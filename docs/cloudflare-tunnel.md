# Exposing the OpenSMS relay with a Cloudflare Tunnel

A step-by-step account of how the relay server in `server/` was made reachable from a phone on
mobile data, without opening ports on the router and without a public IP.

Everything below was done inside **WSL2 (Ubuntu 26.04)** on Windows, with the relay listening on
`127.0.0.1:3000`. The same steps work on a native Linux box; Windows and macOS notes are at the end.

---

## 1. Why a tunnel at all

The Flutter gateway connects to the relay over WebSocket, and the phone is often on mobile data:

```
phone (4G)  ──wss──▶  Cloudflare edge  ──QUIC──▶  cloudflared (your machine)  ──http──▶  localhost:3000
```

A **quick tunnel** (`cloudflared tunnel --url ...`) creates a throwaway public hostname, terminates TLS
at Cloudflare's edge, and forwards traffic down an outbound-only connection. Nothing needs to be
forwarded or whitelisted on your side, which also means there is no inbound port to attack.

Trade-off: the hostname is random (`https://<three-words>.trycloudflare.com`), changes on every
restart, and the edge is unauthenticated — suitable for development, not production. cloudflared
itself warns at startup that account-less quick tunnels have **no uptime guarantee** and are subject
to Cloudflare's terms; use a named tunnel (§9) for anything you care about.

---

## 2. Install `cloudflared`

Cloudflare publishes a single static binary. No package manager or root needed:

```bash
mkdir -p ~/opt
curl -fL -o ~/opt/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x ~/opt/cloudflared
~/opt/cloudflared --version
# cloudflared version 2026.10.7 (built 2026-10-30-17:05 UTC)
```

Other hosts:

| Platform | Command |
|---|---|
| Windows | `winget install --id Cloudflare.cloudflared` (binary also at `…/cloudflared-windows-amd64.exe`) |
| macOS | `brew install cloudflared` |
| Debian/Ubuntu (root) | install Cloudflare's apt repo, then `sudo apt install cloudflared` |

---

## 3. Start the local service first

The tunnel only proxies; it does not start anything. The relay was started from `server/` with
generated secrets in `.env`:

```bash
cd ~/projects/opensms-flutter-and-node/server
cat > .env <<EOF
PORT=3000
HOST=0.0.0.0
WS_PATH=/ws
API_KEYS=$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')
DEVICE_TOKENS=$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')
ADMIN_TOKEN=$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')
EOF
chmod 600 .env
node server.js        # prints: listening on http://0.0.0.0:3000
```

Sanity check before involving Cloudflare:

```bash
curl -s http://127.0.0.1:3000/health
# {"status":"ok","version":"1.0.0","env":"development","uptimeSeconds":1,"devicesOnline":0,"queueDepth":0}
```

> If this fails, the tunnel will only ever return `502`. Always debug locally first.

---

## 4. Run the quick tunnel

```bash
~/opt/cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate
```

`--no-autoupdate` keeps the binary from replacing itself mid-run (useful when you launch it from a
script and want a stable file).

On startup Cloudflare logs an account-less-tunnel disclaimer, requests a hostname, then registers a
QUIC connection (and prints a connectivity pre-check table):

```
INF Requesting new quick Tunnel on trycloudflare.com...
INF +--------------------------------------------------------------------------------------------+
INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
INF |  https://radios-jamie-article-person.trycloudflare.com                                     |
INF +--------------------------------------------------------------------------------------------+
INF Registered tunnel connection connIndex=0 connection=be513a1a-… event=0 location=sof01 protocol=quic
INF precheck complete hard_fail=false … suggested_protocol=quic
```

Reusing the URL in scripts is easiest by parsing the log:

```bash
URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | head -1)
```

---

## 5. Verify, including the WebSocket

HTTP first — this is also the endpoint the app's **Test server** button probes:

```bash
curl -s "$URL/health"
# {"status":"ok",...,"devicesOnline":0,"queueDepth":0}
```

Then the part that actually matters for this project: the authenticated WebSocket upgrade
(`wss://`, because the tunnel is HTTPS). Node 22+ has a built-in `WebSocket`, so no dependencies:

```bash
cat > /tmp/wstest.mjs <<'JS'
const ws = new WebSocket(process.argv[2]);
const done = (m) => { console.log(m); try { ws.close(); } catch {} process.exit(0); };
ws.addEventListener('message', (e) => done('first frame: ' + String(e.data).slice(0, 200)));
ws.addEventListener('error', () => done('ERROR'));
setTimeout(() => done('TIMEOUT'), 20000);
JS

node /tmp/wstest.mjs "wss://${URL#https://}/ws?token=$DEVICE_TOKEN"
# first frame: {"type":"welcome","deviceId":"device-2f45f362","pending":0,...}
```

A `welcome` frame proves TLS, the WebSocket upgrade, the query-string token auth and the relay are all
working through the tunnel. After that, the phone connected and `GET /health` reported
`"devicesOnline":1`.

---

## 6. Keep it alive

Two problems appeared in practice:

1. **A backgrounded process dies with its shell.** `nohup node server.js &` did not survive the
   non-interactive shell that started it; the tunnel then logged
   `dial tcp 127.0.0.1:3000: connect: connection refused`. Starting it in a new session fixed it:

   ```bash
   setsid node server.js > server.log 2>&1 < /dev/null &
   setsid ~/opt/cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate > tunnel.log 2>&1 &
   ```

   (`systemd` + `Restart=always` is the proper answer on a real server.)

2. **The URL changes every start.** Automation therefore re-parses `tunnel.log` and reprints the URL,
   and the app's saved server URL must be updated whenever the tunnel restarts.

The two scripts used here:

```bash
~/android-setup/start-stack.sh    # server + tunnel, prints URL / device token / API key
~/android-setup/stop-stack.sh     # pkill both
```

---

## 7. Errors seen, and what they meant

| Symptom | Cause | Fix |
|---|---|---|
| `530` on the public URL | tunnel process not registered yet / just started | wait a few seconds, retry |
| `502 Bad gateway` (Cloudflare error page) | `cloudflared` up, but nothing listening on the origin port | start the server, `curl 127.0.0.1:3000/health` |
| tunnel log `connection refused` | origin crashed or was killed with its shell | `setsid`, or a supervisor |
| `no URL specified` from curl | shell quoting swallowed `$URL` | quote the URL, run from a script |
| app connects locally but not from the phone | phone on another network and URL is `http://192.168.x.x` | use the tunnel URL |

---

## 8. Hardening before this leaves your machine

The quick tunnel is fine for a demo; treat it as public. What matters for this project:

- **Secrets**: `server/.env` holds `API_KEYS`, `DEVICE_TOKENS`, `ADMIN_TOKEN`. It is `chmod 600` and
  gitignored. Never commit it, and rotate the tokens after a testing session.
- **Admin routes**: `/api/v1/admin/*` are protected by `ADMIN_TOKEN`; if it is empty the server
  returns `503` instead of leaking an open admin surface. Keep it non-empty.
- **SMS is a paid, regulated action**: the tunnel makes your SIM reachable by anyone holding the
  API key. Revoke the key when you are done.
- **CORS**: `CORS_ORIGINS=*` is only acceptable because this API is machine-to-machine. Narrow it if
  you add a browser client.
- **Do not expose a debug build to the internet.** `flutter run` on a public URL is fine for the
  gateway protocol, but release builds are what you want the server to trust.

---

## 9. The stable alternative: a named tunnel

If you own a domain on Cloudflare (free plan is enough), a named tunnel gives you a fixed hostname,
a stable UUID and no per-restart reconfiguration:

```bash
cloudflared tunnel login                      # opens a browser, authorises the zone
cloudflared tunnel create opensms             # writes ~/.cloudflared/<UUID>.json
cloudflared tunnel route dns opensms sms.example.com
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: <UUID>
credentials-file: /home/<user>/.cloudflared/<UUID>.json
ingress:
  - hostname: sms.example.com
    service: http://localhost:3000
  - service: http_status:404
```

```bash
cloudflared tunnel run opensms
```

Then the app's server URL becomes `https://sms.example.com` — entered once, never changed. On a server
you would additionally `sudo cloudflared service install` so it starts at boot.

---

## 10. Teardown

```bash
~/android-setup/stop-stack.sh     # or: pkill -f "cloudflared tunnel"; pkill -f "node server.js"
```

The quick tunnel, its DNS record and its certificate disappear when the process stops. Nothing is left
behind on Cloudflare, which is why this is a safe default for development.

---

## Cheat sheet

```bash
# install
curl -fL -o ~/opt/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x ~/opt/cloudflared

# run (origin must already be up)
setsid ~/opt/cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate > tunnel.log 2>&1 &

# discover the URL
grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | head -1

# verify HTTP + WebSocket
curl -s "$URL/health"
node /tmp/wstest.mjs "wss://${URL#https://}/ws?token=$DEVICE_TOKEN"
```
