# OpenSMS Gateway

A self-hosted SMS gateway. An **Express relay** queues outbound messages over HTTP/WebSocket, and an
**Android app** picks them up and sends them silently through the phone's SIM card, reporting the
result back.

Useful when you need programmatic SMS (2FA, alerts, notifications) without paying an SMS provider and
with a SIM you already own.

```
   your service                  relay (this repo)                  phone
 ┌───────────────┐            ┌──────────────────────┐          ┌──────────────────┐
 │ POST /sms/send│──X-API-KEY▶│  queue (in-memory)   │──ws sms─▶│ Gateway app      │
 │ GET  /status  │◀───JSON────│  devices  ·  reaper  │◀─status──│ SmsManager → SIM │
 └───────────────┘            └──────────────────────┘          └──────────────────┘
```

| Piece | Stack | Where |
|---|---|---|
| Relay | Node ≥ 18.17, Express 5, `ws`, ESM | [`server/`](server/) |
| Gateway | Flutter 3.35.7 (FVM-pinned), Kotlin `SmsManager` + foreground service | [`app/`](app/) |

> ⚠️ SMS is a paid, regulated resource. Read [Security & legal](#security--legal) before pointing this
> at a real SIM.

---

## Layout

```
opensms-flutter-and-node/
├── server/                 Express + WebSocket relay
│   ├── server.js           config, store, HTTP routes, WS gateway, reaper, bootstrap
│   ├── test/smoke.test.mjs node:test suite (auth, queue, ws, status)
│   ├── .env.example        every setting, documented
│   └── package.json        "start" / "dev" / "test"
├── app/                    Flutter Android gateway
│   ├── lib/main.dart       config persistence, WS client, queue, status reporter, UI
│   ├── android/…/MainActivity.kt                  MethodChannel `opensms/gateway`
│   ├── android/…/GatewayForegroundService.kt      keeps the socket alive
│   ├── .fvmrc              pins Flutter 3.35.7
│   └── pubspec.yaml        http, web_socket_channel, permission_handler, shared_preferences
├── docs/cloudflare-tunnel.md   exposing the relay publicly with `cloudflared`
└── README.md               this file
```

---

## Quick start

### 1. Relay

```bash
cd server
cp .env.example .env          # edit: API_KEYS, DEVICE_TOKENS, ADMIN_TOKEN
npm install
npm start                     # → http://0.0.0.0:3000
curl -s localhost:3000/health
# {"status":"ok","version":"1.0.0","env":"development","uptimeSeconds":1,"devicesOnline":0,"queueDepth":0}
```

No credentials configured? The server mints one API key and one device token at boot and prints them
once. For anything beyond a smoke test, set them in `.env`.

State is **in memory**: restarting the relay drops the queue, the registered devices and the keys
created through the admin API (env-seeded keys are recreated).

### 2. Gateway app

```bash
cd app
fvm install 3.35.7            # honours .fvmrc
fvm flutter pub get
fvm flutter run -d <device>   # emulator or a USB phone with USB debugging on
```

In the app: paste the relay URL (e.g. `https://sms.example.com` or `http://192.168.1.20:3000`), paste
the **device token**, tap **Test server**, then flip **Gateway service** on. The status pill turns
`Connected` and the server reports `devicesOnline: 1`.

The app derives the WebSocket URL itself (`http→ws`, `https→wss`, `…/ws` appended), keeps the socket
alive with a foreground service, reconnects with exponential backoff + jitter, dedupes by message id,
buffers status reports while offline and asks to be exempted from battery optimisation.

---

## Configuration (`server/.env`)

| Variable | Default | Purpose |
|---|---|---|
| `PORT` / `HOST` | `3000` / `0.0.0.0` | HTTP + WS listener |
| `WS_PATH` | `/ws` | WebSocket endpoint |
| `API_KEYS` | — | comma-separated keys allowed to call `/api/v1/sms/*` |
| `DEVICE_TOKENS` | — | comma-separated tokens a gateway may authenticate with |
| `ADMIN_TOKEN` | — | bearer token for `/api/v1/admin/*`; **empty ⇒ admin disabled (503)** |
| `CORS_ORIGINS` | `*` | comma-separated origins or `*` |
| `MESSAGE_TTL_MS` | `86400000` | drop messages older than this (→ `Failed`) |
| `STUCK_TIMEOUT_MS` | `120000` | requeue a message stuck in `Sending` |
| `MAX_ATTEMPTS` | `3` | attempts before a message is `Failed` |
| `RATE_LIMIT_WINDOW_MS` / `RATE_LIMIT_MAX` | `60000` / `120` | fixed-window limit per API key |
| `BODY_LIMIT` | `64kb` | JSON body cap |
| `WS_HEARTBEAT_MS` | `30000` | server-side WS ping interval |
| `WS_AUTH_GRACE_MS` | `10000` | time a socket may stay unauthenticated |

Limits: recipient must be E.164-ish (`+15551234567`, up to 16 chars), message ≤ 1600 characters.

---

## HTTP API

Machine routes use `X-API-KEY` (or `Authorization: apikey <key>`); admin routes use
`Authorization: Bearer <ADMIN_TOKEN>`.

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/` | – | service banner + route list |
| `GET` | `/health` | – | `{status, version, env, uptimeSeconds, devicesOnline, queueDepth}` |
| `POST` | `/api/v1/sms/send` | API key | queue a message → `202` `{id, status, statusUrl, devicesOnline}` |
| `GET` | `/api/v1/sms/status/:id` | API key | one message |
| `GET` | `/api/v1/sms?status=Pending&limit=50` | API key | recent outbox, newest first |
| `GET` | `/api/v1/admin/stats` | admin | counters + uptime |
| `POST` | `/api/v1/admin/keys` | admin | create key → raw secret returned **once** |
| `GET`/`DELETE` | `/api/v1/admin/keys[/:id]` | admin | list / revoke |
| `POST` | `/api/v1/admin/device-tokens` | admin | create device token |
| `GET`/`DELETE` | `/api/v1/admin/device-tokens[/:id]` | admin | list / revoke |
| `GET` | `/api/v1/admin/devices` | admin | connected gateways |

```bash
# queue
curl -X POST http://localhost:3000/api/v1/sms/send \
  -H "X-API-KEY: $API_KEY" -H "Content-Type: application/json" \
  -H "Idempotency-Key: order-4711-3" \
  -d '{"to":"+15551234567","message":"Your code is 123456"}'

# follow up
curl -H "X-API-KEY: $API_KEY" http://localhost:3000/api/v1/sms/status/<id>
```

`Idempotency-Key` makes retries safe: the same key returns the original message with
`idempotentReplay: true`. Errors are uniform: `{"error":{"code","message","details?}}`; every response
carries `X-Request-Id` (echoed from the request when supplied) and the rate-limit headers
`X-RateLimit-Limit/Remaining/Reset`.

Message object: `{id, to, message, status, attempts, deviceId, error, createdAt, updatedAt, sentAt}`.

---

## WebSocket protocol

```
wss://<host>/ws?token=<device-token>&deviceId=<optional>&appVersion=<optional>
```

The token may instead be sent as `X-Device-Token` / `Authorization: Bearer …`, or kept out of proxy
logs entirely by sending a `hello` frame within `WS_AUTH_GRACE_MS`. An invalid token is rejected during
the HTTP upgrade.

**Server → device**

| `type` | Fields | Meaning |
|---|---|---|
| `welcome` | `deviceId, pending, serverTime, serverVersion` | authenticated |
| `sms` | `id, to, message, createdAt, attempt` | send this now |
| `ack` | `id, status, duplicate?` | status report accepted |
| `pong` | `ts` | answer to `ping` |
| `error` | `code, message` | bad frame / unknown id / invalid status |
| `auth_error` | `reason` | `invalid_token`, `not_authenticated`, `auth_timeout` |
| `server_shutdown` | `retryInMs` | reconnect shortly |

**Device → server**

| `type` | Fields | Meaning |
|---|---|---|
| `hello` | `token, deviceId, appVersion` | authenticate late (grace window only) |
| `status_update` | `id, status: "sent"\|"failed", error?` | result of an SMS |
| `ping` / `pong` | — | app-level heartbeat |

Exactly **one SMS is in flight per device**, which preserves ordering; disconnects requeue the
in-flight message. A device reconnecting with the same `deviceId` replaces the older socket
(close code `4000`).

---

## Message lifecycle

```
        POST /sms/send
              │
              ▼
          ┌────────┐  WS sms   ┌─────────┐ status sent ┌──────┐
          │Pending │──────────▶│ Sending │────────────▶│ Sent │
          └────────┘           └─────────┘             └──────┘
              ▲                     │ status failed / device drop
              │  requeue (< MAX_ATTEMPTS)
              └─────────────────────┴──────────────▶ ┌────────┐
                       attempts exhausted / TTL      │ Failed │
                                                     └────────┘
```

A 15 s reaper retries messages stuck in `Sending` beyond `STUCK_TIMEOUT_MS` and expires messages older
than `MESSAGE_TTL_MS`.

---

## Android gateway details

- **Permissions** (`app/android/app/src/main/AndroidManifest.xml`): `SEND_SMS`, `RECEIVE_SMS`,
  `READ_PHONE_STATE`, `READ_PHONE_NUMBERS`, `INTERNET`, `ACCESS_NETWORK_STATE`, `WAKE_LOCK`,
  `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE`, `POST_NOTIFICATIONS`, optional
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
- **Sending**: Kotlin `MethodChannel opensms/gateway` → `SmsManager` with per-part `SENT` pending
  intents, so multipart messages report accurately. No SMS composer UI is ever shown.
- **Persistence**: relay URL + device token in `SharedPreferences`; the foreground service keeps the
  socket alive with an ongoing notification.
- **Build**: `minSdk 24`, `applicationId com.opensms.gateway`, `compileSdk`/`targetSdk` from the
  Flutter SDK defaults, `usesCleartextTraffic="true"` for local `http://` development (remove it for
  production and use `https://`/`wss://`).

---

## Development in WSL + Windows device

The project is developed in WSL (Ubuntu) on Windows, with Flutter managed by FVM, while the phone or
emulator and the Android **adb server** stay on Windows. The Linux `adb` client is pointed at the
Windows server, so Windows USB devices appear inside WSL.

```bash
# once per Windows boot
adb.exe -a -P 5037 nodaemon server        # on Windows, all interfaces
export ANDROID_ADB_SERVER_ADDRESS=$(ip route show default | awk '{print $3}')
export ANDROID_ADB_SERVER_PORT=5037

cd app
fvm flutter run -d <serial>               # hot reload on the physical phone
fvm flutter build apk --debug
```

A Gradle debug build wants a real 4 GB heap: give WSL enough RAM (`.wslconfig` with
`memory=8GB`, `swap=8GB`) or the Linux OOM killer will take out the Gradle JVM
(`Gradle build daemon disappeared unexpectedly`).

For exposing the relay to a phone on mobile data, see [`docs/cloudflare-tunnel.md`](docs/cloudflare-tunnel.md).

---

## Tests

```bash
cd server
npm test          # node --test test/ — auth, queueing, WebSocket dispatch, status updates
```

---

## Security & legal

- **Tokens are hashed at rest** (SHA-256) and compared in constant time; admin routes are disabled
  unless `ADMIN_TOKEN` is set. Keys created via the admin API are shown once.
- **Transport**: terminate TLS at a reverse proxy or tunnel; the API rejects nothing you send in
  cleartext, so the network is your responsibility.
- **Silent SMS is restricted**: Google Play requires the default-SMS-handler role (or a policy
  exception) for `SEND_SMS`. This app is meant for sideloaded/internal devices, not Play distribution.
- **Costs and consent**: every queued message is a real, billable SMS from your SIM. Do not leave a
  public API key active, and only use it for recipients who opted in.
- **In-memory state**: not a database. Put Redis/Prisma behind `store` before trusting it with real
  traffic; a restart loses queued messages.

---

## Status

The relay, gateway, protocol and tooling are implemented and exercised end to end: a physical phone
authenticated over a Cloudflare tunnel, received a `welcome`, and reported `devicesOnline: 1`.
Queued SMS are dispatched one at a time per device, with retries and status callbacks.

Not production-ready as-is: the store is in-memory (no database), there is no user model, and Play
Store distribution would need the default-SMS-handler role or a policy exception.
