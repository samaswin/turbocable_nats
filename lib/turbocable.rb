# frozen_string_literal: true

require_relative "turbocable/version"
require_relative "turbocable/errors"
require_relative "turbocable/configuration"
require_relative "turbocable/codecs"
require_relative "turbocable/null_adapter"
require_relative "turbocable/nats_connection"
require_relative "turbocable/client"
require_relative "turbocable/auth"

# Turbocable is a pure-Ruby publisher for the TurboCable fan-out pipeline.
#
# == Quick start
#
#   require "turbocable_nats"   # RubyGems name; loads the +Turbocable+ module
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
    # Only closes the underlying connection when it is a known real adapter
    # (+NatsConnection+ or +NullAdapter+). This avoids triggering RSpec mock
    # verification failures when the connection has been replaced with an
    # +instance_double+ in a test.
    #
    # @api private
    # @return [void]
    def reset!
      @config_mutex ||= Mutex.new
      @client_mutex ||= Mutex.new
      @client_mutex.synchronize do
        conn = begin
          @client&.send(:connection)
        rescue
          nil
        end
        if conn.is_a?(NatsConnection) || conn.is_a?(NullAdapter)
          begin
            conn.close
          rescue
            nil
          end
        end
        @client = nil
      end
      @config_mutex.synchronize { @config = nil }
      NullAdapter.reset!
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
    # Uses a dedicated mutex separate from the config mutex so that
    # +Client.new(config)+ can call +config+ internally without deadlocking.
    #
    # @return [Turbocable::Client]
    def client
      @client_mutex ||= Mutex.new
      @client_mutex.synchronize { @client ||= Client.new(config) }
    end

    # Checks whether the publisher can reach NATS.
    #
    # For the +:nats+ adapter this issues a NATS +flush+ (PING/PONG round-trip)
    # within +config.publish_timeout+ seconds. For the +:null+ adapter it always
    # returns +true+.
    #
    # == What this probe does and does not check
    #
    # A +true+ result means the *publisher process* can reach the *NATS server*.
    # It does **not** confirm that +turbocable-server+ (the gateway) is running
    # or that messages are being fanned out to WebSocket clients. To check
    # gateway liveness, hit its HTTP endpoint directly:
    #
    #   curl http://turbocable-server:9292/health
    #
    # For a stricter check that raises on failure see +healthcheck!+.
    #
    # @return [Boolean] +true+ if NATS is reachable, +false+ otherwise
    # @raise [ConfigurationError] if configuration is invalid
    def healthy?
      client.healthy?
    end

    # Like +healthy?+ but raises on failure instead of returning +false+.
    #
    # Useful for Kubernetes +startupProbe+ handlers or other contexts where
    # an exception is easier to handle than a boolean.
    #
    # @return [true]
    # @raise [HealthCheckError] if NATS is unreachable
    # @raise [ConfigurationError] if configuration is invalid
    def healthcheck!
      return true if healthy?

      raise HealthCheckError.new(
        "Turbocable health check failed: NATS is unreachable at " \
        "#{config.nats_url} within #{config.publish_timeout}s. " \
        "Verify the NATS server is running and the publisher is correctly configured."
      )
    end
  end
end
