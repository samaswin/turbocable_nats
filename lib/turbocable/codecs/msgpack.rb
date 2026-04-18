# frozen_string_literal: true

module Turbocable
  module Codecs
    # MessagePack codec.
    #
    # Encodes payloads using MessagePack with registered ext types for +Time+
    # and +Symbol+. The ext type IDs are coordinated with the TurboCable JS
    # client — the server uses plain +rmp_serde+ and does not interpret ext
    # types (it forwards raw bytes downstream once it confirms the payload is
    # valid MessagePack).
    #
    # == Ext type registry (coordinated with JS client)
    #
    #   EXT_TYPE_SYMBOL = 0   # Symbol encoded as UTF-8 string bytes
    #   EXT_TYPE_TIME   = 1   # Time encoded as int64 (seconds) + int32 (nsec), big-endian
    #
    # == Optional dependency
    #
    # This codec requires the +msgpack+ gem (~> 1.7), which is *not* a hard
    # dependency of +turbocable_nats+. Add it to your Gemfile:
    #
    #   gem "msgpack", "~> 1.7"
    #
    # A +LoadError+ with install instructions is raised on first use if the gem
    # is unavailable.
    #
    # == MRI only
    #
    # The +msgpack+ gem's native extension is MRI-only. JRuby and TruffleRuby
    # are not supported for this codec.
    module MsgPack
      # Ext type ID for +Symbol+, encoded as its UTF-8 string representation.
      # Coordinated with the TurboCable JS client decoder — do not change
      # without a matching update there.
      EXT_TYPE_SYMBOL = 0

      # Ext type ID for +Time+, encoded as 12 bytes:
      # big-endian int64 (seconds since Unix epoch) + big-endian int32 (nanoseconds).
      # Coordinated with the TurboCable JS client decoder — do not change
      # without a matching update there.
      EXT_TYPE_TIME = 1

      FACTORY_MUTEX = Mutex.new
      private_constant :FACTORY_MUTEX

      # @return [String] the WebSocket sub-protocol name for this codec
      def self.content_type
        "turbocable-v1-msgpack"
      end

      # Serializes +payload+ to MessagePack bytes.
      #
      # @param payload [Object] any MessagePack-serializable value
      # @return [String] binary MessagePack bytes (ASCII-8BIT encoding)
      # @raise [LoadError] if the +msgpack+ gem is not installed
      # @raise [Turbocable::SerializationError] if the payload cannot be serialized
      def self.encode(payload)
        require_msgpack!
        factory.pack(payload)
      rescue ::TypeError, ::NoMethodError => e
        raise Turbocable::SerializationError.new(
          "MsgPack codec failed to encode #{payload.class}: #{e.message}",
          codec_name: :msgpack,
          payload_class: payload.class
        )
      end

      # Deserializes MessagePack bytes back to a Ruby value.
      # Intended for testing and round-trip specs; production subscribers are
      # WebSocket clients, not this gem.
      #
      # @param bytes [String] MessagePack-encoded bytes
      # @return [Object]
      # @raise [LoadError] if the +msgpack+ gem is not installed
      def self.decode(bytes)
        require_msgpack!
        factory.unpack(bytes)
      end

      # Returns the shared factory instance, building it on first call.
      # @api private
      def self.factory
        return @factory if @factory

        FACTORY_MUTEX.synchronize { @factory ||= build_factory }
      end

      # Resets the cached factory. Used in tests that need a fresh state.
      # @api private
      def self.reset_factory!
        FACTORY_MUTEX.synchronize { @factory = nil }
      end

      private_class_method def self.build_factory
        f = ::MessagePack::Factory.new

        # EXT_TYPE_SYMBOL (0): pack Symbol as its UTF-8 string bytes
        f.register_type(
          EXT_TYPE_SYMBOL,
          ::Symbol,
          packer: ->(sym) { sym.to_s.encode(Encoding::UTF_8).b },
          unpacker: ->(bytes) { bytes.force_encoding(Encoding::UTF_8).to_sym }
        )

        # EXT_TYPE_TIME (1): pack Time as int64 (seconds) + int32 (nanoseconds)
        f.register_type(
          EXT_TYPE_TIME,
          ::Time,
          packer: ->(t) { [t.to_i, t.nsec].pack("q>l>") },
          unpacker: ->(bytes) {
            secs, nsecs = bytes.unpack("q>l>")
            ::Time.at(secs, nsecs, :nsec).utc
          }
        )

        f
      end

      private_class_method def self.require_msgpack!
        require "msgpack"
      rescue ::LoadError
        raise ::LoadError,
          "The 'msgpack' gem is required for the :msgpack codec but is not installed. " \
          "Add it to your Gemfile: gem 'msgpack', '~> 1.7'"
      end
    end
  end
end
