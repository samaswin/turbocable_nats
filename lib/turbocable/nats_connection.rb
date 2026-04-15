# frozen_string_literal: true

require "nats/client"

module Turbocable
  # Manages the process-wide NATS connection and JetStream context.
  #
  # == Design invariants
  #
  # * *One connection per process.* +nats-pure+ is thread-safe; multiple Ruby
  #   threads can publish concurrently without additional serialization.
  # * *Lazy open.* The connection is not established until the first +#publish+
  #   call. This means apps that configure Turbocable but never broadcast (e.g.
  #   consumer-only processes) don't open a NATS socket.
  # * *Fork-safe.* On +Process.fork+ (Puma / Unicorn worker boot), child
  #   processes detect the PID change and reopen their own connection instead
  #   of sharing the parent's file descriptors.
  # * *Clean shutdown.* An +at_exit+ hook flushes pending acks and closes the
  #   connection gracefully when the process exits.
  # * *No stream management.* The gem never creates or alters the +TURBOCABLE+
  #   JetStream stream — that's +turbocable-server+'s responsibility. If the
  #   stream is absent, NATS returns a "no stream matches subject" error that
  #   is surfaced as +PublishError+ with an actionable message.
  #
  # @api private
  class NatsConnection
    # @param config [Turbocable::Configuration]
    def initialize(config)
      @config = config
      @mutex  = Mutex.new
      @nc     = nil # NATS::IO::Client
      @js     = nil # JetStream context
      @pid    = nil # PID at connection open time

      at_exit { close_quietly }
    end

    # Publishes +bytes+ to +subject+ via JetStream and returns the ack.
    #
    # Opens the connection on first call (lazy) and reopens it in a forked
    # child process (fork-safe).
    #
    # @param subject [String] full NATS subject (e.g. +"TURBOCABLE.chat_room_42"+)
    # @param bytes   [String] encoded payload bytes
    # @param timeout [Float]  per-publish ack wait in seconds
    # @return [NATS::JetStream::PubAck] the JetStream publish acknowledgement
    # @raise [Turbocable::PublishError] if the stream is missing or NATS rejects
    def publish(subject, bytes, timeout:)
      ensure_connected!
      @js.publish(subject, bytes, timeout: timeout)
    rescue NATS::IO::NoRespondersError, NATS::JetStream::Error => e
      handle_nats_error(e, subject)
    end

    # Returns +true+ if NATS is reachable via a flush round-trip.
    #
    # @param timeout [Float]
    # @return [Boolean]
    def ping(timeout: 2.0)
      ensure_connected!
      @nc.flush(timeout)
      true
    rescue StandardError
      false
    end

    # Returns a NATS KV store handle for +bucket+, creating the bucket with
    # sensible defaults if it does not yet exist.
    #
    # Used by +Turbocable::Auth.publish_public_key!+. The server watches the
    # bucket but does not create it; the gem is the source of truth for the
    # bucket's lifecycle.
    #
    # @param bucket [String] KV bucket name (e.g. +"TC_PUBKEYS"+)
    # @param history [Integer] revision history depth (default: +1+)
    # @return [NATS::JetStream::KeyValue]
    # @raise [Turbocable::PublishError] if NATS is unreachable
    def key_value(bucket, history: 1)
      ensure_connected!
      begin
        @js.key_value(bucket)
      rescue NATS::JetStream::Error::NotFound, NATS::JetStream::Error::StreamNotFound
        @js.create_key_value(bucket: bucket, history: history)
      end
    end

    # Closes the connection if open. Safe to call multiple times.
    # @return [void]
    def close
      @mutex.synchronize do
        @nc&.close
        @nc = nil
        @js = nil
        @pid = nil
      end
    end

    private

    # Opens or reopens the NATS connection, guarded by a mutex.
    # PID is checked *inside* the critical section to avoid a TOCTOU race
    # where two threads both observe a stale PID and both try to reconnect.
    def ensure_connected!
      return if connected_in_current_process?

      @mutex.synchronize do
        # Re-check inside the lock — another thread may have already reconnected.
        return if connected_in_current_process?

        close_quietly
        open_connection!
      end
    end

    def connected_in_current_process?
      @nc && !@nc.closed? && @pid == Process.pid
    end

    def open_connection!
      @config.validate!

      opts = build_nats_opts
      nc = NATS::IO::Client.new
      nc.connect(opts)

      @nc  = nc
      @js  = nc.jetstream
      @pid = Process.pid

      @config.logger.debug { "[Turbocable] NATS connection opened (pid=#{@pid})" }
    end

    def build_nats_opts
      opts = {servers: [@config.nats_url]}

      # Credentials file (JWT+nkey — NGS / managed NATS)
      if @config.nats_creds_file
        opts[:user_credentials] = @config.nats_creds_file
      end

      # User + password
      if @config.nats_user
        opts[:user] = @config.nats_user
        opts[:pass] = @config.nats_password
      end

      # Static token
      opts[:auth_token] = @config.nats_token if @config.nats_token

      # TLS
      if @config.nats_tls || @config.nats_tls_cert_file || @config.nats_tls_ca_file
        tls_opts = {}
        tls_opts[:ca_file]   = @config.nats_tls_ca_file   if @config.nats_tls_ca_file
        tls_opts[:cert_file] = @config.nats_tls_cert_file if @config.nats_tls_cert_file
        tls_opts[:key_file]  = @config.nats_tls_key_file  if @config.nats_tls_key_file
        opts[:tls] = tls_opts
      end

      opts
    end

    # Translates NATS-level errors into Turbocable errors with helpful messages.
    def handle_nats_error(error, subject)
      message = if error.message.to_s.include?("no stream matches subject") ||
                   error.message.to_s.include?("no interest")
        "No JetStream stream found for subject '#{subject}'. " \
        "Is turbocable-server running and healthy? " \
        "(The server creates the TURBOCABLE stream on boot — the gem never does.)"
      else
        "NATS publish failed for '#{subject}': #{error.message}"
      end

      raise PublishError.new(message, subject: subject, attempts: 1, cause: error)
    end

    def close_quietly
      @nc&.close
    rescue StandardError
      # Logger may already be torn down at exit — swallow all errors
      nil
    ensure
      @nc  = nil
      @js  = nil
      @pid = nil
    end
  end
end
