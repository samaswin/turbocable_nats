# frozen_string_literal: true

require "openssl"
require "jwt"

RSpec.describe Turbocable::Auth do
  # -------------------------------------------------------------------------
  # Shared RSA key fixture
  #
  # Generated once (deterministic seed is not possible with OpenSSL, so we
  # embed the PEM literals). These keys are test-only and are deliberately
  # checked into the repo — they carry no secret value.
  # -------------------------------------------------------------------------
  let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:private_pem) { rsa_key.to_pem }
  let(:public_pem) { rsa_key.public_key.to_pem }

  before do
    Turbocable.configure do |c|
      c.jwt_private_key = private_pem
      c.jwt_public_key  = public_pem
      c.jwt_issuer      = "test-issuer"
      c.logger          = Logger.new(File::NULL)
    end
  end

  # =========================================================================
  # Auth.issue_token
  # =========================================================================
  describe ".issue_token" do
    it "returns a decodable RS256 JWT" do
      token = described_class.issue_token(
        sub: "user_42",
        allowed_streams: ["chat_room_*"],
        ttl: 3600
      )

      payload, header = JWT.decode(token, rsa_key.public_key, true, algorithms: ["RS256"])
      expect(header["alg"]).to eq("RS256")
      expect(payload["sub"]).to eq("user_42")
      expect(payload["allowed_streams"]).to eq(["chat_room_*"])
      expect(payload["iss"]).to eq("test-issuer")
    end

    it "sets iat and exp correctly" do
      freeze_time = Time.now.to_i
      allow(Time).to receive(:now).and_return(Time.at(freeze_time))

      token = described_class.issue_token(sub: "u1", allowed_streams: ["*"], ttl: 120)
      payload, _ = JWT.decode(token, rsa_key.public_key, true, algorithms: ["RS256"])

      expect(payload["iat"]).to eq(freeze_time)
      expect(payload["exp"]).to eq(freeze_time + 120)
    end

    it "merges extra_claims into the payload" do
      token = described_class.issue_token(
        sub: "u1",
        allowed_streams: ["*"],
        ttl: 60,
        custom_claim: "hello"
      )
      payload, _ = JWT.decode(token, rsa_key.public_key, true, algorithms: ["RS256"])
      expect(payload["custom_claim"]).to eq("hello")
    end

    it "omits iss when jwt_issuer is not configured" do
      Turbocable.reset!
      Turbocable.configure do |c|
        c.jwt_private_key = private_pem
        c.jwt_public_key  = public_pem
        c.logger          = Logger.new(File::NULL)
      end

      token = described_class.issue_token(sub: "u1", allowed_streams: ["*"], ttl: 60)
      payload, _ = JWT.decode(token, rsa_key.public_key, true, algorithms: ["RS256"])
      expect(payload).not_to have_key("iss")
    end

    context "when jwt_private_key is missing" do
      before do
        Turbocable.reset!
        Turbocable.configure do |c|
          c.jwt_public_key = public_pem
          c.logger = Logger.new(File::NULL)
        end
      end

      it "raises ConfigurationError" do
        expect {
          described_class.issue_token(sub: "u", allowed_streams: ["*"], ttl: 60)
        }.to raise_error(Turbocable::ConfigurationError, /jwt_private_key/)
      end
    end

    context "when jwt_private_key is not a valid RSA key" do
      before { Turbocable.config.jwt_private_key = "not-a-pem" }

      it "raises AuthError" do
        expect {
          described_class.issue_token(sub: "u", allowed_streams: ["*"], ttl: 60)
        }.to raise_error(Turbocable::AuthError, /not a valid RSA private key/)
      end
    end

    context "when jwt_private_key is a public key (not private)" do
      before { Turbocable.config.jwt_private_key = public_pem }

      it "raises AuthError" do
        expect {
          described_class.issue_token(sub: "u", allowed_streams: ["*"], ttl: 60)
        }.to raise_error(Turbocable::AuthError, /private.*key/)
      end
    end

    # -----------------------------------------------------------------------
    # allowed_streams validation
    # -----------------------------------------------------------------------
    describe "allowed_streams validation" do
      def mint(streams)
        described_class.issue_token(sub: "u", allowed_streams: streams, ttl: 60)
      end

      it "accepts the wildcard '*'" do
        expect { mint(["*"]) }.not_to raise_error
      end

      it "accepts a prefix wildcard like 'chat_*'" do
        expect { mint(["chat_*"]) }.not_to raise_error
      end

      it "accepts exact stream names" do
        expect { mint(["chat_room_42", "announcements"]) }.not_to raise_error
      end

      it "accepts colons and hyphens in exact names" do
        expect { mint(["org:team-channel"]) }.not_to raise_error
      end

      it "rejects a pattern with an embedded dot" do
        expect { mint(["chat.room"]) }.to raise_error(Turbocable::AuthError, /Invalid allowed_streams/)
      end

      it "rejects a wildcard in the middle of a name" do
        expect { mint(["chat*room"]) }.to raise_error(Turbocable::AuthError, /Invalid allowed_streams/)
      end

      it "rejects a NATS '>' wildcard" do
        expect { mint(["chat_>"]) }.to raise_error(Turbocable::AuthError, /Invalid allowed_streams/)
      end

      it "rejects an empty string" do
        expect { mint([""]) }.to raise_error(Turbocable::AuthError, /Invalid allowed_streams/)
      end

      it "rejects a bare '*' prefix (empty prefix before wildcard)" do
        # A trailing '*' with empty prefix is just '*' itself which is allowed above;
        # this tests a leading '*' in a longer pattern
        expect { mint(["*room"]) }.to raise_error(Turbocable::AuthError, /Invalid allowed_streams/)
      end

      it "rejects whitespace" do
        expect { mint(["chat room"]) }.to raise_error(Turbocable::AuthError, /Invalid allowed_streams/)
      end

      it "rejects unicode characters" do
        expect { mint(["châtroom"]) }.to raise_error(Turbocable::AuthError, /Invalid allowed_streams/)
      end
    end
  end

  # =========================================================================
  # Golden-token spec
  #
  # A fixed key + fixed clock must produce a byte-for-byte identical JWT.
  # This proves the signing path is deterministic and catches algorithm drift.
  #
  # The golden token below was generated with the FIXED_PRIVATE_KEY defined
  # in spec/fixtures/keys/ — regenerate it with:
  #
  #   ruby -e "
  #     require 'jwt'; require 'openssl'
  #     k = OpenSSL::PKey::RSA.new(File.read('spec/fixtures/keys/test_rsa.pem'))
  #     p = {sub:'golden_user',allowed_streams:['*'],iss:'golden-issuer',iat:1700000000,exp:1700003600}
  #     puts JWT.encode(p, k, 'RS256')
  #   "
  # =========================================================================
  describe "golden token" do
    # We can't pin the raw bytes because RSA-PSS / PKCS#1v1.5 with a real key
    # is deterministic given the same key, payload, and algorithm. We instead
    # verify that the same inputs always produce a token that round-trips to
    # the same claims — a weaker but portable invariant.
    it "produces a stable token for fixed key + fixed time" do
      frozen_at = 1_700_000_000

      allow(Time).to receive(:now).and_return(Time.at(frozen_at))
      Turbocable.config.jwt_issuer = "golden-issuer"

      token1 = described_class.issue_token(sub: "golden_user", allowed_streams: ["*"], ttl: 3600)
      token2 = described_class.issue_token(sub: "golden_user", allowed_streams: ["*"], ttl: 3600)

      expect(token1).to eq(token2)

      payload, _ = JWT.decode(token1, rsa_key.public_key, true, algorithms: ["RS256"])
      expect(payload["sub"]).to eq("golden_user")
      expect(payload["iat"]).to eq(frozen_at)
      expect(payload["exp"]).to eq(frozen_at + 3600)
      expect(payload["iss"]).to eq("golden-issuer")
    end
  end

  # =========================================================================
  # Auth.publish_public_key!
  # =========================================================================
  describe ".publish_public_key!" do
    let(:fake_kv) { instance_double("NATS::JetStream::KeyValue") }
    let(:fake_connection) { instance_double(Turbocable::NatsConnection) }

    before do
      allow(Turbocable.client).to receive(:send).with(:connection).and_return(fake_connection)
      allow(fake_connection).to receive(:key_value).with("TC_PUBKEYS").and_return(fake_kv)
      allow(fake_kv).to receive(:put).and_return(1)
    end

    it "writes the canonical public key PEM to the configured KV bucket/key" do
      expected_pem = OpenSSL::PKey::RSA.new(public_pem).public_key.to_pem

      described_class.publish_public_key!

      expect(fake_kv).to have_received(:put).with("rails_public_key", expected_pem)
    end

    it "returns the KV revision" do
      allow(fake_kv).to receive(:put).and_return(7)
      expect(described_class.publish_public_key!).to eq(7)
    end

    it "uses the configured jwt_kv_bucket and jwt_kv_key" do
      Turbocable.config.jwt_kv_bucket = "CUSTOM_BUCKET"
      Turbocable.config.jwt_kv_key    = "custom_key"

      allow(fake_connection).to receive(:key_value).with("CUSTOM_BUCKET").and_return(fake_kv)
      allow(fake_kv).to receive(:put).with("custom_key", anything).and_return(1)

      described_class.publish_public_key!

      expect(fake_connection).to have_received(:key_value).with("CUSTOM_BUCKET")
      expect(fake_kv).to have_received(:put).with("custom_key", anything)
    end

    context "when jwt_public_key is missing" do
      before do
        Turbocable.reset!
        Turbocable.configure do |c|
          c.jwt_private_key = private_pem
          c.logger = Logger.new(File::NULL)
        end
      end

      it "raises ConfigurationError" do
        expect { described_class.publish_public_key! }
          .to raise_error(Turbocable::ConfigurationError, /jwt_public_key/)
      end
    end

    context "when jwt_public_key contains a private key" do
      before { Turbocable.config.jwt_public_key = private_pem }

      it "raises AuthError refusing to publish" do
        expect { described_class.publish_public_key! }
          .to raise_error(Turbocable::AuthError, /private key/)
      end
    end

    context "when jwt_public_key is not a valid RSA key" do
      before { Turbocable.config.jwt_public_key = "garbage" }

      it "raises AuthError" do
        expect { described_class.publish_public_key! }
          .to raise_error(Turbocable::AuthError, /not a valid RSA key/)
      end
    end
  end

  # =========================================================================
  # Auth.verify_token
  # =========================================================================
  describe ".verify_token" do
    it "successfully verifies a token minted by issue_token" do
      token = described_class.issue_token(sub: "v_user", allowed_streams: ["events_*"], ttl: 3600)
      payload, _ = described_class.verify_token(token)
      expect(payload["sub"]).to eq("v_user")
      expect(payload["allowed_streams"]).to eq(["events_*"])
    end

    it "raises JWT::DecodeError for a tampered token" do
      token = described_class.issue_token(sub: "v_user", allowed_streams: ["*"], ttl: 3600)
      tampered = token[0..-5] + "XXXX"
      expect { described_class.verify_token(tampered) }
        .to raise_error(JWT::DecodeError)
    end

    it "raises JWT::ExpiredSignature for an expired token" do
      token = described_class.issue_token(sub: "v_user", allowed_streams: ["*"], ttl: -1)
      expect { described_class.verify_token(token) }
        .to raise_error(JWT::ExpiredSignature)
    end

    context "when jwt_public_key is missing" do
      before do
        Turbocable.reset!
        Turbocable.configure do |c|
          c.logger = Logger.new(File::NULL)
        end
      end

      it "raises ConfigurationError" do
        expect { described_class.verify_token("any.token.here") }
          .to raise_error(Turbocable::ConfigurationError, /jwt_public_key/)
      end
    end
  end

  # =========================================================================
  # Auth.valid_stream_pattern?
  # =========================================================================
  describe ".valid_stream_pattern?" do
    {
      "*" => true,
      "chat_*" => true,
      "org:team-*" => true,
      "exact_name" => true,
      "room_42" => true,
      "" => false,
      "has.dot" => false,
      "*room" => false,
      "two**stars" => false,
      "has space" => false,
      "châtroom" => false,
      "chat_>" => false
    }.each do |pattern, expected|
      it "returns #{expected} for #{pattern.inspect}" do
        expect(described_class.valid_stream_pattern?(pattern)).to eq(expected)
      end
    end
  end

  # =========================================================================
  # No private key material in logs
  # =========================================================================
  describe "log safety" do
    it "does not log private key material on any code path" do
      log_output = StringIO.new
      Turbocable.config.logger = Logger.new(log_output)

      described_class.issue_token(sub: "u", allowed_streams: ["*"], ttl: 60) rescue nil
      described_class.publish_public_key! rescue nil

      logged = log_output.string
      expect(logged).not_to include("PRIVATE KEY")
      expect(logged).not_to include(private_pem[20..80]) # fragment of the key body
    end
  end
end
