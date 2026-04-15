# frozen_string_literal: true

require "openssl"
require "net/http"
require "uri"
require "jwt"

module Turbocable
  # JWT minting and public-key publishing for the TurboCable gateway.
  #
  # The gateway validates every WebSocket connection with an RS256 JWT. The
  # gem is responsible for:
  #
  # 1. *Minting* short-lived tokens via +Auth.issue_token+.
  # 2. *Publishing* the corresponding public key to the NATS KV bucket the
  #    gateway watches via +Auth.publish_public_key!+.
  #
  # == Typical boot sequence
  #
  #   Turbocable.configure do |c|
  #     c.jwt_private_key = File.read("private.pem")
  #     c.jwt_public_key  = File.read("public.pem")
  #     c.jwt_issuer      = "my-rails-app"
  #   end
  #
  #   # Once at boot (or after every key rotation):
  #   Turbocable::Auth.publish_public_key!
  #
  #   # Per request / per user:
  #   token = Turbocable::Auth.issue_token(
  #     sub:             current_user.id.to_s,
  #     allowed_streams: ["chat_room_*"],
  #     ttl:             3600
  #   )
  #
  # == Allowed-stream patterns
  #
  # The server supports three glob forms for +allowed_streams+:
  # * +"*"+ — the subscriber may access any stream.
  # * +"prefix_*"+ — any stream whose name starts with +prefix_+. The prefix
  #   must be a non-empty string matching +/\A[A-Za-z0-9_:\-]+\z/+ and the
  #   trailing +*+ must be the only wildcard character.
  # * Exact name — a single stream name matching +/\A[A-Za-z0-9_:\-]+\z/+.
  #
  # Anything else (embedded dots, mid-string wildcards, multiple wildcards,
  # whitespace) is rejected by +issue_token+ at mint time with +AuthError+.
  #
  # == Key rotation runbook
  #
  # See +docs/auth.md+ for the full runbook, including the warning about
  # +TURBOCABLE_JWT_PUBLIC_KEY_PATH+ silently shadowing the KV entry.
  module Auth
    # Mints a short-lived RS256 JWT for a WebSocket subscriber.
    #
    # @param sub [String] subject (typically a user ID or session ID)
    # @param allowed_streams [Array<String>] stream patterns the subscriber
    #   may access. Each entry must be +"*"+, +"prefix_*"+, or an exact name.
    # @param ttl [Integer] token lifetime in seconds (minimum recommended: 60)
    # @param extra_claims [Hash] additional claims merged into the payload
    # @return [String] signed JWT string
    # @raise [ConfigurationError] if +jwt_private_key+ is not configured
    # @raise [AuthError] if the key is not a valid RSA private key, if it is
    #   an HMAC secret, or if any +allowed_streams+ entry is invalid
    def self.issue_token(sub:, allowed_streams:, ttl:, **extra_claims)
      config = Turbocable.config

      pem = config.jwt_private_key
      raise ConfigurationError, "jwt_private_key is required to mint tokens" if pem.nil? || pem.empty?

      rsa_key = load_rsa_private_key!(pem)
      validate_allowed_streams!(allowed_streams)

      now = Time.now.to_i
      payload = {
        sub: sub,
        allowed_streams: allowed_streams,
        iat: now,
        exp: now + ttl
      }
      payload[:iss] = config.jwt_issuer if config.jwt_issuer
      payload.merge!(extra_claims)

      JWT.encode(payload, rsa_key, "RS256")
    end

    # Publishes the configured RSA public key PEM to the NATS KV bucket that
    # the gateway watches for hot-reload.
    #
    # Creates the +TC_PUBKEYS+ bucket if it does not yet exist. The server
    # *watches* the bucket but never creates it.
    #
    # *Warning*: if the server operator has set +TURBOCABLE_JWT_PUBLIC_KEY_PATH+
    # to a file, the server will prioritise that file over the KV entry and KV
    # rotations will be silently ignored. This method emits a +:warn+ log when
    # it detects this condition (by probing +GET /pubkey+ on the server). See
    # +docs/auth.md+ for the rotation runbook.
    #
    # @return [Integer] KV revision number of the written entry
    # @raise [ConfigurationError] if +jwt_public_key+ is not configured
    # @raise [AuthError] if +jwt_public_key+ contains private-key PEM material
    #   or is not a valid RSA public key
    def self.publish_public_key!
      config = Turbocable.config

      pem = config.jwt_public_key
      raise ConfigurationError, "jwt_public_key is required to publish the public key" if pem.nil? || pem.empty?

      # Guard against accidentally publishing a private key
      if pem.include?("PRIVATE KEY")
        raise AuthError,
          "jwt_public_key appears to contain a private key — refusing to publish. " \
          "Set jwt_public_key to the *public* half of your RSA key pair."
      end

      rsa_pub = load_rsa_public_key!(pem)
      canonical_pem = rsa_pub.public_key.to_pem

      maybe_warn_file_shadow!(config, canonical_pem)

      kv = Turbocable.client.send(:connection).key_value(config.jwt_kv_bucket)
      revision = kv.put(config.jwt_kv_key, canonical_pem)

      config.logger.info do
        "[Turbocable::Auth] Published public key to #{config.jwt_kv_bucket}/#{config.jwt_kv_key} " \
        "(revision #{revision})"
      end

      revision
    end

    # Decodes and verifies a JWT signed with the configured public key.
    #
    # *Intended for test suites only* — the gateway verifies tokens itself.
    # Do not use this in production request paths.
    #
    # @param token [String] the JWT to verify
    # @return [Array<(Hash, Hash)>] +[payload, header]+ as returned by
    #   +JWT.decode+
    # @raise [ConfigurationError] if +jwt_public_key+ is not configured
    # @raise [JWT::DecodeError] and subclasses on verification failure
    def self.verify_token(token)
      config = Turbocable.config

      pem = config.jwt_public_key
      raise ConfigurationError, "jwt_public_key is required to verify tokens" if pem.nil? || pem.empty?

      rsa_pub = load_rsa_public_key!(pem)
      JWT.decode(token, rsa_pub.public_key, true, algorithms: ["RS256"])
    end

    # Returns +true+ if +pattern+ is a valid +allowed_streams+ entry for the
    # server's glob grammar. Exposed for callers that want to pre-validate
    # patterns without minting a full token.
    #
    # @param pattern [String]
    # @return [Boolean]
    def self.valid_stream_pattern?(pattern)
      return true if pattern == "*"

      if pattern.end_with?("*")
        prefix = pattern[0..-2]
        return false if prefix.empty?
        return prefix.match?(/\A[A-Za-z0-9_:\-]+\z/)
      end

      pattern.match?(/\A[A-Za-z0-9_:\-]+\z/)
    end

    # -------------------------------------------------------------------------
    # Private helpers
    # -------------------------------------------------------------------------

    def self.load_rsa_private_key!(pem)
      key = OpenSSL::PKey::RSA.new(pem)
      raise AuthError, "jwt_private_key must be an RSA *private* key (HMAC secrets are not supported)" unless key.private?
      key
    rescue OpenSSL::PKey::RSAError, OpenSSL::PKey::PKeyError => e
      raise AuthError, "jwt_private_key is not a valid RSA private key: #{e.message}"
    end
    private_class_method :load_rsa_private_key!

    def self.load_rsa_public_key!(pem)
      OpenSSL::PKey::RSA.new(pem)
    rescue OpenSSL::PKey::RSAError, OpenSSL::PKey::PKeyError => e
      raise AuthError, "jwt_public_key is not a valid RSA key: #{e.message}"
    end
    private_class_method :load_rsa_public_key!

    def self.validate_allowed_streams!(streams)
      Array(streams).each do |pattern|
        next if valid_stream_pattern?(pattern)

        raise AuthError,
          "Invalid allowed_streams pattern: #{pattern.inspect}. " \
          "Must be \"*\", \"prefix_*\" (non-empty prefix + single trailing wildcard), " \
          "or an exact stream name matching /\\A[A-Za-z0-9_:\\-]+\\z/."
      end
    end
    private_class_method :validate_allowed_streams!

    # Probes +GET /pubkey+ on the server (best-effort). Warns if the server
    # returns a PEM that differs from +canonical_pem+, which means it is
    # serving a file-based key that will shadow KV updates.
    def self.maybe_warn_file_shadow!(config, canonical_pem)
      server_health_url = ENV.fetch("TURBOCABLE_SERVER_HEALTH_URL", "http://localhost:9292")
      pubkey_url = server_health_url.sub(%r{/health\z}, "") + "/pubkey"
      uri = URI(pubkey_url)

      response = Net::HTTP.get_response(uri)
      return unless response.is_a?(Net::HTTPOK)

      server_pem = response.body.strip
      return if server_pem == canonical_pem.strip

      config.logger.warn do
        "[Turbocable::Auth] The server at #{pubkey_url} is serving a different public key " \
        "than the one being published to KV. This usually means TURBOCABLE_JWT_PUBLIC_KEY_PATH " \
        "is set on the server, which takes precedence over the KV entry. " \
        "Tokens signed with the KV key will be rejected until the file-based key is removed. " \
        "See docs/auth.md for the rotation runbook."
      end
    rescue StandardError
      # Best-effort probe — swallow all network errors silently
      nil
    end
    private_class_method :maybe_warn_file_shadow!
  end
end
