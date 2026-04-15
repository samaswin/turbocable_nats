# turbocable

Pure-Ruby publisher for the [TurboCable](https://github.com/samaswin/turbocable-server) fan-out pipeline. `turbocable` publishes messages to NATS JetStream on the `TURBOCABLE.*` subject tree, where `turbocable-server` picks them up and fans them out to WebSocket subscribers.

> **Status: Phase 2 — codecs, error surface, retries.** The gem publishes JSON and MessagePack messages to NATS JetStream with exponential-backoff retries. JWT auth (Phase 3) and the null adapter (Phase 4) are still ahead.

## Installation

Add to your `Gemfile`:

```ruby
gem "turbocable", "~> 0.0"
```

Or install directly:

```sh
gem install turbocable
```

## Requirements

- Ruby `>= 3.1`
- A running `turbocable-server` in front of `nats-server` with JetStream enabled (see `docker-compose.yml`)

## Quickstart

```ruby
require "turbocable"

Turbocable.configure do |c|
  # NATS server URL (env: TURBOCABLE_NATS_URL)
  c.nats_url = "nats://localhost:4222"

  # Payload codec: :json (default) or :msgpack (requires msgpack gem)
  c.default_codec = :json

  # JetStream publish ack timeout in seconds
  c.publish_timeout = 2.0

  # How many times to retry on transient NATS failures
  c.max_retries = 3

  # Inject any Logger-compatible object (Rails.logger, Ougai, etc.)
  c.logger = Logger.new($stdout)
end

# Broadcast a payload to the "chat_room_42" stream.
# The message lands on NATS subject "TURBOCABLE.chat_room_42".
ack = Turbocable.broadcast("chat_room_42", text: "hello", user_id: 1)
puts ack.stream  # => "TURBOCABLE"
puts ack.seq     # => 1
```

Boot the server stack locally with `bin/dev` before running your application:

```sh
./bin/dev
# → Starts nats:2.10 + ghcr.io/turbocable/server:latest via Docker Compose
# → Blocks until GET http://127.0.0.1:9292/health returns 200
```

## Configuration reference

| Attribute | Env var | Default | Description |
|-----------|---------|---------|-------------|
| `nats_url` | `TURBOCABLE_NATS_URL` | `nats://localhost:4222` | NATS server URL |
| `stream_name` | `TURBOCABLE_STREAM_NAME` | `TURBOCABLE` | JetStream stream name |
| `subject_prefix` | `TURBOCABLE_SUBJECT_PREFIX` | `TURBOCABLE` | NATS subject prefix |
| `default_codec` | `TURBOCABLE_DEFAULT_CODEC` | `:json` | Codec (`:json` or `:msgpack`) |
| `publish_timeout` | `TURBOCABLE_PUBLISH_TIMEOUT` | `2.0` | Seconds to wait for JetStream ack |
| `max_retries` | `TURBOCABLE_MAX_RETRIES` | `3` | Retry count on transient failures |
| `max_payload_bytes` | `TURBOCABLE_MAX_PAYLOAD_BYTES` | `1_000_000` | Pre-publish size limit |
| `logger` | — | `Logger.new($stdout, level: :warn)` | Logger instance |

### NATS authentication

Pick exactly one auth mode — mixing creds file with user/token raises `ConfigurationError`.

| Mode | Attributes | Env vars |
|------|------------|---------|
| No auth (default) | — | — |
| Credentials file (NGS/managed) | `nats_creds_file` | `TURBOCABLE_NATS_CREDENTIALS_PATH` |
| User + password | `nats_user`, `nats_password` | `TURBOCABLE_NATS_USER`, `TURBOCABLE_NATS_PASSWORD` |
| Static token | `nats_token` | `TURBOCABLE_NATS_AUTH_TOKEN` |
| TLS / mTLS | `nats_tls`, `nats_tls_ca_file`, `nats_tls_cert_file`, `nats_tls_key_file` | `TURBOCABLE_NATS_TLS`, `TURBOCABLE_NATS_TLS_CA_PATH`, `TURBOCABLE_NATS_CERT_PATH`, `TURBOCABLE_NATS_KEY_PATH` |

## Codec selection

### JSON (default)

No extra dependencies. Encodes payloads as UTF-8 JSON strings compatible with the `actioncable-v1-json` WebSocket sub-protocol.

```ruby
Turbocable.broadcast("stream", {text: "hello"})              # uses :json
Turbocable.broadcast("stream", {text: "hello"}, codec: :json) # explicit
```

### MessagePack

Requires the `msgpack` gem (~> 1.7), which is **not** a hard dependency of `turbocable`. Add it to your Gemfile:

```ruby
gem "msgpack", "~> 1.7"
```

Then configure process-wide or override per-call:

```ruby
Turbocable.configure { |c| c.default_codec = :msgpack }

# or per-call:
Turbocable.broadcast("stream", {text: "hello"}, codec: :msgpack)
```

A `LoadError` with install instructions is raised on first use if the gem is absent.

#### Ext type registry (coordinated with JS client)

Ruby-specific types are encoded using MessagePack extension types. The IDs below are the shared contract between this gem and the TurboCable JS client decoder — **do not change them** without a matching update on the JS side.

| Ext type ID | Ruby type | Encoding |
|:-----------:|-----------|----------|
| `0` | `Symbol` | UTF-8 string bytes |
| `1` | `Time` | big-endian int64 (seconds) + int32 (nanoseconds) |

> **Note:** `turbocable-server` uses plain `rmp_serde` and does not interpret ext types. It forwards the raw bytes to WebSocket clients after confirming the payload is valid MessagePack.

## Retry semantics

Failed publishes are retried with exponential backoff (base 50 ms, factor 2, ±20% jitter):

| Attempt | Minimum delay |
|---------|--------------|
| 1 (initial) | — |
| 2 | ~50 ms |
| 3 | ~100 ms |
| 4 | ~200 ms |

Each delay is capped at `config.publish_timeout` so retries never block longer than the ack window. Only `NATS::IO::Timeout` and `NATS::JetStream::Error` trigger retries; all other exceptions propagate immediately.

```ruby
Turbocable.configure do |c|
  c.max_retries     = 3    # default; set 0 to disable retries entirely
  c.publish_timeout = 2.0  # per-attempt ack timeout (seconds); also caps backoff
end
```

After all retries are exhausted `Turbocable::PublishError` is raised with `#subject`, `#attempts`, and `#cause`.

## Error handling

```ruby
begin
  Turbocable.broadcast("my_stream", payload)
rescue Turbocable::InvalidStreamName => e
  # Stream name contains illegal characters (., *, >, whitespace, etc.)
rescue Turbocable::SerializationError => e
  # Payload could not be encoded; e.codec_name and e.payload_class are set
rescue Turbocable::PayloadTooLargeError => e
  # Encoded payload exceeds config.max_payload_bytes; e.byte_size and e.limit
rescue Turbocable::PublishError => e
  # NATS rejected the publish after all retries; e.subject, e.attempts, e.cause
rescue Turbocable::ConfigurationError => e
  # Required config is missing or mutually exclusive options are combined
rescue Turbocable::Error => e
  # Catch-all for any Turbocable error
end
```

## On delivery guarantees

A successful `broadcast` means NATS JetStream has persisted the message. If the
server operator has set `TURBOCABLE_STREAM_RATE_LIMIT_RPS`, messages that exceed
the stream rate limit may be dropped by `turbocable-server` *after* the NATS ack.
A green `broadcast` is a persistence guarantee, not an end-to-end delivery guarantee.

## Development

```sh
bundle install
bundle exec rspec              # unit tests (no NATS required)
bundle exec standardrb         # linter

# Integration tests (requires the compose stack):
./bin/dev                      # boots nats + turbocable-server
INTEGRATION=true bundle exec rspec spec/integration

# Auth-mode integration tests:
docker compose up -d nats-token-auth turbocable-server-token-auth
AUTH_MODE=token-auth TURBOCABLE_NATS_URL=nats://localhost:4223 \
  INTEGRATION=true bundle exec rspec spec/integration/nats_auth_spec.rb
```

The `rspec` service in `docker-compose.yml` mirrors CI exactly:

```sh
docker compose run --rm rspec
```

## License

MIT — see [`LICENSE`](./LICENSE).
