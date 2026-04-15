# frozen_string_literal: true

# Integration spec — requires a running compose stack with turbocable-server.
#
# Run with:
#   docker compose up -d nats turbocable-server
#   INTEGRATION=true bundle exec rspec spec/integration/auth_spec.rb
#
# Or via the CI compose service which sets INTEGRATION=true automatically.
#
# Pre-condition: turbocable-server must be running and reachable before this
# spec starts. The suite-level before(:all) enforces this.

require "net/http"
require "uri"
require "json"
require "openssl"
require "nats/client"

# websocket-client-simple is an optional dev dep used only for the E2E spec.
# If it is not available, the E2E example is pending.
begin
  require "websocket-client-simple"
  WS_CLIENT_AVAILABLE = true
rescue LoadError
  WS_CLIENT_AVAILABLE = false
end

INTEGRATION_ENABLED = ENV["INTEGRATION"] == "true"

RSpec.describe "Auth integration", if: INTEGRATION_ENABLED do
  NATS_URL_AUTH          = ENV.fetch("TURBOCABLE_NATS_URL",         "nats://localhost:4222")
  SERVER_HEALTH_URL_AUTH = ENV.fetch("TURBOCABLE_SERVER_HEALTH_URL", "http://localhost:9292/health")
  SERVER_BASE_URL        = SERVER_HEALTH_URL_AUTH.sub(%r{/health\z}, "")
  SERVER_WS_URL          = ENV.fetch("TURBOCABLE_SERVER_WS_URL",    "ws://localhost:9292/cable")
  HEALTH_TIMEOUT_AUTH    = Integer(ENV.fetch("HEALTH_TIMEOUT_SECS", "30"))

  # Generate a fresh RSA key pair per suite run — no need to pin keys in CI.
  RSA_KEY     = OpenSSL::PKey::RSA.generate(2048)
  PRIVATE_PEM = RSA_KEY.to_pem
  PUBLIC_PEM  = RSA_KEY.public_key.to_pem

  def wait_for_server_health!
    deadline = Time.now + HEALTH_TIMEOUT_AUTH
    uri      = URI(SERVER_HEALTH_URL_AUTH)
    loop do
      begin
        response = Net::HTTP.get_response(uri)
        return if response.is_a?(Net::HTTPOK)
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError
        # not ready yet
      end
      raise "turbocable-server did not become healthy within #{HEALTH_TIMEOUT_AUTH}s" if Time.now > deadline

      sleep 1
    end
  end

  before(:all) do
    wait_for_server_health!
  end

  around do |example|
    Turbocable.reset!
    Turbocable.configure do |c|
      c.nats_url        = NATS_URL_AUTH
      c.jwt_private_key = PRIVATE_PEM
      c.jwt_public_key  = PUBLIC_PEM
      c.jwt_issuer      = "turbocable-integration-spec"
      c.publish_timeout = 5.0
      c.max_retries     = 1
      c.logger          = Logger.new(File::NULL)
    end
    example.run
    Turbocable.reset!
  end

  # =========================================================================
  # KV bucket round-trip
  # =========================================================================
  describe "Turbocable::Auth.publish_public_key!" do
    it "creates the TC_PUBKEYS bucket and writes the public key" do
      revision = Turbocable::Auth.publish_public_key!
      expect(revision).to be_a(Integer)
      expect(revision).to be >= 1

      # Read back via raw nats-pure to confirm the bytes landed
      nc = NATS::IO::Client.new
      nc.connect(NATS_URL_AUTH)
      js = nc.jetstream

      kv = js.key_value("TC_PUBKEYS")
      entry = kv.get("rails_public_key")
      expect(entry.value).to eq(OpenSSL::PKey::RSA.new(PUBLIC_PEM).public_key.to_pem)
    ensure
      nc&.close
    end

    it "is idempotent — calling twice does not raise" do
      Turbocable::Auth.publish_public_key!
      expect { Turbocable::Auth.publish_public_key! }.not_to raise_error
    end
  end

  # =========================================================================
  # End-to-end WebSocket fan-out
  #
  # Full path: gem publishes → NATS JetStream → turbocable-server → WebSocket
  # =========================================================================
  describe "end-to-end WebSocket fan-out", if: WS_CLIENT_AVAILABLE do
    it "delivers a broadcast to a connected subscriber within 2 seconds" do
      # 1. Publish the public key so the gateway can verify tokens.
      Turbocable::Auth.publish_public_key!

      # Allow time for the server's KV watcher to pick up the new key.
      sleep 0.5

      # 2. Mint a token permitting access to the test stream.
      stream  = "e2e_test_#{SecureRandom.hex(4)}"
      token   = Turbocable::Auth.issue_token(
        sub:             "integration_spec_user",
        allowed_streams: [stream],
        ttl:             120
      )

      # 3. Open a WebSocket connection using the token.
      received_messages = []
      ws_error          = nil
      ws_opened         = false

      ws = WebSocket::Client::Simple.connect(
        "#{SERVER_WS_URL}?token=#{token}"
      )

      ws.on(:message) { |msg| received_messages << JSON.parse(msg.data) rescue nil }
      ws.on(:error)   { |e|   ws_error = e }
      ws.on(:open)    { ws_opened = true }

      # Wait for the connection to open
      deadline = Time.now + 5
      sleep 0.1 until ws_opened || ws_error || Time.now > deadline
      raise "WebSocket did not open: #{ws_error}" if ws_error || !ws_opened

      # 4. Subscribe to the stream (ActionCable-style hello + subscribe message)
      ws.send(JSON.generate(command: "subscribe", identifier: JSON.generate(channel: stream)))
      sleep 0.3

      # 5. Broadcast via the gem.
      payload = {text: "e2e hello", seq: rand(10_000)}
      Turbocable.broadcast(stream, payload)

      # 6. Assert the payload arrives on the socket within 2 seconds.
      deadline = Time.now + 2
      sleep 0.1 until received_messages.any? { |m| m.dig("message", "text") == "e2e hello" } || Time.now > deadline

      matching = received_messages.find { |m| m.dig("message", "text") == "e2e hello" }
      expect(matching).not_to be_nil,
        "Expected to receive broadcast payload on WebSocket within 2s. " \
        "Got: #{received_messages.inspect}"
    ensure
      ws&.close rescue nil
    end
  end

  describe "end-to-end WebSocket fan-out", unless: WS_CLIENT_AVAILABLE do
    it "pending — install `websocket-client-simple` gem to enable E2E WebSocket spec" do
      pending "websocket-client-simple not available"
    end
  end

  # =========================================================================
  # Token rejection — wrong key
  # =========================================================================
  describe "token signed with a different key is rejected", if: WS_CLIENT_AVAILABLE do
    it "closes the WebSocket with code 3000 (auth failed)" do
      # Publish the correct key first
      Turbocable::Auth.publish_public_key!
      sleep 0.5

      # Mint a token with a *different* key — the server should reject it
      wrong_key   = OpenSSL::PKey::RSA.generate(2048)
      wrong_token = JWT.encode(
        {sub: "bad_actor", allowed_streams: ["*"], iat: Time.now.to_i, exp: Time.now.to_i + 60},
        wrong_key,
        "RS256"
      )

      close_code = nil
      ws = WebSocket::Client::Simple.connect("#{SERVER_WS_URL}?token=#{wrong_token}")
      ws.on(:close) { |e| close_code = e.code }

      deadline = Time.now + 5
      sleep 0.1 until close_code || Time.now > deadline

      # Server sends close code 3000 on auth failure
      expect(close_code).to eq(3000)
    ensure
      ws&.close rescue nil
    end
  end
end

RSpec.describe "Auth integration", unless: INTEGRATION_ENABLED do
  it "skipped — set INTEGRATION=true and run against the compose stack to enable"
end
