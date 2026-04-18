# API Stability

This document defines the public API surface of the **`turbocable_nats`** gem (the `Turbocable` module) and the compatibility promises made for the **1.0.x** line (from **1.0.0** onward).

The gem follows [Semantic Versioning](https://semver.org/). Since 1.0.0:

- **Patch releases** (1.0.x) — bug fixes only. No breaking changes.
- **Minor releases** (1.x.0) — backward-compatible additions. New methods, new options, new codecs.
- **Major releases** (2.0.0+) — may include breaking changes. Will be listed in `CHANGELOG.md` under **Breaking**.

---

## Public API (stable for the 1.0.x line)

The following are considered part of the public, stable interface. Do not use anything not listed here in production code — unlisted items may change without notice.

### Top-level module methods

| Method | Signature |
|--------|-----------|
| `Turbocable.configure` | `{|Turbocable::Configuration| }` |
| `Turbocable.config` | `→ Turbocable::Configuration` |
| `Turbocable.broadcast` | `(stream_name, payload, codec: nil) → NATS::JetStream::PubAck` |
| `Turbocable.healthy?` | `→ Boolean` |
| `Turbocable.healthcheck!` | `→ true` or raises `HealthCheckError` |

### `Turbocable::Configuration` (public attributes)

All read/write attributes listed in [configuration.md](configuration.md): `nats_url`, `stream_name`, `subject_prefix`, `default_codec`, `publish_timeout`, `max_retries`, `max_payload_bytes`, `logger`, `adapter`, `nats_creds_file`, `nats_user`, `nats_password`, `nats_token`, `nats_tls`, `nats_tls_ca_file`, `nats_tls_cert_file`, `nats_tls_key_file`, `jwt_private_key`, `jwt_public_key`, `jwt_issuer`, `jwt_kv_bucket`, `jwt_kv_key`.

### `Turbocable::Auth`

| Method | Signature |
|--------|-----------|
| `Auth.issue_token` | `(sub:, allowed_streams:, ttl:, **extra_claims) → String` |
| `Auth.publish_public_key!` | `→ Integer` (KV revision) |
| `Auth.verify_token` | `(token) → [Hash, Hash]` |
| `Auth.valid_stream_pattern?` | `(pattern) → Boolean` |

### `Turbocable::NullAdapter` (test adapter)

| Member | Type |
|--------|------|
| `.broadcasts` | `→ Array<Hash>` |
| `.reset!` | `→ void` |
| `NullAck` | Struct with `stream`, `seq`, `duplicate` |

### Error classes

All error classes in `lib/turbocable/errors.rb`:

| Class | Attributes |
|-------|------------|
| `Turbocable::Error` | (base) |
| `Turbocable::ConfigurationError` | — |
| `Turbocable::InvalidStreamName` | — |
| `Turbocable::SerializationError` | `#codec_name`, `#payload_class` |
| `Turbocable::PublishError` | `#subject`, `#attempts`, `#cause` |
| `Turbocable::AuthError` | — |
| `Turbocable::HealthCheckError` | `#cause` |
| `Turbocable::PayloadTooLargeError` | `#byte_size`, `#limit` |

### Codec constants (stable contract with JS client)

| Constant | Value |
|----------|-------|
| `Turbocable::Codecs::MsgPack::EXT_TYPE_SYMBOL` | `0` |
| `Turbocable::Codecs::MsgPack::EXT_TYPE_TIME` | `1` |

These constants define the cross-repo encoding contract between the gem and the TurboCable JS client. They will not change in a minor release. Any change requires a major bump **and** a coordinated JS client update.

---

## Private / internal API (may change)

The following items are explicitly **not** part of the public API. They may change or disappear in a minor release without a deprecation notice.

| Item | Reason |
|------|--------|
| `Turbocable::NatsConnection` | Internal adapter; the interface is defined by the adapter protocol, not this class |
| `Turbocable::NullAdapter#record` | Internal; call `.broadcasts` instead |
| `Turbocable::NullAdapter#publish`, `#ping`, `#close`, `#key_value` | Adapter protocol, not consumer-facing |
| `Turbocable::Codecs::REGISTRY` | Internal registry; do not mutate |
| `Turbocable::Codecs::MsgPack.factory`, `.reset_factory!` | Internal factory management |
| `Turbocable::Client` (direct instantiation) | Use `Turbocable.broadcast` / `Turbocable.client` |
| `Turbocable.client` | Returns the singleton but `Client` itself is not stable |
| `Turbocable.reset!` | Test-only teardown helper; behavior may change |

---

## Breaking changes policy

Before making a breaking change:

1. Add a deprecation warning (`logger.warn "[Turbocable] DEPRECATED: ..."`) in a minor release.
2. Remove the deprecated item in the next major release.
3. Document the migration path in `CHANGELOG.md` under **Breaking**.

Emergency security patches may skip the deprecation cycle. Such patches will be documented as soon as possible.

---

## Version support

| Ruby version | Supported |
|---|---|
| 3.3 | yes |
| 3.2 | yes |
| 3.1 | yes |
| < 3.1 | no |

Older Ruby versions are not tested and may not work. End-of-life Ruby versions will be dropped in a minor release with a CHANGELOG note.
