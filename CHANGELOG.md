# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_No unreleased changes._

---

## [1.0.0] - 2026-04-15

### Added

- **Phase 5 — 1.0 Release**
  - Full YARD documentation on every public method; `yard stats --list-undoc` returns 100%.
  - `docs/` directory: `getting-started.md`, `configuration.md`, `codecs.md`, `auth.md`,
    `testing.md`, `operations.md`, `api-stability.md`.
  - Security threat-model section in `docs/auth.md` covering JWT handling, private-key
    storage, log redaction, and KV access permissions.
  - Supported-server compatibility matrix in README (turbocable-server ≥ 0.5.0).
  - Trusted RubyGems publishing workflow (`.github/workflows/release.yml`) using OIDC —
    no long-lived API keys stored in repository secrets.
  - Version pinned to `1.0.0`; public API surface locked down in `docs/api-stability.md`.

---

## [0.5.0] - 2026-04-15

### Added

- **Phase 4 — Null Adapter & Health Check**
  - `Turbocable::NullAdapter`: drop-in replacement for `NatsConnection` that records
    every broadcast in a thread-safe in-memory ring buffer (default size: 1 000).
    Exposes `.broadcasts`, `.reset!`, and a `NullAck` struct.
  - Adapter selection via `config.adapter = :nats` (default) or `:null`.
    Also readable from env `TURBOCABLE_ADAPTER`.
  - `NullAdapter#key_value` raises `NotImplementedError` so callers cannot silently
    succeed with KV operations against the null adapter.
  - `Turbocable.healthy?` — client-side NATS probe: opens the connection with a short
    timeout, issues a flush (PING/PONG round-trip), and returns `true`/`false` without
    raising on network errors.
  - `Turbocable.healthcheck!` — strict variant that raises `HealthCheckError` on failure.
  - `Turbocable::HealthCheckError` error class with `#cause`.
  - README sections: null adapter usage in RSpec/Minitest; Kubernetes `livenessProbe`
    example; clarification that `healthy?` is a publisher→NATS probe only.

---

## [0.4.0] - 2026-04-15

### Added

- **Phase 3 — Auth: JWT Minting & Public Key Publishing**
  - `Turbocable::Auth.issue_token(sub:, allowed_streams:, ttl:, **extra_claims)`:
    mints RS256 JWTs with `sub`, `allowed_streams`, `iat`, `exp`, and optional `iss`.
    Validates every `allowed_streams` entry against the server's supported glob grammar
    (`"*"`, `"prefix_*"`, exact name) at mint time.
  - `Turbocable::Auth.publish_public_key!`: creates the `TC_PUBKEYS` KV bucket if absent
    (the server watches but never creates it), writes the public key PEM under
    `rails_public_key`, returns the KV revision. Detects and warns when
    `TURBOCABLE_JWT_PUBLIC_KEY_PATH` on the server would shadow the KV entry.
  - `Turbocable::Auth.verify_token(token)`: decodes and verifies a JWT for use in test
    suites. Not intended for production request paths.
  - `Turbocable::Auth.valid_stream_pattern?(pattern)`: public helper to pre-validate
    allowed-stream patterns without minting a token.
  - `Turbocable::AuthError` error class for key-material and pattern-validation failures.
  - `NatsConnection#key_value(bucket, history:)`: returns a NATS KV handle, creating
    the bucket with sensible defaults if it does not yet exist.
  - Configuration attributes: `jwt_private_key`, `jwt_public_key`, `jwt_issuer`,
    `jwt_kv_bucket` (default `"TC_PUBKEYS"`), `jwt_kv_key` (default `"rails_public_key"`).
    All readable from env vars with automatic `\n` → newline conversion for PEM material.
  - `docs/auth.md`: JWT quick start, how-it-works diagram, configuration reference,
    minting tokens, publishing the public key, key-rotation runbook, allowed-stream
    patterns, security notes, and testing guidance.

---

## [0.3.0] - 2026-04-15

### Added

- **Phase 2 — Codecs, Error Surface, Retries**
  - `Turbocable::Codecs::MsgPack`: MessagePack codec with ext types for `Symbol`
    (`EXT_TYPE_SYMBOL = 0`) and `Time` (`EXT_TYPE_TIME = 1`). IDs coordinated with the
    TurboCable JS client; the server treats the payload as opaque bytes.
  - Lazy-loads the `msgpack` gem on first use; raises `LoadError` with install
    instructions if absent.
  - Exponential backoff retry loop in `Client#broadcast`: base 50 ms, factor 2, ±20%
    jitter, capped at `config.publish_timeout`. Only `NATS::IO::Timeout` and
    `NATS::JetStream::Error` trigger retries.
  - Configurable via `config.max_retries` (default 3); injectable clock for
    deterministic testing.
  - `PublishError` enriched with `#subject`, `#attempts`, and `#cause`.
  - `Turbocable::SerializationError` with `#codec_name` and `#payload_class`.
  - `Turbocable::PayloadTooLargeError` with `#byte_size` and `#limit`.
  - Structured logging: `:debug` per-attempt, `:warn` per-retry, `:error` final failure.
    Payload bodies are never logged.
  - README sections: codec selection, retry semantics, error-handling reference.

---

## [0.2.0] - 2026-04-15

### Added

- **Phase 1 — Core Publish Path (JSON only)**
  - `Turbocable::Configuration` with full transport options (`nats_url`, `stream_name`,
    `subject_prefix`, `default_codec`, `publish_timeout`, `max_retries`,
    `max_payload_bytes`, `logger`) and five NATS auth modes (no-auth, creds file,
    user+password, static token, TLS/mTLS). Every attribute reads from a corresponding
    `TURBOCABLE_*` env var.
  - `Configuration#validate!` raises `ConfigurationError` on mutual-exclusion violations
    and missing TLS paths. Validated lazily at publish time.
  - `Turbocable.configure { |c| … }` / `Turbocable.config` process-wide singleton,
    guarded by a `Mutex`.
  - `Turbocable::Errors` module: `Error`, `ConfigurationError`, `PublishError`,
    `SerializationError`, `InvalidStreamName`, `PayloadTooLargeError`.
  - `Turbocable::Codecs::JSON` with `.encode`, `.decode`, `.content_type`
    (`"actioncable-v1-json"`). Validates primitive types before calling `JSON.generate`
    to prevent silent coercion.
  - `Turbocable::Codecs` registry with lazy-codec support and `.fetch(name)`.
  - `Turbocable::NatsConnection`: lazy NATS connection, PID-aware fork detection,
    `at_exit` flush/close, JetStream publish, `#ping`, `#key_value`.
  - `Turbocable::Client#broadcast(stream_name, payload, codec:)`: validates stream name
    against `/\A[A-Za-z0-9_:\-]+\z/`, enforces `max_payload_bytes`, delegates to
    `NatsConnection`.
  - `Turbocable.broadcast` top-level convenience delegating to the client singleton.
  - Integration spec: boots compose stack, waits on `/health`, publishes via gem,
    confirms JetStream receipt.
  - Auth-mode integration specs (no-auth, token-auth, user-pass, mtls).
  - `bin/dev` script: boots nats + turbocable-server via Docker Compose, blocks until
    `GET :9292/health` returns `200`.
  - README quickstart, configuration reference, NATS auth mode table.

---

## [0.0.1] - 2026-04-15

### Added

- **Phase 0 — Skeleton & Repository Bootstrap**
  - Gem scaffolding with `turbocable.gemspec`: MIT license, Ruby ≥ 3.1, no runtime
    dependencies yet.
  - `lib/turbocable.rb` and `lib/turbocable/version.rb` (`VERSION = "0.0.1"`).
  - RSpec with `spec/spec_helper.rb`; SimpleCov wired in, threshold 90%.
  - `standard` + `rubocop-rspec` with `.rubocop.yml` inheriting from `standard`.
  - GitHub Actions CI matrix: Ruby 3.1 / 3.2 / 3.3 on `ubuntu-latest` running
    `bundle exec rspec`, `bundle exec standardrb`, and `gem build`.
  - Dependabot for `bundler` and `github-actions` ecosystems.
  - `docker-compose.yml` scaffold pinning `nats:2.10` and
    `ghcr.io/samaswin/turbocable-server:latest`.
  - `bin/dev` stub that boots the compose stack and blocks on `GET :9292/health`.
  - `CHANGELOG.md`, `README.md` (one-paragraph pitch + status), `LICENSE` (MIT).

[Unreleased]: https://github.com/samaswin/turbocable/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/samaswin/turbocable/compare/v0.5.0...v1.0.0
[0.5.0]: https://github.com/samaswin/turbocable/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/samaswin/turbocable/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/samaswin/turbocable/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/samaswin/turbocable/compare/v0.0.1...v0.2.0
[0.0.1]: https://github.com/samaswin/turbocable/releases/tag/v0.0.1
