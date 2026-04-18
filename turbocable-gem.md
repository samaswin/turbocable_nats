# turbocable_nats (Ruby gem) — Scope & Architecture

> **Status:** Phase 1 complete. This document is the authoritative scope and
> architectural plan for the upstream [`turbocable`](https://github.com/samaswin/turbocable)
> repository (RubyGems package **`turbocable_nats`**). It targets interop with `turbocable-server` as documented in
> [`docs/nats-jetstream.md`](../nats-jetstream.md),
> [`docs/websocket-protocol.md`](../websocket-protocol.md), and
> [`docs/jwt-authentication.md`](../jwt-authentication.md).

---

## 1. Purpose

`turbocable_nats` is a pure-Ruby gem that lets any Ruby application publish messages
to the TurboCable fan-out pipeline by speaking directly to NATS JetStream. It
provides the primitives that `turbocable-rails` is built on, and can be used
standalone by Sinatra apps, Sidekiq workers, Rake tasks, CLI scripts, or any
non-Rails Ruby process.

The gem owns **one direction only**: backend → NATS → gateway. It is not a
WebSocket server, not a subscriber, and does not read from JetStream.

## 1a. Runtime prerequisites

The gem connects directly to **nats-server** (TCP port 4222) — it never
connects to `turbocable-server`. However, `turbocable-server` is still a hard
runtime prerequisite for two reasons:

1. **Stream creation.** `turbocable-server` creates the `TURBOCABLE` JetStream
   stream idempotently on startup (`get_or_create_stream`). The gem deliberately
   never creates or alters the stream. If `turbocable-server` has never booted,
   the stream does not exist and every `Turbocable.broadcast` call fails
   immediately with `PublishError` ("no stream matches subject — is
   turbocable-server running?").

2. **No point without it.** Even if the stream were pre-created manually, NATS
   would just accumulate messages with no consumer. `turbocable-server` is the
   only process that subscribes to `TURBOCABLE.>` and fans messages out to
   WebSocket clients.

**In tests**, the `NullAdapter` (Phase 4) replaces the NATS connection entirely,
removing the dependency on both nats-server and `turbocable-server`. Unit and
adapter-level specs run with no external processes.

Network topology summary:

```
Your Ruby app
(turbocable_nats gem)
      │ TCP :4222  — gem connects HERE
      ▼
 nats-server
      │ JetStream subscribe
      ▼
 turbocable-server   — gem never connects here directly
 (Rust, port 9292)
      │ WebSocket fan-out
      ▼
 Browser / Mobile clients (up to 1M+ concurrent)
```

## 2. Scope

### In scope (MVP)

- NATS JetStream publisher that targets the `TURBOCABLE.*` subject space.
- A `Turbocable.broadcast(stream, payload)` one-liner API.
- Automatic subject encoding (`TURBOCABLE.#{stream_name}`) with stream-name
  validation matching the server's glob authorization rules.
- Payload serialization:
  - JSON (default, `actioncable-v1-json` compatible).
  - MessagePack (opt-in, `turbocable-v1-msgpack` compatible), including ext
    types for `Time` and `Symbol` aligned with the server and JS client
    deserializers.
- Connection management — lazily opened, thread-safe, process-wide singleton
  with a pluggable factory for test isolation.
- JWT signing key publisher — writes the current **RS256 public key** to the
  `TC_PUBKEYS` NATS KV bucket under the `rails_public_key` entry so that
  gateway nodes can hot-reload it. Private key material never leaves the host.
- JWT minting helper for short-lived connection tokens (`sub`, `exp`,
  `allowed_streams`, custom claims).
- Structured logging via a `Logger` injection point.
- Configurable timeouts, max retries, and an exponential backoff for publish
  failures.
- A minimal **dry-run / null adapter** so tests can assert on broadcasts
  without a running NATS server.
- `Turbocable.healthy?` — lightweight health-check helper that publishes a
  ping to a dedicated subject (e.g. `TURBOCABLE._health`). Intended for
  Kubernetes liveness probes. The server-side topology must acknowledge the
  ping for the check to pass.

### Out of scope

- WebSocket hosting or subscription.
- Reading from JetStream (the gateway does that).
- Redis fall-back (TurboCable is NATS-native).
- Rails-specific concerns — those belong in `turbocable-rails`.
- Multi-tenant key management beyond a single `rails_public_key` slot.

## 3. Target users

| User | Use case |
|------|----------|
| Ruby/Sinatra app authors | Publish broadcasts to the fan-out gateway without pulling in Rails. |
| Sidekiq / background workers | Fire-and-forget broadcasts from job code. |
| Rake / CLI scripts | Publish admin notifications from one-shot tooling. |
| `turbocable-rails` | Consume this gem as the transport layer under its DSL. |

## 4. Public API (target shape)

```ruby
require "turbocable_nats"

Turbocable.configure do |config|
  config.nats_url          = ENV.fetch("TURBOCABLE_NATS_URL", "nats://localhost:4222")
  config.stream_name       = "TURBOCABLE"          # server default
  config.subject_prefix    = "TURBOCABLE"          # matches server
  config.default_codec     = :json                 # :json or :msgpack
  config.publish_timeout   = 2.0                   # seconds
  config.max_retries       = 3
  config.jwt_private_key   = File.read(ENV["TURBOCABLE_JWT_PRIVATE_KEY_PATH"])
  config.jwt_public_key    = File.read(ENV["TURBOCABLE_JWT_PUBLIC_KEY_PATH"])
  config.jwt_issuer        = "my-app"
  config.logger            = Rails.logger          # or any Logger
end

# Broadcast to a stream — payload is serialized by the configured codec.
Turbocable.broadcast("chat_room_42", text: "hello")

# Health-check (e.g. for Kubernetes liveness probes).
# Returns true if the server acknowledges the ping; false / raises on failure.
Turbocable.healthy?

# Mint a JWT for a browser client.
token = Turbocable::Auth.issue_token(
  sub: current_user.id,
  allowed_streams: ["chat_room_*", "notifications"],
  ttl: 15 * 60,
)

# Push the current public key to NATS KV (call once at boot / after rotation).
Turbocable::Auth.publish_public_key!
```

### Error surface

- `Turbocable::ConfigurationError` — missing required config at publish time.
- `Turbocable::PublishError` — wraps underlying NATS errors after retries.
- `Turbocable::SerializationError` — payload could not be encoded by the
  chosen codec.
- `Turbocable::InvalidStreamName` — stream name contains characters that
  would break NATS subject parsing (whitespace, wildcards, etc.).

## 5. Architecture

### Component view

```
+-------------------------+       +----------------------+
|  Application code       |       |  turbocable-rails    |
|  (Sinatra / Sidekiq /   |       |  (DSL + callbacks)   |
|   Rake / plain Ruby)    |       +----------+-----------+
+-----------+-------------+                  |
            |                                |
            v                                v
        +--------------------------------------------+
        |              Turbocable::Client            |
        |  - broadcast(stream, payload, codec:)      |
        |  - ensure_connected                        |
        |  - retry + backoff                         |
        +---------------------+----------------------+
                              |
          +-------------------+--------------------+
          |                                        |
          v                                        v
+--------------------+                 +-----------------------+
| Turbocable::Codec  |                 |  Turbocable::NatsConn |
|   ::JSON           |                 |   - JetStream context |
|   ::MsgPack        |                 |   - KV bucket handle  |
+--------------------+                 +-----------+-----------+
                                                   |
                                                   v
                                           NATS JetStream
                                          (TURBOCABLE stream,
                                           TC_PUBKEYS KV bucket)
```

### Module layout

```
lib/turbocable_nats.rb          # RubyGems entry; requires turbocable.rb
lib/turbocable.rb               # top-level constants, autoload
lib/turbocable/version.rb
lib/turbocable/configuration.rb # Configuration struct + validate!
lib/turbocable/client.rb        # publish / broadcast entrypoint
lib/turbocable/nats_connection.rb
lib/turbocable/codecs.rb        # registry
lib/turbocable/codecs/json.rb
lib/turbocable/codecs/msgpack.rb
lib/turbocable/auth.rb          # JWT mint + publish_public_key!
lib/turbocable/errors.rb
lib/turbocable/null_adapter.rb  # in-memory test adapter
```

### Data flow — a single `broadcast`

1. `Turbocable.broadcast("chat_room_42", payload)` calls the client singleton.
2. The client validates the stream name against a conservative regex
   (`A-Za-z0-9_:-`), matching what the glob authorizer accepts.
3. The configured codec serializes `payload` to bytes.
4. The client lazily opens the NATS connection (TCP + JetStream context) on
   first use, guarded by a `Mutex`.
5. It calls `js.publish("TURBOCABLE.chat_room_42", encoded)` with the
   configured `publish_timeout`.
6. On `NATS::IO::Timeout` or `NATS::JetStream::Error`, it retries with
   exponential backoff up to `max_retries`, then raises `PublishError`.
7. On success, it returns the JetStream ack (stream + sequence) to the caller.

### Threading and connection model

- **One NATS client per process.** The `nats-pure` library is thread-safe;
  publishes can fan out from many Ruby threads without serialization.
- **Lazy open, fork-safe reset.** On `Process.fork` (Puma / Unicorn workers),
  the gem detects PID changes and reopens the connection in the child.
- **Forced close on exit.** An `at_exit` hook flushes pending acks and closes
  the connection.

### JWT & key management

- `Turbocable::Auth.issue_token` signs a JWT with `jwt` gem (RS256) using
  `config.jwt_private_key`.
- `Turbocable::Auth.publish_public_key!` writes `config.jwt_public_key` bytes
  into the `TC_PUBKEYS` KV bucket under the `rails_public_key` slot. This is
  the exact slot the Rust gateway watches for hot-reload.
- Key rotation flow: rotate private key locally → update `jwt_public_key` →
  call `publish_public_key!` → gateway picks it up within seconds. Old tokens
  remain valid until `exp`.

## 6. Dependencies

| Gem | Why | Notes |
|-----|-----|-------|
| `nats-pure` (~> 2.4) | Pure-Ruby NATS client with JetStream and KV support | Avoids native extensions; works in all Ruby runtimes |
| `msgpack` (~> 1.7) | MessagePack codec | Optional; only loaded if `:msgpack` codec is configured |
| `jwt` (~> 2.8) | RS256 signing | Standard choice, widely audited |
| `json` (stdlib) | Default codec | No extra dep |

Development-only: `rspec`, `rubocop`, `standard`, `simplecov`, `webmock`,
`nats-server` binary in CI for integration tests.

## 7. Compatibility contract with the server

The gem is tightly coupled to the wire expectations of `turbocable-server`.
Any change here requires a matching change in the server:

| Concern | Contract |
|---------|----------|
| Stream subject | `TURBOCABLE.<stream_name>` — `extract_stream_name` in `src/pubsub/nats.rs` strips the `TURBOCABLE.` prefix |
| JetStream stream | Created by the server (`get_or_create_stream`) with `TURBOCABLE.>`, file storage, 7-day `max_age`, configurable replicas. Gem must not touch it. |
| Payload | Raw bytes; the server tries JSON first, then MessagePack, then null. NATS `MaxMsgSize` (1 MB default) is the effective ceiling. |
| Stream name charset | Must be a valid NATS subject token — no `.`, `*`, `>`, whitespace |
| KV bucket | `TC_PUBKEYS`, key `rails_public_key`, PEM-encoded RSA public key. Server watches but does not create; gem is responsible for bucket lifecycle. Server's `TURBOCABLE_JWT_PUBLIC_KEY_PATH` shadows the KV entry when set. |
| JWT claims | Required: `sub`, `exp`, `iat`, `allowed_streams` (array). Not verified: `iss`, `aud`, `kid`. Clock leeway effectively zero. |
| `allowed_streams` grammar | Exact name, `prefix_*`, or `*` — nothing else is honored. |
| Signing algo | RS256 only — other algorithms are rejected by the gateway |
| NATS auth | The gem must match whatever auth mode (`no-auth`, token, user/pass, creds file, TLS, mTLS) the server operator enabled on `nats-server`. The server itself passes through via `TURBOCABLE_NATS_URL` and peer TLS/creds env vars. |
| Rate limiting | Server's `TURBOCABLE_STREAM_RATE_LIMIT_RPS` may drop messages after successful NATS ack. A successful `broadcast` is not a delivery guarantee. |
| Liveness | `GET http://server:9292/health`, `/metrics`, `/pubkey` all unauthenticated on the WebSocket port. |

## 8. Testing strategy

The reference topology for every integration-level test is **`turbocable-server`
running against `nats-server --jetstream`**. The gem publishes into NATS; the
server fans out over WebSocket. Tests that only talk to NATS miss the half of
the contract that matters to end users.

1. **Unit tests** — codec round-trips, configuration validation, stream-name
   regex, JWT minting with a fixed private key and golden tokens, retry
   backoff logic using an injectable clock.
2. **Adapter tests** — the `NullAdapter` records publishes in-memory so
   dependent gems (including `turbocable-rails`) can assert on broadcasts
   without a live NATS or server.
3. **Integration tests (CI)** — spin up the full stack as Docker Compose
   services: `nats:2.10-alpine` (with `-js`), `ghcr.io/samaswin/turbocable-server:latest`, and
   the Ruby test runner. Each spec:
   - Mints a JWT via `Turbocable::Auth.issue_token`.
   - Publishes the public key via `Turbocable::Auth.publish_public_key!`.
   - Opens a WebSocket to `ws://turbocable-server:9292/cable` with the token.
   - Calls `Turbocable.broadcast(stream, payload)`.
   - Asserts the payload is received over the WebSocket with the expected
     codec framing.
4. **Server health gate** — every integration spec waits on
   `GET http://turbocable-server:9292/health` returning `200` before
   publishing, so flakes from server boot races are visible as setup
   failures rather than assertion failures.
5. **Local dev parity** — a `bin/dev` script in the repo boots the same
   `nats-server` + `turbocable-server` topology locally so authors run the
   same stack CI does. See §12.

## 9. Distribution

- Released to RubyGems.org as `turbocable_nats`.
- Semver. Gem versions stay decoupled from server versions but the README
  documents the minimum compatible server version.
- Source of truth: GitHub repo `samaswin/turbocable`, CI via GitHub Actions
  (Ruby 3.1 / 3.2 / 3.3 matrix).
- `CHANGELOG.md` kept in Keep-a-Changelog format.

## 10. Milestones

| Phase | Deliverable | Exit criteria |
|-------|-------------|---------------|
| 0 — Skeleton | Gemspec, CI, empty module, `rspec` passing on a placeholder | `bundle exec rspec` green on CI |
| 1 — Core publish | `Configuration`, `Client`, `NatsConnection`, JSON codec, `Turbocable.broadcast` | Publishes a message visible on `nats sub 'TURBOCABLE.>'` |
| 2 — Codecs & errors | MessagePack codec, typed error classes, retry/backoff | Unit tests for every error path |
| 3 — Auth & KV | `Turbocable::Auth.issue_token`, `publish_public_key!`, KV watch sanity test | `turbocable-server` picks up a rotated key in < 5 s |
| 4 — Null adapter | `NullAdapter`, documented for test doubles | `turbocable-rails` can run its entire test suite against it |
| 5 — 1.0 | Docs, CHANGELOG, security notes, supported server version matrix | First `1.0.0` release on RubyGems |

## 11. Local development & reference topology

Authors working on the gem — and the CI job that gates every PR — run against
the same topology end users deploy: `nats-server` behind `turbocable-server`.
The gem is never developed against bare NATS alone, because the only
integration surface users care about is the WebSocket fan-out.

### Reference topology

```
  +------------------+        +---------------------+        +---------------+
  |  Ruby test /     |        |  turbocable-server  |        |  WS client    |
  |  dev process     |        |  (Rust, port 9292)  |        |  in specs     |
  |  turbocable_nats |      |                     |        |               |
  +--------+---------+        +----------+----------+        +-------+-------+
           |                             |                           ^
           | JetStream publish           | JetStream consume         | WS frames
           v                             v                           |
           +-----------------------------+---------------------------+
                                   NATS 2.10+
                               (stream TURBOCABLE,
                                KV bucket TC_PUBKEYS)
```

### `bin/dev` script

The repo ships a `bin/dev` script that:

1. Verifies `nats-server --jetstream` is reachable on `nats://127.0.0.1:4222`,
   starting it in the background if not.
2. Pulls and runs `ghcr.io/samaswin/turbocable-server:latest` with
   `TURBOCABLE_NATS_URL=nats://host.docker.internal:4222` exposed on `:9292`.
3. Blocks until `GET http://127.0.0.1:9292/health` returns `200`.
4. Drops the author into an `irb` session with `turbocable_nats` loaded and
   configured, ready for interactive `Turbocable.broadcast` calls.

### Docker Compose for CI and local parity

A `docker-compose.yml` at the repo root starts:

| Service | Image | Notes |
|---------|-------|-------|
| `nats` | `nats:2.10-alpine` | Started with `-js` (Alpine variant for compose healthchecks) |
| `turbocable-server` | `ghcr.io/samaswin/turbocable-server:latest` | Depends on `nats`, exposes `9292` |
| `rspec` | Locally built Ruby image | Mounts the gem source, runs `bundle exec rspec` |

CI invokes this compose file; local authors can run `docker compose up` to
mirror CI exactly. This is the single source of truth for "does the gem work
against the server?".

### Running against a source build of the server

When working on cross-cutting changes (e.g., a new JWT claim or codec quirk),
authors can replace the `ghcr.io/samaswin/turbocable-server:latest` service with a
sibling checkout of `samaswin/turbocable-server` and `cargo run`. The
[server README](https://github.com/samaswin/turbocable-server) documents the
exact steps (`asdf install`, `nats-server --jetstream &`, `cargo build`,
`RUST_LOG=info cargo run`). The gem's `bin/dev --server-from-source` flag
automates the handoff.

## 12. Resolved decisions

| Question | Decision |
|----------|----------|
| **Health-check helper** — bundle `Turbocable.healthy?` that publishes a ping to a dedicated subject? | **Yes.** Included in MVP scope. Useful for Kubernetes liveness probes; the coupling to server-side topology is accepted. See §2 and §4 for API shape. |
| **Raw `publish(subject, bytes)` for power users?** | **Hidden.** Public surface stays purely `broadcast(stream, payload)`. `publish` will not be exposed until a concrete use case justifies it. |
| **MessagePack ext types for `Time` / `Symbol`** | **Yes.** The MessagePack codec will register ext types for `Time` and `Symbol` that match what `turbocable-server` and the JS client deserialize. Exact type IDs must be agreed on across all three packages before the codec is shipped. |
