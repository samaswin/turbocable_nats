# frozen_string_literal: true

module Turbocable
  # Holds all configuration for the Turbocable gem. Set via
  # +Turbocable.configure { |c| … }+.
  #
  # Every attribute that maps to an environment variable is read from the
  # environment at *first access*, not at require time. This means containers
  # that inject env vars after boot (e.g. via secrets sidecars) still work.
  #
  # == NATS auth modes
  #
  # Exactly one of the following auth strategies may be active at a time:
  #
  # 1. No auth (default — leave all auth fields nil)
  # 2. Credentials file (+nats_creds_file+) — JWT+nkey, used by NGS / managed NATS
  # 3. User+password (+nats_user+ / +nats_password+)
  # 4. Static token (+nats_token+)
  # 5. mTLS (+nats_tls+ = true, with optional cert/key/ca paths)
  #
  # Mixing creds-file with user/token is rejected at +#validate!+.
  class Configuration
    # -------------------------------------------------------------------------
    # NATS transport
    # -------------------------------------------------------------------------

    # @!attribute [rw] nats_url
    #   NATS server URL (default: +TURBOCABLE_NATS_URL+ env or
    #   +"nats://localhost:4222"+).
    # @return [String]
    attr_writer :nats_url

    def nats_url
      @nats_url ||= ENV.fetch("TURBOCABLE_NATS_URL", "nats://localhost:4222")
    end

    # @!attribute [rw] stream_name
    #   JetStream stream name (default: +"TURBOCABLE"+). Must match the name
    #   the server creates — do not change unless you also change the server.
    # @return [String]
    attr_writer :stream_name

    def stream_name
      @stream_name ||= ENV.fetch("TURBOCABLE_STREAM_NAME", "TURBOCABLE")
    end

    # @!attribute [rw] subject_prefix
    #   NATS subject prefix used when building publish subjects
    #   (default: +"TURBOCABLE"+). A broadcast to stream +"chat_room_42"+ will
    #   publish to +"TURBOCABLE.chat_room_42"+.
    # @return [String]
    attr_writer :subject_prefix

    def subject_prefix
      @subject_prefix ||= ENV.fetch("TURBOCABLE_SUBJECT_PREFIX", "TURBOCABLE")
    end

    # @!attribute [rw] default_codec
    #   Default codec to use when none is specified on +broadcast+. Must be a
    #   key registered in +Turbocable::Codecs+ (e.g. +:json+, +:msgpack+).
    #   (default: +:json+)
    # @return [Symbol]
    attr_writer :default_codec

    def default_codec
      @default_codec ||= (ENV["TURBOCABLE_DEFAULT_CODEC"]&.to_sym || :json)
    end

    # @!attribute [rw] publish_timeout
    #   Maximum seconds to wait for a JetStream publish ack (default: +2.0+).
    # @return [Float]
    attr_writer :publish_timeout

    def publish_timeout
      @publish_timeout ||= Float(ENV.fetch("TURBOCABLE_PUBLISH_TIMEOUT", "2.0"))
    end

    # @!attribute [rw] max_retries
    #   How many times to retry after a transient NATS failure before raising
    #   +PublishError+ (default: +3+). A value of +0+ disables retries.
    # @return [Integer]
    attr_writer :max_retries

    def max_retries
      @max_retries ||= Integer(ENV.fetch("TURBOCABLE_MAX_RETRIES", "3"))
    end

    # @!attribute [rw] max_payload_bytes
    #   Maximum encoded payload size in bytes (default: +1_000_000+, matching
    #   NATS +MaxMsgSize+). Payloads that exceed this limit are rejected with
    #   +PayloadTooLargeError+ before the connection is touched.
    # @return [Integer]
    attr_writer :max_payload_bytes

    def max_payload_bytes
      @max_payload_bytes ||= Integer(ENV.fetch("TURBOCABLE_MAX_PAYLOAD_BYTES", "1000000"))
    end

    # @!attribute [rw] logger
    #   A +Logger+-compatible object. Defaults to +Logger.new($stdout)+ at
    #   +:warn+ level. Inject +Rails.logger+ or any logger you prefer.
    # @return [Logger, nil]
    attr_writer :logger

    def logger
      @logger ||= begin
        require "logger"
        Logger.new($stdout, level: Logger::WARN)
      end
    end

    # -------------------------------------------------------------------------
    # NATS connection auth
    # -------------------------------------------------------------------------

    # @!attribute [rw] nats_creds_file
    #   Path to a NATS +.creds+ file (JWT+nkey). Used by NGS and managed NATS
    #   clusters. Maps to env +TURBOCABLE_NATS_CREDENTIALS_PATH+.
    #   Mutually exclusive with +nats_user+/+nats_token+.
    # @return [String, nil]
    attr_writer :nats_creds_file

    def nats_creds_file
      @nats_creds_file ||= ENV["TURBOCABLE_NATS_CREDENTIALS_PATH"]
    end

    # @!attribute [rw] nats_user
    #   Username for NATS user+password auth. Maps to env
    #   +TURBOCABLE_NATS_USER+.
    # @return [String, nil]
    attr_writer :nats_user

    def nats_user
      @nats_user ||= ENV["TURBOCABLE_NATS_USER"]
    end

    # @!attribute [rw] nats_password
    #   Password for NATS user+password auth. Maps to env
    #   +TURBOCABLE_NATS_PASSWORD+.
    # @return [String, nil]
    attr_writer :nats_password

    def nats_password
      @nats_password ||= ENV["TURBOCABLE_NATS_PASSWORD"]
    end

    # @!attribute [rw] nats_token
    #   Static auth token for NATS token auth. Maps to env
    #   +TURBOCABLE_NATS_AUTH_TOKEN+. Mutually exclusive with +nats_creds_file+.
    # @return [String, nil]
    attr_writer :nats_token

    def nats_token
      @nats_token ||= ENV["TURBOCABLE_NATS_AUTH_TOKEN"]
    end

    # @!attribute [rw] nats_tls
    #   Enable TLS for the NATS connection (default: +false+). Set to +true+
    #   for TLS-only; combine with cert/key/ca fields for mTLS.
    # @return [Boolean]
    attr_writer :nats_tls

    def nats_tls
      return @nats_tls unless @nats_tls.nil?

      @nats_tls = ENV["TURBOCABLE_NATS_TLS"]&.match?(/\A(1|true|yes)\z/i) || false
    end

    # @!attribute [rw] nats_tls_ca_file
    #   Path to a PEM CA certificate file for verifying the NATS server cert.
    #   Maps to env +TURBOCABLE_NATS_TLS_CA_PATH+.
    # @return [String, nil]
    attr_writer :nats_tls_ca_file

    def nats_tls_ca_file
      @nats_tls_ca_file ||= ENV["TURBOCABLE_NATS_TLS_CA_PATH"]
    end

    # @!attribute [rw] nats_tls_cert_file
    #   Path to a PEM client certificate file (mTLS). Maps to env
    #   +TURBOCABLE_NATS_CERT_PATH+.
    # @return [String, nil]
    attr_writer :nats_tls_cert_file

    def nats_tls_cert_file
      @nats_tls_cert_file ||= ENV["TURBOCABLE_NATS_CERT_PATH"]
    end

    # @!attribute [rw] nats_tls_key_file
    #   Path to a PEM client private key file (mTLS). Maps to env
    #   +TURBOCABLE_NATS_KEY_PATH+.
    # @return [String, nil]
    attr_writer :nats_tls_key_file

    def nats_tls_key_file
      @nats_tls_key_file ||= ENV["TURBOCABLE_NATS_KEY_PATH"]
    end

    # -------------------------------------------------------------------------
    # JWT auth
    # -------------------------------------------------------------------------

    # @!attribute [rw] jwt_private_key
    #   PEM-encoded RSA private key used to sign JWTs. Read from env
    #   +TURBOCABLE_JWT_PRIVATE_KEY+ (newlines encoded as +\n+).
    #   Required by +Turbocable::Auth.issue_token+.
    # @return [String, nil]
    attr_writer :jwt_private_key

    def jwt_private_key
      @jwt_private_key ||= ENV["TURBOCABLE_JWT_PRIVATE_KEY"]&.gsub('\n', "\n")
    end

    # @!attribute [rw] jwt_public_key
    #   PEM-encoded RSA public key corresponding to +jwt_private_key+.
    #   Read from env +TURBOCABLE_JWT_PUBLIC_KEY+ (newlines as +\n+).
    #   Required by +Turbocable::Auth.publish_public_key!+ and
    #   +Turbocable::Auth.verify_token+.
    #
    #   *Never* assign the private key here — +publish_public_key!+ will
    #   detect private-key PEM markers and raise +AuthError+.
    # @return [String, nil]
    attr_writer :jwt_public_key

    def jwt_public_key
      @jwt_public_key ||= ENV["TURBOCABLE_JWT_PUBLIC_KEY"]&.gsub('\n', "\n")
    end

    # @!attribute [rw] jwt_issuer
    #   Optional +iss+ claim added to every minted token. The server does not
    #   currently verify +iss+, but setting it is cheap future-proofing and
    #   helps off-platform token debuggers identify the issuer.
    #   Read from env +TURBOCABLE_JWT_ISSUER+.
    # @return [String, nil]
    attr_writer :jwt_issuer

    def jwt_issuer
      @jwt_issuer ||= ENV["TURBOCABLE_JWT_ISSUER"]
    end

    # @!attribute [rw] jwt_kv_bucket
    #   NATS KV bucket name where the public key is published.
    #   Must match the bucket name the server is watching (default:
    #   +"TC_PUBKEYS"+).
    # @return [String]
    attr_writer :jwt_kv_bucket

    def jwt_kv_bucket
      @jwt_kv_bucket ||= ENV.fetch("TURBOCABLE_JWT_KV_BUCKET", "TC_PUBKEYS")
    end

    # @!attribute [rw] jwt_kv_key
    #   Key within +jwt_kv_bucket+ under which the public key PEM is stored.
    #   Default: +"rails_public_key"+ (confirmed in turbocable-server docs).
    # @return [String]
    attr_writer :jwt_kv_key

    def jwt_kv_key
      @jwt_kv_key ||= ENV.fetch("TURBOCABLE_JWT_KV_KEY", "rails_public_key")
    end

    # -------------------------------------------------------------------------
    # Validation
    # -------------------------------------------------------------------------

    # Validates all required fields and raises +ConfigurationError+ on the
    # first violation. Called lazily at publish time, not at configure time.
    #
    # @raise [ConfigurationError] if configuration is invalid
    # @return [void]
    def validate!
      validate_auth_mutual_exclusion!
      validate_tls_paths!
    end

    private

    def validate_auth_mutual_exclusion!
      creds_active = !nats_creds_file.nil? && !nats_creds_file.empty?
      user_active  = (!nats_user.nil? && !nats_user.empty?) ||
                     (!nats_password.nil? && !nats_password.empty?)
      token_active = !nats_token.nil? && !nats_token.empty?

      if creds_active && (user_active || token_active)
        raise ConfigurationError,
          "nats_creds_file is mutually exclusive with nats_user/nats_password " \
          "and nats_token — pick one auth mode"
      end
    end

    def validate_tls_paths!
      %i[nats_tls_ca_file nats_tls_cert_file nats_tls_key_file].each do |attr|
        path = public_send(attr)
        next if path.nil? || path.empty?

        unless File.exist?(path)
          raise ConfigurationError, "#{attr} path does not exist: #{path}"
        end
      end

      if nats_tls_cert_file && !nats_tls_key_file
        raise ConfigurationError,
          "nats_tls_cert_file requires nats_tls_key_file to also be set"
      end

      if nats_tls_key_file && !nats_tls_cert_file
        raise ConfigurationError,
          "nats_tls_key_file requires nats_tls_cert_file to also be set"
      end
    end
  end
end
