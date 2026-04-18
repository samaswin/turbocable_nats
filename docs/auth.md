# Authentication — JWT Minting & Key Rotation

The TurboCable gateway validates every WebSocket connection with an **RS256 JWT**. The **`turbocable_nats`** gem handles both sides of that contract: minting short-lived tokens for subscribers and publishing the corresponding public key to the NATS KV store that the gateway watches.

---

## Table of contents

1. [Quick start](#quick-start)
2. [How it works](#how-it-works)
3. [Configuration](#configuration)
4. [Minting tokens](#minting-tokens)
5. [Publishing the public key](#publishing-the-public-key)
6. [Key rotation runbook](#key-rotation-runbook)
7. [Allowed-stream patterns](#allowed-stream-patterns)
8. [Security notes](#security-notes)
9. [Testing](#testing)

---

## Quick start

```ruby
# config/initializers/turbocable_nats.rb
Turbocable.configure do |c|
  c.nats_url        = ENV.fetch("TURBOCABLE_NATS_URL")
  c.jwt_private_key = ENV.fetch("TURBOCABLE_JWT_PRIVATE_KEY").gsub('\n', "\n")
  c.jwt_public_key  = ENV.fetch("TURBOCABLE_JWT_PUBLIC_KEY").gsub('\n', "\n")
  c.jwt_issuer      = "my-rails-app"
end

# Once at boot (or after every key rotation):
Turbocable::Auth.publish_public_key!
```

```ruby
# In a controller / channel:
token = Turbocable::Auth.issue_token(
  sub:             current_user.id.to_s,
  allowed_streams: ["chat_room_#{room.id}"],
  ttl:             3600   # 1 hour
)
render json: {token: token}
```

Pass `token` as a query parameter when opening the WebSocket:

```js
const ws = new WebSocket(`wss://example.com/cable?token=${token}`);
```

---

## How it works

```
Rails app                    NATS                turbocable-server
   │                           │                        │
   │── publish_public_key! ──► KV: TC_PUBKEYS ─────────► key_watcher
   │                           │                        │  (hot-reload)
   │                           │                        │
   │── issue_token ──────────────────────────────────────
   │    (RS256 JWT returned to browser)                 │
   │                           │                        │
   │── broadcast(stream, msg) ─► NATS JetStream ───────► fan-out
   │                           │                        │
   │                           │                        │── WS push ──► browser
```

1. **Boot**: `publish_public_key!` writes your RSA public key PEM to the `TC_PUBKEYS` KV bucket. The server's key-watcher picks it up without restarting.
2. **Per-request**: `issue_token` signs a short-lived RS256 JWT the browser uses to authenticate its WebSocket.
3. **Broadcast**: `Turbocable.broadcast` publishes a message to NATS JetStream; the server fans it out to all authenticated WebSocket subscribers.

---

## Configuration

| Config attr | Env var | Default | Notes |
|---|---|---|---|
| `jwt_private_key` | `TURBOCABLE_JWT_PRIVATE_KEY` | `nil` | PEM. Required for `issue_token`. |
| `jwt_public_key`  | `TURBOCABLE_JWT_PUBLIC_KEY`  | `nil` | PEM. Required for `publish_public_key!` and `verify_token`. |
| `jwt_issuer`      | `TURBOCABLE_JWT_ISSUER`      | `nil` | Optional `iss` claim. Server does not verify it today but it aids debugging. |
| `jwt_kv_bucket`   | `TURBOCABLE_JWT_KV_BUCKET`   | `"TC_PUBKEYS"` | Must match the bucket the server watches. Do not change without a coordinated server update. |
| `jwt_kv_key`      | `TURBOCABLE_JWT_KV_KEY`      | `"rails_public_key"` | KV entry name within the bucket. |

**Storing keys in environment variables**: newlines in PEM must be encoded as `\n` literals in most secret stores. The gem's env-var reader automatically converts `\n` → newline, so this just works.

```bash
export TURBOCABLE_JWT_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----"
```

---

## Minting tokens

```ruby
token = Turbocable::Auth.issue_token(
  sub:             "user_42",          # required — unique subject identifier
  allowed_streams: ["chat_room_42"],   # required — see "Allowed-stream patterns"
  ttl:             3600,               # required — lifetime in seconds
  # any extra kwargs become additional JWT claims:
  role: "member"
)
```

**Claims set automatically:**

| Claim | Value |
|---|---|
| `sub` | passed argument |
| `allowed_streams` | passed argument |
| `iat` | `Time.now.to_i` |
| `exp` | `iat + ttl` |
| `iss` | `config.jwt_issuer` (omitted if not set) |

**Clock skew**: the server applies no leeway to `exp`. If your Rails host's clock drifts from the gateway, tokens may be rejected prematurely. Ensure NTP is running on both hosts. A `ttl` of at least 60 seconds is recommended.

---

## Publishing the public key

```ruby
revision = Turbocable::Auth.publish_public_key!
# => 1  (KV revision number)
```

- Creates the `TC_PUBKEYS` bucket if it does not exist (history depth 1).
- Writes the PEM under `rails_public_key`.
- Returns the integer KV revision.
- **Idempotent** — safe to call on every boot.

### File-based key warning

If the server operator set `TURBOCABLE_JWT_PUBLIC_KEY_PATH` to a file, the server **prioritises that file over the KV entry**. KV updates will be silently ignored and tokens signed with the KV key will be rejected.

`publish_public_key!` will log a `:warn` if it detects this condition (by probing `GET /pubkey` on the server). The log message looks like:

```
[Turbocable::Auth] The server at http://localhost:9292/pubkey is serving a different
public key than the one being published to KV. This usually means
TURBOCABLE_JWT_PUBLIC_KEY_PATH is set on the server, which takes precedence over the
KV entry. Tokens signed with the KV key will be rejected until the file-based key is
removed.
```

**Resolution**: unset `TURBOCABLE_JWT_PUBLIC_KEY_PATH` on the server and restart it before rotating keys via KV.

---

## Key rotation runbook

Use this runbook when you need to rotate RSA keys (e.g. scheduled rotation, key compromise).

### Step-by-step

1. **Generate a new key pair**:

   ```bash
   openssl genrsa -out new_private.pem 2048
   openssl rsa -in new_private.pem -pubout -out new_public.pem
   ```

2. **Deploy the new keys** to your Rails app's secrets/environment variables (`TURBOCABLE_JWT_PRIVATE_KEY`, `TURBOCABLE_JWT_PUBLIC_KEY`). Do **not** restart yet.

3. **Publish the new public key** to NATS KV (before restarting the app):

   ```ruby
   # In a Rails console or a one-shot rake task:
   Turbocable.configure do |c|
     c.jwt_public_key = File.read("new_public.pem")
   end
   Turbocable::Auth.publish_public_key!
   ```

4. **Wait for gateway hot-reload** (~5 seconds). The server's key-watcher picks up the new entry from KV without a restart. You can confirm with:

   ```bash
   curl http://localhost:9292/pubkey
   # Should return the new public key PEM
   ```

5. **Restart (or rolling-restart) the Rails app** so it picks up the new `TURBOCABLE_JWT_PRIVATE_KEY`. From this point all newly minted tokens use the new key.

6. **Old tokens remain valid** until their `exp` claim passes. No forced logout is required unless you are responding to a compromise.

### Compromise response

If a private key is compromised:

1. Follow steps 1–5 immediately. The server will start rejecting old-key tokens as soon as the hot-reload completes (step 4).
2. If you need to revoke all existing sessions before their `exp`, issue a deploy with `ttl: 0` or force-close all WebSocket connections at the gateway level.

---

## Allowed-stream patterns

The server's authorizer supports three pattern forms:

| Pattern | Meaning |
|---|---|
| `"*"` | Any stream |
| `"prefix_*"` | Any stream whose name starts with `prefix_` (non-empty prefix, single trailing wildcard) |
| `"exact_name"` | A single, exact stream name |

**Rules enforced by `issue_token` at mint time:**

- The prefix in `prefix_*` must match `/\A[A-Za-z0-9_:\-]+\z/` — no dots, no spaces, no Unicode.
- The `*` wildcard may only appear as the last character.
- `>` is not a supported wildcard in stream patterns (it is a NATS subject wildcard, not a stream-level concept).
- An empty string is rejected.

Any violation raises `Turbocable::AuthError` before signing.

---

## Security notes

- **Never log private key material.** The gem never logs private key PEM at any log level. If you extend `issue_token`, ensure your code also avoids logging `jwt_private_key`.
- **`jwt_public_key` must be the public half.** `publish_public_key!` detects `PRIVATE KEY` PEM markers in the `jwt_public_key` field and raises `AuthError` rather than broadcasting your private key to NATS.
- **Store keys in a secrets manager**, not in version-controlled config files. Reference them via environment variables.
- **NATS KV access permissions**: the NATS credential used by the publisher must have `kv:put` permission on `TC_PUBKEYS`. See your NATS operator's policy docs.
- **`verify_token` is for testing only.** The gateway verifies tokens internally; there is no need (and some risk) to re-verify in production request paths.

---

## Testing

Use `Turbocable::Auth.verify_token` in your test suite to confirm tokens are well-formed:

```ruby
token = Turbocable::Auth.issue_token(sub: "u1", allowed_streams: ["room_*"], ttl: 60)
payload, _ = Turbocable::Auth.verify_token(token)
expect(payload["sub"]).to eq("u1")
expect(payload["allowed_streams"]).to contain_exactly("room_*")
```

For unit tests that should not hit NATS, stub `publish_public_key!`:

```ruby
allow(Turbocable::Auth).to receive(:publish_public_key!).and_return(1)
```

For full end-to-end coverage, see `spec/integration/auth_spec.rb` which exercises the `gem → NATS KV → turbocable-server → WebSocket` path against a live compose stack.
