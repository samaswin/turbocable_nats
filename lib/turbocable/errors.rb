# frozen_string_literal: true

module Turbocable
  # Base error class for all Turbocable-raised exceptions. Callers can rescue
  # +Turbocable::Error+ to catch any gem-originated error.
  class Error < StandardError; end

  # Raised when required configuration fields are absent or mutually exclusive
  # auth options are combined. Validated lazily at publish time, not at
  # +configure+ time, so apps that configure Turbocable on boot but never
  # publish (e.g. consumer-only processes) don't pay the validation cost.
  class ConfigurationError < Error; end

  # Raised when a stream name fails the conservative character-set check:
  # +/\A[A-Za-z0-9_:\-]+\z/+. Names containing +.+, +*+, +>+, whitespace, or
  # other characters that would break NATS subject parsing are rejected before
  # the connection is touched.
  class InvalidStreamName < Error; end

  # Raised when the configured codec cannot serialize the given payload. Carries
  # the codec name and payload class for diagnosis.
  class SerializationError < Error
    # @return [Symbol] the codec that failed (e.g. +:json+)
    attr_reader :codec_name

    # @return [Class] the class of the payload that could not be serialized
    attr_reader :payload_class

    # @param message [String]
    # @param codec_name [Symbol]
    # @param payload_class [Class]
    def initialize(message, codec_name:, payload_class:)
      super(message)
      @codec_name = codec_name
      @payload_class = payload_class
    end
  end

  # Raised when a publish fails after all retries have been exhausted. Wraps
  # the underlying NATS error and preserves diagnostic metadata.
  class PublishError < Error
    # @return [String] the NATS subject that was targeted
    attr_reader :subject

    # @return [Integer] the number of publish attempts made (1 = no retries)
    attr_reader :attempts

    # @param message [String]
    # @param subject [String]
    # @param attempts [Integer]
    # @param cause [Exception, nil]
    def initialize(message, subject:, attempts:, cause: nil)
      super(message)
      @subject = subject
      @attempts = attempts
      @cause = cause
    end

    # @return [Exception, nil] the underlying exception from the final attempt
    def cause
      @cause || super
    end
  end

  # Raised for authentication or JWT-related failures: invalid key material,
  # illegal +allowed_streams+ patterns, or accidental private-key exposure.
  class AuthError < Error; end

  # Raised when the encoded payload exceeds +config.max_payload_bytes+. The
  # limit is checked client-side before touching NATS so callers get a useful
  # error rather than a cryptic NATS-level rejection.
  class PayloadTooLargeError < Error
    # @return [Integer] the byte size of the encoded payload
    attr_reader :byte_size

    # @return [Integer] the configured limit
    attr_reader :limit

    # @param byte_size [Integer]
    # @param limit [Integer]
    def initialize(byte_size:, limit:)
      super("Encoded payload is #{byte_size} bytes, exceeding the #{limit}-byte limit")
      @byte_size = byte_size
      @limit = limit
    end
  end
end
