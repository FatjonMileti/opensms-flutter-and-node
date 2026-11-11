/**
 * End-to-end smoke test for the relay server.
 * Boots the real server in a child process, then plays the role of both a
 * web client (REST) and an Android gateway (WebSocket).
 *
 *   npm test
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';

const PORT = 4599;
const API_KEY = 'sk_test_smoke_key';
const DEVICE_TOKEN = 'dt_test_smoke_token';
const ADMIN_TOKEN = 'admin_test_token';
const BASE = `http://127.0.0.1:${PORT}`;

let child;
let stderr = '';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitForHealth(timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${BASE}/health`);
      if (res.ok) return res.json();
    } catch {
      /* not up yet */
    }
    await sleep(150);
  }
  throw new Error(`Server did not become healthy.\n${stderr}`);
}

function openGateway() {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${DEVICE_TOKEN}&deviceId=test-device`);
  const queue = [];
  const waiters = [];

  ws.on('message', (raw) => {
    const frame = JSON.parse(raw.toString());
    const waiter = waiters.shift();
    if (waiter) waiter(frame);
    else queue.push(frame);
  });

  const nextFrame = (timeoutMs = 5000) =>
    new Promise((resolve, reject) => {
      if (queue.length) return resolve(queue.shift());
      const timer = setTimeout(() => reject(new Error('Timed out waiting for a frame')), timeoutMs);
      waiters.push((frame) => {
        clearTimeout(timer);
        resolve(frame);
      });
    });

  return { ws, nextFrame };
}

before(async () => {
  child = spawn(process.execPath, ['server.js'], {
    cwd: fileURLToPath(new URL('..', import.meta.url)),
    env: {
      ...process.env,
      PORT: String(PORT),
      HOST: '127.0.0.1',
      NODE_ENV: 'test',
      API_KEYS: API_KEY,
      DEVICE_TOKENS: DEVICE_TOKEN,
      ADMIN_TOKEN,
      STUCK_TIMEOUT_MS: '5000',
      RATE_LIMIT_MAX: '500',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stderr.on('data', (d) => {
    stderr += d.toString();
  });
  child.stdout.on('data', () => {});
  await waitForHealth();
});

after(async () => {
  child?.kill('SIGTERM');
  await sleep(200);
});

test('health endpoint is public and reports queue state', async () => {
  const body = await (await fetch(`${BASE}/health`)).json();
  assert.equal(body.status, 'ok');
  assert.equal(typeof body.devicesOnline, 'number');
});

test('send without an API key is rejected', async () => {
  const res = await fetch(`${BASE}/api/v1/sms/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ to: '+15551234567', message: 'nope' }),
  });
  assert.equal(res.status, 401);
  assert.equal((await res.json()).error.code, 'missing_api_key');
});

test('invalid recipient is rejected', async () => {
  const res = await fetch(`${BASE}/api/v1/sms/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-KEY': API_KEY },
    body: JSON.stringify({ to: 'not-a-phone', message: 'hello' }),
  });
  assert.equal(res.status, 400);
  assert.equal((await res.json()).error.code, 'invalid_recipient');
});

test('message queues, dispatches over WS, and status is updated', async () => {
  const sendRes = await fetch(`${BASE}/api/v1/sms/send`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-KEY': API_KEY,
      'Idempotency-Key': 'smoke-1',
    },
    body: JSON.stringify({ to: '+1 (555) 123-4567', message: 'Hello from the API' }),
  });
  assert.equal(sendRes.status, 202);

  const queued = await sendRes.json();
  assert.equal(queued.status, 'Pending');
  assert.match(queued.id, /^[0-9a-f-]{36}$/);
  assert.equal(queued.devicesOnline, 0);

  // A Pending message must survive until a gateway shows up.
  const pendingStatus = await (
    await fetch(`${BASE}/api/v1/sms/status/${queued.id}`, { headers: { 'X-API-KEY': API_KEY } })
  ).json();
  assert.equal(pendingStatus.status, 'Pending');

  const { ws, nextFrame } = openGateway();
  const welcome = await nextFrame();
  assert.equal(welcome.type, 'welcome');
  assert.equal(welcome.deviceId, 'test-device');

  const job = await nextFrame();
  assert.equal(job.type, 'sms');
  assert.equal(job.id, queued.id);
  assert.equal(job.to, '+15551234567');
  assert.equal(job.message, 'Hello from the API');

  const statusWhileSending = await (
    await fetch(`${BASE}/api/v1/sms/status/${queued.id}`, { headers: { 'X-API-KEY': API_KEY } })
  ).json();
  assert.equal(statusWhileSending.status, 'Sending');
  assert.equal(statusWhileSending.attempts, 1);

  ws.send(JSON.stringify({ type: 'status_update', id: job.id, status: 'Sent' }));

  const ack = await nextFrame();
  assert.equal(ack.type, 'ack');
  assert.equal(ack.status, 'Sent');

  const finalStatus = await (
    await fetch(`${BASE}/api/v1/sms/status/${queued.id}`, { headers: { 'X-API-KEY': API_KEY } })
  ).json();
  assert.equal(finalStatus.status, 'Sent');
  assert.ok(finalStatus.sentAt);

  ws.close();
});

test('idempotency key replays the original message', async () => {
  const payload = {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-KEY': API_KEY,
      'Idempotency-Key': 'smoke-replay',
    },
    body: JSON.stringify({ to: '+15550001111', message: 'only once' }),
  };

  const first = await (await fetch(`${BASE}/api/v1/sms/send`, payload)).json();
  const second = await (await fetch(`${BASE}/api/v1/sms/send`, payload)).json();

  assert.equal(second.id, first.id);
  assert.equal(second.idempotentReplay, true);
});

test('gateway token is verified before the upgrade completes', async () => {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=wrong-token`);
  const error = await new Promise((resolve) => {
    ws.on('error', resolve);
    ws.on('open', () => resolve(new Error('should not have opened')));
  });
  assert.match(String(error.message), /401/);
});

test('admin can mint an API key and it works', async () => {
  const created = await (
    await fetch(`${BASE}/api/v1/admin/keys`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${ADMIN_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ label: 'smoke-test' }),
    })
  ).json();
  assert.ok(created.key.startsWith('sk_'));

  const res = await fetch(`${BASE}/api/v1/sms/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-KEY': created.key },
    body: JSON.stringify({ to: '+15550002222', message: 'minted key works' }),
  });
  assert.equal(res.status, 202);
});
