# frozen_string_literal: true

require_relative "turbocable/version"
require_relative "turbocable/errors"
require_relative "turbocable/configuration"
require_relative "turbocable/codecs"
require_relative "turbocable/nats_connection"
require_relative "turbocable/client"
require_relative "turbocable/auth"

# Turbocable is a pure-Ruby publisher for the TurboCable fan-out pipeline.
#
# == Quick start
#
#   require "turbocable"
#
#   Turbocable.configure do |c|
#     c.nats_url        = ENV.fetch("TURBOCABLE_NATS_URL", "nats://localhost:4222")
#     c.default_codec   = :json
#     c.publish_timeout = 2.0
#     c.max_retries     = 3
#     c.logger          = Rails.logger   # or any Logger-compatible object
#   end
#
#   Turbocable.broadcast("chat_room_42", text: "hello")
#
# See +Turbocable::Configuration+ for the full list of options including NATS
# auth modes (creds file, user+password, token, mTLS).
module Turbocable
  class << self
    # Returns the process-wide configuration object.
    #
    # @return [Turbocable::Configuration]
    def config
      @config_mutex ||= Mutex.new
      @config_mutex.synchronize { @config ||= Configuration.new }
    end

    # Yields the configuration object and then freezes it for thread-safety.
    # May be called multiple times — subsequent calls merge into the existing
    # config rather than replacing it.
    #
    # @yieldparam config [Turbocable::Configuration]
    # @return [void]
    def configure
      yield config
    end

    # Resets the configuration and the client singleton. Intended for use in
    # test suites between examples.
    #
    # @api private
    def reset!
      @config_mutex ||= Mutex.new
      @config_mutex.synchronize do
        @client&.send(:connection).close rescue nil
        @config = nil
        @client = nil
      end
    end

    # Publishes +payload+ to the stream identified by +stream_name+.
    #
    # This is the primary public API. It delegates to the process-wide
    # +Client+ singleton, creating it on first call.
    #
    # @param stream_name [String]  logical stream name (e.g. +"chat_room_42"+)
    # @param payload [Object]      any value serializable by the codec
    # @param codec [Symbol, nil]   override the configured default codec
    # @return [NATS::JetStream::PubAck]
    # @raise [Turbocable::InvalidStreamName]
    # @raise [Turbocable::SerializationError]
    # @raise [Turbocable::PayloadTooLargeError]
    # @raise [Turbocable::PublishError]
    def broadcast(stream_name, payload, codec: nil)
      client.broadcast(stream_name, payload, codec: codec)
    end

    # Returns the process-wide +Client+ singleton. Created lazily on first call.
    #
    # @return [Turbocable::Client]
    def client
      @config_mutex ||= Mutex.new
      @config_mutex.synchronize { @client ||= Client.new(config) }
    end
  end
end
