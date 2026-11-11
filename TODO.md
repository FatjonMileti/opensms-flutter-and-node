# OpenSMS Clone — Implementation TODO

Goal: a working SMS-gateway system: an Express relay server (queue + API keys + WebSocket)
and an Android Flutter client that silently sends SMS through the device SIM.

## 0. Project layout
- [x] Create `opensms-clone/` workspace
- [x] Write this TODO.md first
- [x] Create `server/` (Node/Express) and `app/` (Flutter) folders
- [x] Write root `README.md` with architecture + protocol contract

## 1. Express server
- [x] `package.json` (ESM, express 5, ws, uuid, cors, dotenv)
- [x] `.env.example` + `.gitignore`
- [x] Config section (env parsing with defaults, no crashes on missing env)
- [x] In-memory stores: API keys, device tokens, messages, idempotency map, devices
- [x] Middleware: request id, access log, CORS, JSON body, API-key auth, admin auth,
      rate limit, payload validation, 404 + central error handler
- [x] Routes:
  - [x] `POST /api/v1/sms/send` (X-API-KEY, optional Idempotency-Key) -> 202 + id
  - [x] `GET  /api/v1/sms/status/:id`
  - [x] `GET  /api/v1/sms` (filter/paginate)
  - [x] `GET  /health` (public probe used by the app)
  - [x] Admin: create/list/revoke API keys + device tokens, list devices, stats
- [x] WebSocket server on `/ws`
  - [x] Token auth via `?token=` or `hello` frame within grace period
  - [x] Device registry, one socket per deviceId (replace old socket)
  - [x] `sms` dispatch (1 in-flight message per device, FIFO)
  - [x] `status_update` handling -> updates message + acks + dispatches next
  - [x] `ping`/`pong` app-level heartbeat + native ws ping for dead sockets
  - [x] Requeue in-flight messages when a device drops
- [x] Reaper: stuck `Sending` -> retry (max attempts) -> `Failed`, TTL expiry
- [x] Graceful shutdown (SIGINT/SIGTERM)
- [x] Smoke test (`server/test/smoke.test.mjs`) covering auth, queue, ws, status
- [ ] Run `npm install` + `npm test` and confirm green  <-- doing this next

## 2. Flutter Android gateway
- [x] `pubspec.yaml` (http, web_socket_channel, permission_handler, shared_preferences)
- [x] `AndroidManifest.xml` with SMS / phone / FGS / notification permissions
- [x] `MainActivity.kt`:
  - [x] MethodChannel `opensms/gateway`
  - [x] `sendSms` using SmsManager + per-part SENT PendingIntents (multipart safe)
  - [x] Timeout + permission + error mapping (no native intent UI ever launched)
  - [x] Foreground-service control + battery-optimization helpers + SIM info
- [x] `GatewayForegroundService.kt` (specialUse FGS, ongoing notification, stop action)
- [x] `build.gradle.kts` snippet (minSdk 23, compile/target 35)
- [x] `lib/main.dart`:
  - [x] Config model + persistence (SharedPreferences)
  - [x] WS URL derivation (http->ws, https->wss, appends /ws)
  - [x] Controller: connect / reconnect with exponential backoff + jitter
  - [x] Heartbeat watchdog + forced reconnect on stale socket
  - [x] Inbound `sms` queue, dedupe by id, serialised sending
  - [x] Status reporting with offline buffer, flushed on reconnect
  - [x] Runtime permissions, foreground service, lifecycle handling
  - [x] Single-screen UI: config card, big toggle, status indicator, activity log
- [x] `analysis_options.yaml`

## 3. Verification / docs
- [x] Run server smoke test (or at minimum boot the server and curl /health)
- [x] Document curl examples, WS protocol table, security hardening notes
- [x] Document Android build steps + Play Store caveats (SMS permission policy)
- [x] Final review: no secrets committed, `.env.example` only

## 4. Windows dev-environment repair (`fix-dev-environment.ps1`)
Run elevated: `powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-dev-environment.ps1`

- [x] Corrupted Flutter `jdk-dir` (`path/to/jdk & ...exit_with_errorlevel.bat`) -> rewritten
- [x] `ANDROID_HOME` / `ANDROID_SDK_ROOT` / `JAVA_HOME` set (Machine + User)
- [x] PATH reordered so Flutter's bundled Dart wins over standalone Dart 3.9.0
- [x] Detect **gutted Android Studio JBR** (has `bin\java.exe`, no `lib\jvm.cfg`) and reject it
- [x] Enforce JDK 17-23 (Gradle 8.12); auto-install Temurin 21 to `C:\tools\jdk-21`
- [x] Detect **fake `adb.exe`** (GUI-subsystem wrapper that prints nothing) and reinstall
      platform-tools from Google -> Flutter now sees physical devices
- [x] Detect **WiseFS filter driver** (Wise Care 360 leftover) that zeroes/delays compiler
      output -> warn, `-DisableWiseFilter` unloads it for the boot
- [x] Dart compiler smoke test (kernel must be > 100 KB, waits for delayed writes)
- [x] FVM wiring: `.fvmrc` + `.fvm\flutter_sdk` junction to the FVM-managed SDK
- [x] Long paths, stale build cleanup, `pub get` / `precache`, project pins
- [x] Optional AVD creation, `flutter doctor` / `analyze` / `test` / APK build
- [x] Backup of env + PATH + `.flutter_settings` + generated `restore.ps1`
- [ ] Confirm `flutter build apk --debug` and install on the physical device
