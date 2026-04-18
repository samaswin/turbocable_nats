# Getting Started

This guide walks you from zero to your first broadcast in a Rails app. For a plain-Ruby process (Sidekiq worker, CLI script, etc.) the same steps apply — skip the Rails-specific parts.

---

## Table of contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Boot the server stack](#boot-the-server-stack)
4. [Configure the gem](#configure-the-gem)
5. [Your first broadcast](#your-first-broadcast)
6. [Rails integration](#rails-integration)
7. [Authentication quickstart](#authentication-quickstart)
8. [Next steps](#next-steps)

---

## Prerequisites

- Ruby **≥ 3.1**
- A running `turbocable-server` backed by `nats-server --jetstream`

The fastest way to get both is with Docker Compose (included in this repo):

```sh
git clone https://github.com/samaswin/turbocable
cd turbocable
./bin/dev   # boots nats:2.10 + ghcr.io/samaswin/turbocable-server:latest
```

`bin/dev` blocks until `GET http://127.0.0.1:9292/health` returns `200`, then keeps the stack running in the foreground. Press `Ctrl-C` to stop.

---

## Installation

Add `turbocable` to your app's `Gemfile`:

```ruby
gem "turbocable", "~> 1.0"
```

Then:

```sh
bundle install
```

---

## Boot the server stack

For local development with your own app, the compose stack in the `turbocable` repo is the easiest starting point:

```sh
# From your turbocable clone:
./bin/dev
```

Alternatively, run just the NATS + server containers and point your app at them:

```sh
docker run -d --name nats -p 4222:4222 nats:2.10 --jetstream
docker run -d --name tc-server \
  -e TURBOCABLE_NATS_URL=nats://host.docker.internal:4222 \
  -p 9292:9292 \
  ghcr.io/samaswin/turbocable-server:latest
```

Confirm the server is healthy before broadcasting:

```sh
curl http://localhost:9292/health
# {"status":"ok","version":"0.5.0","connections":0,"nats_connected":true}
```

---

## Configure the gem

The minimal configuration for a no-auth local setup:

```ruby
require "turbocable"

Turbocable.configure do |c|
  c.nats_url = "nats://localhost:4222"
end
```

Every attribute reads from a corresponding `TURBOCABLE_*` environment variable, so in most deployments you can rely on env vars and skip the `configure` block entirely:

```sh
export TURBOCABLE_NATS_URL=nats://nats:4222
```

See [configuration.md](configuration.md) for the full option reference including NATS auth modes (token, user+password, mTLS, creds file).

---

## Your first broadcast

```ruby
ack = Turbocable.broadcast("chat_room_42", text: "hello", user_id: 1)
# => #<struct NATS::JetStream::PubAck stream="TURBOCABLE", seq=1, duplicate=false>

puts ack.stream   # => "TURBOCABLE"
puts ack.seq      # => 1  (monotonically increasing per stream)
```

`broadcast` returns the JetStream `PubAck` on success. A returned ack means NATS has **persisted** the message — it does not guarantee delivery to WebSocket clients (see [On delivery guarantees](../README.md#on-delivery-guarantees) in the README).

### Payload shape

Payloads must be a JSON-serializable value: `Hash`, `Array`, `String`, `Integer`, `Float`, `true`, `false`, or `nil`. Symbols are valid Hash keys but are not in the JSON spec — use string keys when the receiving JS client expects strings.

```ruby
# Good
Turbocable.broadcast("events", {type: "order_placed", order_id: 99})

# Also good
Turbocable.broadcast("notifications", ["msg1", "msg2"])
```

### Stream name rules

Stream names must match `/\A[A-Za-z0-9_:\-]+\z/`. Characters that break NATS subject parsing (`.`, `*`, `>`, whitespace, non-ASCII) are rejected with `InvalidStreamName` before touching the connection.

---

## Rails integration

### Initializer

Create `config/initializers/turbocable.rb`:

```ruby
Turbocable.configure do |c|
  c.nats_url        = ENV.fetch("TURBOCABLE_NATS_URL", "nats://localhost:4222")
  c.default_codec   = :json
  c.publish_timeout = 2.0
  c.max_retries     = 3
  c.logger          = Rails.logger
end
```

If you are using JWT authentication, add key config and call `publish_public_key!` at boot:

```ruby
Turbocable.configure do |c|
  c.nats_url        = ENV.fetch("TURBOCABLE_NATS_URL")
  c.jwt_private_key = ENV.fetch("TURBOCABLE_JWT_PRIVATE_KEY").gsub('\n', "\n")
  c.jwt_public_key  = ENV.fetch("TURBOCABLE_JWT_PUBLIC_KEY").gsub('\n', "\n")
  c.jwt_issuer      = "my-rails-app"
  c.logger          = Rails.logger
end

# Idempotent — safe to call on every boot. Creates the KV bucket if needed.
Turbocable::Auth.publish_public_key!
```

### Broadcast from a controller or service object

```ruby
class MessagesController < ApplicationController
  def create
    message = Message.create!(message_params)
    Turbocable.broadcast("chat_room_#{message.room_id}", {
      type:    "new_message",
      id:      message.id,
      content: message.content,
      sender:  message.user.display_name
    })
    render json: message, status: :created
  rescue Turbocable::Error => e
    # Log and continue — the HTTP response shouldn't fail because NATS is down
    Rails.logger.error("[Turbocable] broadcast failed: #{e.class} — #{e.message}")
    render json: message, status: :created
  end
end
```

### Issue a JWT for a WebSocket subscriber

```ruby
class TokensController < ApplicationController
  before_action :authenticate_user!

  def create
    token = Turbocable::Auth.issue_token(
      sub:             current_user.id.to_s,
      allowed_streams: ["chat_room_#{params[:room_id]}"],
      ttl:             3600
    )
    render json: {token: token}
  end
end
```

The browser then opens the WebSocket:

```js
const ws = new WebSocket(`wss://example.com/cable?token=${token}`);
```

See [auth.md](auth.md) for the full JWT reference and key-rotation runbook.

---

## Authentication quickstart

If you're not ready to set up JWT authentication yet, run `turbocable-server` with auth disabled:

```sh
TURBOCABLE_JWT_PUBLIC_KEY_PATH=""  # leave blank = auth disabled
```

Broadcasts work without any JWT configuration. Add auth when you're ready to put WebSocket connections behind access control.

---

## Next steps

- [Configuration reference](configuration.md) — all options including TLS and multi-auth modes
- [Codecs](codecs.md) — switch to MessagePack for binary-efficient payloads
- [Authentication](auth.md) — JWT minting, key rotation, allowed-stream patterns
- [Testing](testing.md) — use the null adapter so your test suite doesn't need a live NATS
- [Operations](operations.md) — health checks, logging, retries, Kubernetes probes
