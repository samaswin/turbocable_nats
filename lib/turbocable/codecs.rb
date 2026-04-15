# frozen_string_literal: true

require_relative "codecs/json"
# codecs/msgpack is loaded lazily on first :msgpack request (requires optional msgpack gem)

module Turbocable
  # Registry for payload codecs. Each codec exposes:
  #
  #   .encode(payload) -> String (bytes)
  #   .decode(bytes)   -> Object  (for tests / round-trips)
  #   .content_type    -> String  (WebSocket sub-protocol name, informational)
  #
  # Built-in codecs:
  # - +:json+ — always available, no extra dependencies
  # - +:msgpack+ — requires the +msgpack+ gem (~> 1.7); loaded lazily on first use
  #
  # @example Fetch the JSON codec
  #   codec = Turbocable::Codecs.fetch(:json)
  #   bytes = codec.encode({ text: "hello" })
  #
  # @example Fetch the MessagePack codec (requires msgpack gem)
  #   codec = Turbocable::Codecs.fetch(:msgpack)
  #   bytes = codec.encode({ text: "hello" })
  module Codecs
    REGISTRY = {
      json: Codecs::JSON
    }.freeze
    private_constant :REGISTRY

    # Codecs loaded lazily because they depend on optional gems.
    LAZY_CODECS = %i[msgpack].freeze
    private_constant :LAZY_CODECS

    # Returns the codec module for +name+.
    #
    # +:msgpack+ is loaded on first access; it raises +LoadError+ if the
    # +msgpack+ gem is not installed.
    #
    # @param name [Symbol, String]
    # @return [Module] a codec module with +.encode+, +.decode+, +.content_type+
    # @raise [Turbocable::ConfigurationError] if +name+ is unknown
    # @raise [LoadError] if +:msgpack+ is requested and the gem is not installed
    def self.fetch(name)
      key = name.to_sym
      return REGISTRY[key] if REGISTRY.key?(key)
      return load_lazy_codec!(key) if LAZY_CODECS.include?(key)

      raise ConfigurationError,
        "Unknown codec #{key.inspect}. " \
        "Available: #{registered.map(&:inspect).join(", ")}."
    end

    # @return [Array<Symbol>] all codec names (eager + lazy)
    def self.registered
      (REGISTRY.keys + LAZY_CODECS).freeze
    end

    private_class_method def self.load_lazy_codec!(name)
      case name
      when :msgpack
        require_relative "codecs/msgpack"
        Codecs::MsgPack
      end
    end
  end
end
