# frozen_string_literal: true

module Turbocable
  # Entry point for publishing messages to the TurboCable fan-out pipeline.
  #
  # Prefer the top-level convenience method:
  #
  #   Turbocable.broadcast("chat_room_42", text: "hello")
  #
  # Use the client directly when you need per-call codec overrides or access to
  # the returned JetStream ack:
  #
  #   client = Turbocable::Client.new(Turbocable.config)
  #   ack = client.broadcast("chat_room_42", {text: "hi"}, codec: :json)
  #   puts ack.stream   # => "TURBOCABLE"
  #   puts ack.seq      # => 1
  #
  # == Data flow
  #
  # 1. Validate the stream name against the server's subject-token charset.
  # 2. Look up the codec (default from +config.default_codec+, or per-call).
  # 3. Serialize the payload to bytes.
  # 4. Enforce +config.max_payload_bytes+ — fail fast before touching NATS.
  # 5. Publish to NATS JetStream via +NatsConnection#publish+.
  # 6. On transient failures (+Timeout+, +JetStream::Error+), retry with
  #    exponential backoff up to +config.max_retries+ times.
  # 7. Return the JetStream ack on success or raise +PublishError+ on final failure.
  #
  # == On delivery guarantees
  #
  # A successful ack means NATS JetStream has persisted the message. If the
  # server operator has set +TURBOCABLE_STREAM_RATE_LIMIT_RPS+, messages that
  # exceed the stream's rate limit may be dropped by +turbocable-server+ *after*
  # a successful NATS ack. A green +broadcast+ is therefore not an end-to-end
  # delivery guarantee — it is a persistence guarantee.
  class Client
    # Conservative charset matching what the server's NATS glob authorizer
    # accepts as a subject token. Characters that break NATS subject parsing
    # (+.+, +*+, +>+, whitespace) are excluded.
    STREAM_NAME_PATTERN = /\A[A-Za-z0-9_:\-]+\z/

    # Exponential backoff parameters.
    BASE_DELAY     = 0.05  # 50 ms
    BACKOFF_FACTOR = 2
    JITTER_FACTOR  = 0.20  # ±20%

    # @param config [Turbocable::Configuration]
    # @param connection [Turbocable::NatsConnection, nil] injectable for tests
    # @param clock [#call, nil] callable invoked with a duration in seconds
    #   instead of +Kernel.sleep+; injectable for deterministic backoff specs
    def initialize(config, connection: nil, clock: nil)
      @config     = config
      @connection = connection
      @clock      = clock
    end

    # Publishes +payload+ to the +stream_name+ subject.
    #
    # @param stream_name [String]  logical stream name (e.g. +"chat_room_42"+).
    #   Must match +/\A[A-Za-z0-9_:\-]+\z/+.
    # @param payload [Object]  value serializable by the codec (typically a Hash).
    # @param codec [Symbol, nil]  codec override; falls back to
    #   +config.default_codec+ when nil.
    # @return [NATS::JetStream::PubAck]
    # @raise [InvalidStreamName] if +stream_name+ contains illegal characters.
    # @raise [SerializationError] if the codec cannot serialize +payload+.
    # @raise [PayloadTooLargeError] if encoded bytes exceed
    #   +config.max_payload_bytes+.
    # @raise [PublishError] if NATS rejects the publish after all retries.
    def broadcast(stream_name, payload, codec: nil)
      validate_stream_name!(stream_name)

      codec_module = Codecs.fetch(codec || @config.default_codec)
      bytes        = codec_module.encode(payload)

      enforce_payload_size!(bytes)

      subject = "#{@config.subject_prefix}.#{stream_name}"
      publish_with_retries(subject, bytes)
    end

    private

    # -------------------------------------------------------------------------
    # Validation helpers
    # -------------------------------------------------------------------------

    def validate_stream_name!(name)
      return if name.is_a?(String) && name.match?(STREAM_NAME_PATTERN)

      raise InvalidStreamName,
        "Invalid stream name #{name.inspect}. " \
        "Names must match /\\A[A-Za-z0-9_:\\-]+\\z/ — " \
        "dots, wildcards (*/>), whitespace, and non-ASCII are not allowed."
    end

    def enforce_payload_size!(bytes)
      limit = @config.max_payload_bytes
      return if bytes.bytesize <= limit

      raise PayloadTooLargeError.new(byte_size: bytes.bytesize, limit: limit)
    end

    # -------------------------------------------------------------------------
    # Retry + publish
    # -------------------------------------------------------------------------

    def publish_with_retries(subject, bytes)
      max_retries = @config.max_retries
      timeout     = @config.publish_timeout
      attempts    = 0
      last_error  = nil

      loop do
        attempts += 1
        @config.logger.debug do
          "[Turbocable] Publishing to '#{subject}' " \
          "(attempt #{attempts}/#{max_retries + 1})"
        end

        begin
          return connection.publish(subject, bytes, timeout: timeout)
        rescue NATS::IO::Timeout, NATS::JetStream::Error => e
          last_error = e
          @config.logger.warn do
            "[Turbocable] Publish attempt #{attempts}/#{max_retries + 1} failed " \
            "for '#{subject}': #{e.class} — #{e.message}"
          end

          break if attempts > max_retries

          do_sleep(backoff_delay(attempts))
        rescue PublishError
          # Already wrapped by NatsConnection — re-raise without additional wrapping
          raise
        rescue => e
          # Unknown error — wrap and raise immediately, no retries
          raise PublishError.new(
            "Unexpected error publishing to '#{subject}': #{e.message}",
            subject: subject,
            attempts: attempts,
            cause: e
          )
        end
      end

      @config.logger.error do
        "[Turbocable] Publish failed permanently after #{attempts} attempt(s) " \
        "for '#{subject}': #{last_error&.class} — #{last_error&.message}"
      end
      raise PublishError.new(
        "Failed to publish to '#{subject}' after #{attempts} attempt(s): #{last_error&.message}",
        subject: subject,
        attempts: attempts,
        cause: last_error
      )
    end

    # Returns the sleep duration for the given attempt number (1-based) with
    # jitter. Capped at +config.publish_timeout+ so we never delay longer than
    # the ack window.
    def backoff_delay(attempt)
      base   = BASE_DELAY * (BACKOFF_FACTOR**(attempt - 1))
      jitter = base * JITTER_FACTOR * ((rand * 2) - 1)
      delay  = base + jitter
      [delay, @config.publish_timeout].min
    end

    # Suspends execution for +duration+ seconds. Delegates to the injected
    # +clock+ callable when present, otherwise falls back to +Kernel.sleep+.
    # Injectable for deterministic backoff tests.
    def do_sleep(duration)
      @clock ? @clock.call(duration) : Kernel.sleep(duration)
    end

    # -------------------------------------------------------------------------
    # Connection accessor (lazy + memoized)
    # -------------------------------------------------------------------------

    def connection
      @connection ||= NatsConnection.new(@config)
    end
  end
end
