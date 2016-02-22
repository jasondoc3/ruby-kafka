require "kafka/partitioner"
require "kafka/message_buffer"
require "kafka/produce_operation"
require "kafka/pending_message"
require "kafka/compression"

module Kafka

  # Allows sending messages to a Kafka cluster.
  #
  # Typically you won't instantiate this class yourself, but rather have {Kafka::Client}
  # do it for you, e.g.
  #
  #     # Will instantiate Kafka::Client
  #     kafka = Kafka.new(...)
  #
  #     # Will instantiate Kafka::Producer
  #     producer = kafka.producer
  #
  # This is done in order to share a logger as well as a pool of broker connections across
  # different producers. This also means that you don't need to pass the `cluster` and
  # `logger` options to `#producer`. See {#initialize} for the list of other options
  # you can pass in.
  #
  # ## Buffering
  #
  # The producer buffers pending messages until {#deliver_messages} is called. Note that there is
  # a maximum buffer size (default is 1,000 messages) and writing messages after the
  # buffer has reached this size will result in a BufferOverflow exception. Make sure
  # to periodically call {#deliver_messages} or set `max_buffer_size` to an appropriate value.
  #
  # Buffering messages and sending them in batches greatly improves performance, so
  # try to avoid sending messages after every write. The tradeoff between throughput and
  # message delays depends on your use case.
  #
  # ## Error Handling and Retries
  #
  # The design of the error handling is based on having a {MessageBuffer} hold messages
  # for all topics/partitions. Whenever we want to send messages to the cluster, we
  # group the buffered messages by the broker they need to be sent to and fire off a
  # request to each broker. A request can be a partial success, so we go through the
  # response and inspect the error code for each partition that we wrote to. If the
  # write to a given partition was successful, we clear the corresponding messages
  # from the buffer -- otherwise, we log the error and keep the messages in the buffer.
  #
  # After this, we check if the buffer is empty. If it is, we're all done. If it's
  # not, we do another round of requests, this time with just the remaining messages.
  # We do this for as long as `max_retries` permits.
  #
  # ## Instrumentation
  #
  # After {#deliver_messages} completes, the notification
  # `deliver_messages.producer.kafka` will be emitted.
  #
  # * `message_count` – the total number of messages that the producer tried to
  #   deliver. Note that not all messages may get delivered.
  # * `delivered_message_count` – the number of messages that were successfully
  #   delivered.
  # * `attempts` – the number of attempts made to deliver the messages.
  #
  # ## Example
  #
  # This is an example of an application which reads lines from stdin and writes them
  # to Kafka:
  #
  #     require "kafka"
  #
  #     logger = Logger.new($stderr)
  #     brokers = ENV.fetch("KAFKA_BROKERS").split(",")
  #
  #     # Make sure to create this topic in your Kafka cluster or configure the
  #     # cluster to auto-create topics.
  #     topic = "random-messages"
  #
  #     kafka = Kafka.new(
  #       seed_brokers: brokers,
  #       client_id: "simple-producer",
  #       logger: logger,
  #     )
  #
  #     producer = kafka.producer
  #
  #     begin
  #       $stdin.each_with_index do |line, index|
  #         producer.produce(line, topic: topic)
  #
  #         # Send messages for every 10 lines.
  #         producer.deliver_messages if index % 10 == 0
  #       end
  #     ensure
  #       # Make sure to send any remaining messages.
  #       producer.deliver_messages
  #
  #       producer.shutdown
  #     end
  #
  class Producer

    # Initializes a new Producer.
    #
    # @param cluster [Cluster] the cluster client. Typically passed in for you.
    #
    # @param logger [Logger] the logger that should be used. Typically passed
    #   in for you.
    #
    # @param ack_timeout [Integer] The number of seconds a broker can wait for
    #   replicas to acknowledge a write before responding with a timeout.
    #
    # @param required_acks [Integer] The number of replicas that must acknowledge
    #   a write.
    #
    # @param max_retries [Integer] the number of retries that should be attempted
    #   before giving up sending messages to the cluster. Does not include the
    #   original attempt.
    #
    # @param retry_backoff [Integer] the number of seconds to wait between retries.
    #
    # @param max_buffer_size [Integer] the number of messages allowed in the buffer
    #   before new writes will raise BufferOverflow exceptions.
    #
    # @param compression_codec [Symbol, nil] the name of the compression codec to
    #   use, or nil if no compression should be performed. Valid codecs: `:snappy`
    #   and `:gzip`.
    #
    def initialize(cluster:, logger:, compression_codec: nil, ack_timeout: 5, required_acks: 1, max_retries: 2, retry_backoff: 1, max_buffer_size: 1000)
      @cluster = cluster
      @logger = logger
      @required_acks = required_acks
      @ack_timeout = ack_timeout
      @max_retries = max_retries
      @retry_backoff = retry_backoff
      @max_buffer_size = max_buffer_size
      @compression_codec = Compression.find_codec(compression_codec)

      # A buffer organized by topic/partition.
      @buffer = MessageBuffer.new

      # Messages added by `#produce` but not yet assigned a partition.
      @pending_messages = []
    end

    # Produces a message to the specified topic. Note that messages are buffered in
    # the producer until {#deliver_messages} is called.
    #
    # ## Partitioning
    #
    # There are several options for specifying the partition that the message should
    # be written to.
    #
    # The simplest option is to not specify a message key, partition key, or
    # partition number, in which case the message will be assigned a partition at
    # random.
    #
    # You can also specify the `partition` parameter yourself. This requires you to
    # know which partitions are available, however. Oftentimes the best option is
    # to specify the `partition_key` parameter: messages with the same partition
    # key will always be assigned to the same partition, as long as the number of
    # partitions doesn't change. You can also omit the partition key and specify
    # a message key instead. The message key is part of the message payload, and
    # so can carry semantic value--whether you want to have the message key double
    # as a partition key is up to you.
    #
    # @param value [String] the message data.
    # @param key [String] the message key.
    # @param topic [String] the topic that the message should be written to.
    # @param partition [Integer] the partition that the message should be written to.
    # @param partition_key [String] the key that should be used to assign a partition.
    #
    # @raise [BufferOverflow] if the maximum buffer size has been reached.
    # @return [nil]
    def produce(value, key: nil, topic:, partition: nil, partition_key: nil)
      unless buffer_size < @max_buffer_size
        raise BufferOverflow, "Max buffer size #{@max_buffer_size} exceeded"
      end

      @pending_messages << PendingMessage.new(
        value: value,
        key: key,
        topic: topic,
        partition: partition,
        partition_key: partition_key,
      )

      nil
    end

    # Sends all buffered messages to the Kafka brokers.
    #
    # Depending on the value of `required_acks` used when initializing the producer,
    # this call may block until the specified number of replicas have acknowledged
    # the writes. The `ack_timeout` setting places an upper bound on the amount of
    # time the call will block before failing.
    #
    # @raise [DeliveryFailed] if not all messages could be successfully sent.
    # @return [nil]
    def deliver_messages
      # There's no need to do anything if the buffer is empty.
      return if buffer_size == 0

      Instrumentation.instrument("deliver_messages.producer.kafka") do |notification|
        message_count = buffer_size

        notification[:message_count] = message_count
        notification[:attempts] = 0

        begin
          deliver_messages_with_retries(notification)
        ensure
          notification[:delivered_message_count] = message_count - buffer_size
        end
      end
    end

    # Returns the number of messages currently held in the buffer.
    #
    # @return [Integer] buffer size.
    def buffer_size
      @pending_messages.size + @buffer.size
    end

    # Closes all connections to the brokers.
    #
    # @return [nil]
    def shutdown
      @cluster.disconnect
    end

    private

    def deliver_messages_with_retries(notification)
      attempt = 0

      # Make sure we get metadata for this topic.
      target_topics = @pending_messages.map(&:topic).uniq
      @cluster.add_target_topics(target_topics)

      operation = ProduceOperation.new(
        cluster: @cluster,
        buffer: @buffer,
        required_acks: @required_acks,
        ack_timeout: @ack_timeout,
        compression_codec: @compression_codec,
        logger: @logger,
      )

      loop do
        attempt += 1

        notification[:attempts] = attempt

        @cluster.refresh_metadata_if_necessary!

        assign_partitions!
        operation.execute

        if @pending_messages.empty? && @buffer.empty?
          break
        elsif attempt <= @max_retries
          @logger.warn "Failed to send all messages; attempting retry #{attempt} of #{@max_retries} after #{@retry_backoff}s"

          sleep @retry_backoff
        else
          @logger.error "Failed to send all messages; keeping remaining messages in buffer"
          break
        end
      end

      if @required_acks == 0
        # No response is returned by the brokers, so we can't know which messages
        # have been successfully written. Our only option is to assume that they all
        # have.
        @buffer.clear
      end

      unless @buffer.empty?
        partitions = @buffer.map {|topic, partition, _| "#{topic}/#{partition}" }.join(", ")

        raise DeliveryFailed, "Failed to send messages to #{partitions}"
      end
    end

    def assign_partitions!
      until @pending_messages.empty?
        # We want to keep the message in the first-stage buffer in case there's an error.
        message = @pending_messages.first

        partition = message.partition

        if partition.nil?
          partition_count = @cluster.partitions_for(message.topic).count
          partition = Partitioner.partition_for_key(partition_count, message)
        end

        @buffer.write(
          value: message.value,
          key: message.key,
          topic: message.topic,
          partition: partition,
        )

        # Now it's safe to remove the message from the first-stage buffer.
        @pending_messages.shift
      end
    rescue Kafka::Error => e
      @logger.error "Failed to assign pending message to a partition: #{e}"
      @cluster.mark_as_stale!
    end
  end
end
