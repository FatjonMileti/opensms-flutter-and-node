/* ============================================================================
 * OpenSMS Gateway — relay server
 * ============================================================================
 * Responsibilities
 *   1. Accept authenticated SMS requests from web clients (REST, X-API-KEY).
 *   2. Hold them in an in-memory outbox until an Android gateway picks them up.
 *   3. Push jobs to connected gateways over WebSocket and record their report.
 *
 * Sections (kept deliberately separate so this file can be split into
 * src/config.js, src/store.js, src/middleware/*, src/routes/*, src/ws/*):
 *   1. Configuration          6. WebSocket gateway
 *   2. Utilities / logger     7. Background workers (reaper)
 *   3. In-memory store        8. HTTP app assembly
 *   4. HTTP middleware        9. Bootstrap + graceful shutdown
 *   5. HTTP routes
 * ==========================================================================*/

import 'dotenv/config';
import http from 'node:http';
import crypto from 'node:crypto';
import express from 'express';
import cors from 'cors';
import { WebSocketServer, WebSocket } from 'ws';
import { v4 as uuidv4 } from 'uuid';

/* ==========================================================================
 * 1. CONFIGURATION
 * ========================================================================== */

const envInt = (raw, fallback) => {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
};

const envList = (raw) =>
  String(raw ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);

const config = Object.freeze({
  version: '1.0.0',
  env: process.env.NODE_ENV || 'development',
  port: envInt(process.env.PORT, 3000),
  host: process.env.HOST || '0.0.0.0',
  wsPath: process.env.WS_PATH || '/ws',
  bodyLimit: process.env.BODY_LIMIT || '64kb',

  corsOrigins: envList(process.env.CORS_ORIGINS).length
    ? envList(process.env.CORS_ORIGINS)
    : ['*'],

  adminToken: process.env.ADMIN_TOKEN || '',
  seedApiKeys: envList(process.env.API_KEYS),
  seedDeviceTokens: [
    ...envList(process.env.DEVICE_TOKENS),
    ...envList(process.env.DEVICE_TOKEN),
  ],

  // Queue lifecycle
  messageTtlMs: envInt(process.env.MESSAGE_TTL_MS, 24 * 60 * 60 * 1000),
  stuckTimeoutMs: envInt(process.env.STUCK_TIMEOUT_MS, 2 * 60 * 1000),
  maxAttempts: envInt(process.env.MAX_ATTEMPTS, 3),

  // Abuse protection
  rateLimitWindowMs: envInt(process.env.RATE_LIMIT_WINDOW_MS, 60_000),
  rateLimitMax: envInt(process.env.RATE_LIMIT_MAX, 120),

  // Socket hygiene
  wsHeartbeatMs: envInt(process.env.WS_HEARTBEAT_MS, 30_000),
  authGraceMs: envInt(process.env.WS_AUTH_GRACE_MS, 10_000),

  maxMessageChars: 1600,
  maxPhoneChars: 16,
});

/* ==========================================================================
 * 2. UTILITIES / LOGGER
 * ========================================================================== */

const nowIso = () => new Date().toISOString();
const sha256 = (value) => crypto.createHash('sha256').update(String(value)).digest('hex');

/** Show only enough of a secret to identify it in a list. */
const maskSecret = (value) =>
  value.length <= 10 ? `${value.slice(0, 3)}***` : `${value.slice(0, 6)}…${value.slice(-4)}`;

const jsonError = (res, status, code, message, details) =>
  res.status(status).json({ error: { code, message, ...(details ? { details } : {}) } });

const logger = {
  info: (...args) => console.log(`[${nowIso()}] [info ]`, ...args),
  warn: (...args) => console.warn(`[${nowIso()}] [warn ]`, ...args),
  error: (...args) => console.error(`[${nowIso()}] [error]`, ...args),
};

/** Accepts +15551234567, 15551234567, "+1 (555) 123-4567". */
const PHONE_RE = /^\+?[1-9]\d{6,14}$/;
const normalizePhone = (raw) => {
  if (typeof raw !== 'string') return null;
  const cleaned = raw.replace(/[\s\-().]/g, '');
  return PHONE_RE.test(cleaned) ? cleaned : null;
};

/* ==========================================================================
 * 3. IN-MEMORY STORE
 * ==========================================================================
 * Swap this object for Prisma/Redis later — routes only touch the helpers
 * below, never the maps directly.
 */

const store = {
  apiKeys: new Map(), // sha256(key) -> key record
  deviceTokens: new Map(), // sha256(token) -> device-token record
  messages: new Map(), // id -> message record
  idempotency: new Map(), // `${apiKeyId}:${idempotencyKey}` -> message id
  devices: new Map(), // deviceId -> device record (no sockets here)
  rateBuckets: new Map(), // apiKeyId -> { count, resetAt }
};

const MAX_RECORDS = 10_000;

const createApiKey = (rawKey, label = 'unnamed') => {
  const record = {
    id: uuidv4(),
    label,
    preview: maskSecret(rawKey),
    hash: sha256(rawKey),
    active: true,
    createdAt: nowIso(),
    lastUsedAt: null,
  };
  store.apiKeys.set(record.hash, record);
  return record;
};

const createDeviceToken = (rawToken, label = 'unnamed') => {
  const record = {
    id: uuidv4(),
    label,
    preview: maskSecret(rawToken),
    hash: sha256(rawToken),
    active: true,
    createdAt: nowIso(),
    lastUsedAt: null,
  };
  store.deviceTokens.set(record.hash, record);
  return record;
};

const findApiKey = (rawKey) => (rawKey ? store.apiKeys.get(sha256(rawKey)) ?? null : null);
const findDeviceToken = (rawToken) =>
  rawToken ? store.deviceTokens.get(sha256(rawToken)) ?? null : null;

const createMessage = ({ to, message, apiKeyId, requestId, idempotencyKey }) => {
  const timestamp = nowIso();
  const record = {
    id: uuidv4(),
    to,
    message,
    status: 'Pending', // Pending | Sending | Sent | Failed
    attempts: 0,
    deviceId: null,
    error: null,
    apiKeyId,
    requestId,
    idempotencyKey: idempotencyKey || null,
    createdAt: timestamp,
    updatedAt: timestamp,
    sentAt: null,
  };
  store.messages.set(record.id, record);

  // Cheap memory guard: drop the oldest finished messages first.
  if (store.messages.size > MAX_RECORDS) {
    for (const [id, existing] of store.messages) {
      if (store.messages.size <= MAX_RECORDS) break;
      if (existing.status === 'Sent' || existing.status === 'Failed') store.messages.delete(id);
    }
  }
  return record;
};

const publicMessage = (m) => ({
  id: m.id,
  to: m.to,
  message: m.message,
  status: m.status,
  attempts: m.attempts,
  deviceId: m.deviceId,
  error: m.error,
  createdAt: m.createdAt,
  updatedAt: m.updatedAt,
  sentAt: m.sentAt,
});

const pendingMessages = () =>
  [...store.messages.values()]
    .filter((m) => m.status === 'Pending')
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt));

const queueDepth = () =>
  [...store.messages.values()].filter((m) => m.status === 'Pending' || m.status === 'Sending')
    .length;

/* ==========================================================================
 * 4. HTTP MIDDLEWARE
 * ========================================================================== */

/** Adds an X-Request-Id to every request/response for log correlation. */
const requestContext = (req, res, next) => {
  req.id = req.get('x-request-id')?.slice(0, 100) || uuidv4();
  req.startedAt = process.hrtime.bigint();
  res.setHeader('X-Request-Id', req.id);
  next();
};

const accessLog = (req, res, next) => {
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - req.startedAt) / 1e6;
    logger.info(
      `${req.method} ${req.originalUrl} ${res.statusCode} ${ms.toFixed(1)}ms rid=${req.id}`,
    );
  });
  next();
};

/** Validates the X-API-KEY header against the in-memory key store. */
const apiKeyAuth = (req, res, next) => {
  const header = req.get('x-api-key');
  const bearer = req.get('authorization');
  const rawKey =
    header || (bearer && bearer.toLowerCase().startsWith('apikey ') ? bearer.slice(7).trim() : '');

  if (!rawKey) {
    return jsonError(
      res,
      401,
      'missing_api_key',
      'Provide your key in the X-API-KEY header.',
    );
  }

  const record = findApiKey(rawKey);
  if (!record || !record.active) {
    return jsonError(res, 401, 'invalid_api_key', 'The supplied API key is invalid or revoked.');
  }

  record.lastUsedAt = nowIso();
  req.apiKey = record;
  return next();
};

/** Bearer-token auth for /api/v1/admin/*. */
const adminAuth = (req, res, next) => {
  if (!config.adminToken) {
    return jsonError(
      res,
      503,
      'admin_disabled',
      'Set ADMIN_TOKEN in the server environment to enable admin routes.',
    );
  }
  const bearer = req.get('authorization') || '';
  const supplied = bearer.toLowerCase().startsWith('bearer ') ? bearer.slice(7).trim() : '';
  const a = Buffer.from(supplied);
  const b = Buffer.from(config.adminToken);
  const matches = a.length === b.length && crypto.timingSafeEqual(a, b);
  if (!matches) {
    return jsonError(res, 401, 'invalid_admin_token', 'Admin bearer token is invalid.');
  }
  return next();
};

/** Fixed-window rate limiter, keyed by API key id. */
const rateLimit = (req, res, next) => {
  const key = req.apiKey?.id || req.ip;
  const now = Date.now();
  let bucket = store.rateBuckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    bucket = { count: 0, resetAt: now + config.rateLimitWindowMs };
    store.rateBuckets.set(key, bucket);
  }
  bucket.count += 1;

  const remaining = Math.max(0, config.rateLimitMax - bucket.count);
  res.setHeader('X-RateLimit-Limit', String(config.rateLimitMax));
  res.setHeader('X-RateLimit-Remaining', String(remaining));
  res.setHeader('X-RateLimit-Reset', String(Math.ceil(bucket.resetAt / 1000)));

  if (bucket.count > config.rateLimitMax) {
    const retryAfter = Math.ceil((bucket.resetAt - now) / 1000);
    res.setHeader('Retry-After', String(retryAfter));
    return jsonError(res, 429, 'rate_limited', `Too many requests. Retry in ${retryAfter}s.`);
  }
  return next();
};

/** Body validation for POST /sms/send. Normalises before it hits the route. */
const validateSendRequest = (req, res, next) => {
  const body = req.body;
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return jsonError(res, 400, 'invalid_body', 'Expected a JSON object body.');
  }

  const to = normalizePhone(body.to);
  if (!to) {
    return jsonError(
      res,
      400,
      'invalid_recipient',
      'Field "to" must be a phone number in E.164-ish format, e.g. +15551234567.',
    );
  }

  const message = typeof body.message === 'string' ? body.message.trim() : '';
  if (!message) {
    return jsonError(res, 400, 'invalid_message', 'Field "message" must be a non-empty string.');
  }
  if (message.length > config.maxMessageChars) {
    return jsonError(
      res,
      400,
      'message_too_long',
      `"message" exceeds ${config.maxMessageChars} characters.`,
    );
  }

  req.sms = { to, message };
  return next();
};

/* ==========================================================================
 * 5. HTTP ROUTES
 * ========================================================================== */

const smsRouter = express.Router();
const adminRouter = express.Router();

/**
 * POST /api/v1/sms/send
 * Queue an SMS and push it to a connected gateway immediately (if any).
 * Optional `Idempotency-Key` header makes retries safe.
 */
smsRouter.post('/send', rateLimit, validateSendRequest, (req, res) => {
  const idempotencyKey = req.get('idempotency-key')?.slice(0, 200) || null;
  const idempotencyMapKey = idempotencyKey ? `${req.apiKey.id}:${idempotencyKey}` : null;

  if (idempotencyMapKey) {
    const existingId = store.idempotency.get(idempotencyMapKey);
    const existing = existingId ? store.messages.get(existingId) : null;
    if (existing) {
      return res.status(200).json({ ...publicMessage(existing), idempotentReplay: true });
    }
  }

  const message = createMessage({
    to: req.sms.to,
    message: req.sms.message,
    apiKeyId: req.apiKey.id,
    requestId: req.id,
    idempotencyKey,
  });

  if (idempotencyMapKey) store.idempotency.set(idempotencyMapKey, message.id);

  // Immediate broadcast: every connected gateway races for the job, but only
  // one wins because status flips to Sending synchronously inside flush().
  for (const deviceId of store.devices.keys()) flush(deviceId);

  logger.info(
    `queued sms id=${message.id} to=${message.to} devices=${store.devices.size} rid=${req.id}`,
  );

  return res.status(202).json({
    id: message.id,
    status: message.status,
    to: message.to,
    createdAt: message.createdAt,
    devicesOnline: store.devices.size,
    statusUrl: `/api/v1/sms/status/${message.id}`,
  });
});

/** GET /api/v1/sms/status/:id — transmission status of one SMS. */
smsRouter.get('/status/:id', (req, res) => {
  const message = store.messages.get(req.params.id);
  if (!message) {
    return jsonError(res, 404, 'not_found', `No SMS found with id ${req.params.id}.`);
  }
  return res.json(publicMessage(message));
});

/** GET /api/v1/sms?status=Pending&limit=50 — recent outbox, newest first. */
smsRouter.get('/', (req, res) => {
  const status = typeof req.query.status === 'string' ? req.query.status : null;
  const limit = Math.min(envInt(req.query.limit, 50), 500);

  let rows = [...store.messages.values()];
  if (status) rows = rows.filter((m) => m.status.toLowerCase() === status.toLowerCase());
  rows.sort((a, b) => b.createdAt.localeCompare(a.createdAt));

  res.json({ count: rows.length, messages: rows.slice(0, limit).map(publicMessage) });
});

/* ---------------------------- Admin routes ------------------------------- */

adminRouter.use(adminAuth);

adminRouter.get('/stats', (_req, res) => {
  const counts = { Pending: 0, Sending: 0, Sent: 0, Failed: 0 };
  for (const m of store.messages.values()) counts[m.status] = (counts[m.status] || 0) + 1;
  res.json({
    messages: counts,
    devicesOnline: store.devices.size,
    apiKeys: store.apiKeys.size,
    deviceTokens: store.deviceTokens.size,
    uptimeSeconds: Math.round(process.uptime()),
  });
});

/** Create an API key. The raw secret is returned exactly once. */
adminRouter.post('/keys', (req, res) => {
  const label = String(req.body?.label || 'unnamed').slice(0, 80);
  const rawKey = `sk_${config.env}_${crypto.randomBytes(24).toString('base64url')}`;
  const record = createApiKey(rawKey, label);
  res.status(201).json({
    id: record.id,
    label: record.label,
    key: rawKey,
    createdAt: record.createdAt,
    note: 'Store this key now — it is hashed and cannot be shown again.',
  });
});

adminRouter.get('/keys', (_req, res) => {
  res.json({
    keys: [...store.apiKeys.values()].map((k) => ({
      id: k.id,
      label: k.label,
      preview: k.preview,
      active: k.active,
      createdAt: k.createdAt,
      lastUsedAt: k.lastUsedAt,
    })),
  });
});

adminRouter.delete('/keys/:id', (req, res) => {
  const entry = [...store.apiKeys.values()].find((k) => k.id === req.params.id);
  if (!entry) return jsonError(res, 404, 'not_found', 'API key not found.');
  entry.active = false;
  return res.json({ id: entry.id, active: false });
});

/** Create a device token used by the Android gateway during WS auth. */
adminRouter.post('/device-tokens', (req, res) => {
  const label = String(req.body?.label || 'unnamed').slice(0, 80);
  const rawToken = `dt_${crypto.randomBytes(24).toString('base64url')}`;
  const record = createDeviceToken(rawToken, label);
  res.status(201).json({
    id: record.id,
    label: record.label,
    token: rawToken,
    createdAt: record.createdAt,
    note: 'Paste this token into the gateway app. It cannot be shown again.',
  });
});

adminRouter.get('/device-tokens', (_req, res) => {
  res.json({
    tokens: [...store.deviceTokens.values()].map((t) => ({
      id: t.id,
      label: t.label,
      preview: t.preview,
      active: t.active,
      createdAt: t.createdAt,
      lastUsedAt: t.lastUsedAt,
    })),
  });
});

adminRouter.delete('/device-tokens/:id', (req, res) => {
  const entry = [...store.deviceTokens.values()].find((t) => t.id === req.params.id);
  if (!entry) return jsonError(res, 404, 'not_found', 'Device token not found.');
  entry.active = false;
  return res.json({ id: entry.id, active: false });
});

adminRouter.get('/devices', (_req, res) => {
  res.json({
    devices: [...store.devices.values()].map((d) => ({
      deviceId: d.deviceId,
      connectedAt: d.connectedAt,
      lastSeen: d.lastSeen,
      remoteAddress: d.remoteAddress,
      appVersion: d.appVersion,
    })),
  });
});

/* ==========================================================================
 * 6. WEBSOCKET GATEWAY
 * ==========================================================================
 * Wire protocol (JSON text frames)
 *
 *   client -> server  { type: "hello", token, deviceId?, appVersion? }
 *   server -> client  { type: "welcome", deviceId, pending, serverTime }
 *   server -> client  { type: "sms", id, to, message, createdAt, attempt }
 *   client -> server  { type: "status_update", id, status: "Sent"|"Failed", error? }
 *   server -> client  { type: "ack", id, status }
 *   client -> server  { type: "ping" }        server -> { type: "pong" }
 *   server -> client  { type: "auth_error", reason } then close 4401
 *
 * Authentication: `?token=...` on the upgrade URL, or the `hello` frame within
 * WS_AUTH_GRACE_MS. Tokens are compared by SHA-256 hash, never in plaintext.
 */

const wss = new WebSocketServer({ noServer: true, clientTracking: true, maxPayload: 256 * 1024 });
const inFlight = new Map(); // deviceId -> message id currently being sent

const socketFor = (deviceId) => {
  const device = store.devices.get(deviceId);
  return device ? device.socket ?? null : null;
};

const sendJson = (ws, payload) => {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  try {
    ws.send(JSON.stringify(payload));
    return true;
  } catch (err) {
    logger.warn('ws send failed:', err.message);
    return false;
  }
};

const closeSocket = (ws, code, reason) => {
  try {
    ws.close(code, reason);
  } catch {
    /* already closing */
  }
};

/** Claim the oldest Pending message for a device and push it down the socket. */
function flush(deviceId) {
  const ws = socketFor(deviceId);
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  if (inFlight.has(deviceId)) return; // one in-flight SMS per device keeps order

  const next = pendingMessages()[0];
  if (!next) return;

  next.status = 'Sending';
  next.attempts += 1;
  next.deviceId = deviceId;
  next.updatedAt = nowIso();

  const delivered = sendJson(ws, {
    type: 'sms',
    id: next.id,
    to: next.to,
    message: next.message,
    createdAt: next.createdAt,
    attempt: next.attempts,
  });

  if (!delivered) {
    next.status = 'Pending';
    next.deviceId = null;
    next.updatedAt = nowIso();
    return;
  }

  inFlight.set(deviceId, next.id);
  logger.info(`dispatched sms id=${next.id} device=${deviceId} attempt=${next.attempts}`);
}

/** Put an unconfirmed message back in the queue (device dropped / timeout). */
function requeue(deviceId, reason) {
  const messageId = inFlight.get(deviceId);
  if (!messageId) return;
  inFlight.delete(deviceId);

  const message = store.messages.get(messageId);
  if (!message || message.status !== 'Sending') return;

  if (message.attempts >= config.maxAttempts) {
    message.status = 'Failed';
    message.error = reason;
    message.sentAt = null;
  } else {
    message.status = 'Pending';
  }
  message.deviceId = null;
  message.updatedAt = nowIso();
  logger.warn(`requeued sms id=${messageId} device=${deviceId}: ${reason}`);
}

/** Register an authenticated socket, replacing any stale socket for the device. */
function attachDevice(ws, { deviceId, tokenRecord, appVersion, remoteAddress }) {
  const previous = socketFor(deviceId);
  if (previous && previous !== ws) {
    previous.deviceId = null; // prevent its close handler from unregistering us
    closeSocket(previous, 4000, 'replaced by a newer connection');
  }

  ws.deviceId = deviceId;
  ws.tokenRecord = tokenRecord;
  tokenRecord.lastUsedAt = nowIso();

  store.devices.set(deviceId, {
    deviceId,
    socket: ws,
    connectedAt: nowIso(),
    lastSeen: nowIso(),
    remoteAddress: remoteAddress || null,
    appVersion: appVersion ? String(appVersion).slice(0, 40) : null,
  });

  logger.info(`gateway connected device=${deviceId} from=${remoteAddress || 'unknown'}`);

  sendJson(ws, {
    type: 'welcome',
    deviceId,
    pending: queueDepth(),
    serverTime: nowIso(),
    serverVersion: config.version,
  });

  flush(deviceId);
}

function handleStatusUpdate(ws, data) {
  const id = typeof data.id === 'string' ? data.id : '';
  const status = String(data.status || '').toLowerCase();
  const deviceId = ws.deviceId;

  if (!id) return sendJson(ws, { type: 'error', code: 'missing_id', message: 'id is required' });
  if (status !== 'sent' && status !== 'failed') {
    return sendJson(ws, {
      type: 'error',
      code: 'invalid_status',
      message: 'status must be "Sent" or "Failed"',
    });
  }

  const message = store.messages.get(id);
  if (!message) {
    return sendJson(ws, { type: 'error', code: 'unknown_message', message: `Unknown id ${id}` });
  }

  // Idempotent: duplicate reports are acknowledged, not re-applied.
  if (message.status === 'Sent' || message.status === 'Failed') {
    return sendJson(ws, { type: 'ack', id, status: message.status, duplicate: true });
  }

  message.status = status === 'sent' ? 'Sent' : 'Failed';
  message.error = data.error ? String(data.error).slice(0, 500) : null;
  message.sentAt = message.status === 'Sent' ? nowIso() : null;
  message.updatedAt = nowIso();
  if (message.deviceId === null) message.deviceId = deviceId;

  if (deviceId && inFlight.get(deviceId) === id) inFlight.delete(deviceId);

  logger.info(`status id=${id} -> ${message.status} device=${deviceId || 'unknown'}`);
  sendJson(ws, { type: 'ack', id, status: message.status });

  if (deviceId) flush(deviceId); // keep the pipe full
  return undefined;
}

function handleFrame(ws, raw) {
  let data;
  try {
    data = JSON.parse(raw.toString());
  } catch {
    return sendJson(ws, { type: 'error', code: 'bad_json', message: 'Frames must be JSON.' });
  }
  if (!data || typeof data !== 'object') {
    return sendJson(ws, { type: 'error', code: 'bad_frame', message: 'Expected an object.' });
  }

  switch (data.type) {
    case 'hello': {
      if (ws.deviceId) return sendJson(ws, { type: 'welcome', deviceId: ws.deviceId });
      const tokenRecord = findDeviceToken(data.token) || findApiKey(data.token);
      if (!tokenRecord || !tokenRecord.active) {
        sendJson(ws, { type: 'auth_error', reason: 'invalid_token' });
        return closeSocket(ws, 4401, 'invalid token');
      }
      const deviceId = sanitizeDeviceId(data.deviceId) || ws.suggestedDeviceId;
      return attachDevice(ws, {
        deviceId,
        tokenRecord,
        appVersion: data.appVersion,
        remoteAddress: ws.remoteAddress,
      });
    }
    case 'status_update':
      if (!ws.deviceId) return sendJson(ws, { type: 'auth_error', reason: 'not_authenticated' });
      return handleStatusUpdate(ws, data);
    case 'ping':
      if (ws.deviceId && store.devices.has(ws.deviceId)) {
        store.devices.get(ws.deviceId).lastSeen = nowIso();
      }
      return sendJson(ws, { type: 'pong', ts: nowIso() });
    case 'pong':
      return undefined;
    default:
      return sendJson(ws, { type: 'error', code: 'unknown_type', message: `Unknown type ${data.type}` });
  }
}

const sanitizeDeviceId = (value) => {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return /^[A-Za-z0-9_.:-]{1,64}$/.test(trimmed) ? trimmed : null;
};

wss.on('connection', (ws, req, meta = {}) => {
  ws.isAlive = true;
  ws.deviceId = null;
  ws.remoteAddress = req.socket.remoteAddress;
  ws.suggestedDeviceId = meta.deviceId || `device-${uuidv4().slice(0, 8)}`;

  ws.on('pong', () => {
    ws.isAlive = true;
    const device = ws.deviceId ? store.devices.get(ws.deviceId) : null;
    if (device) device.lastSeen = nowIso();
  });

  const authTimer = setTimeout(() => {
    if (!ws.deviceId) {
      sendJson(ws, { type: 'auth_error', reason: 'auth_timeout' });
      closeSocket(ws, 4401, 'authentication timeout');
    }
  }, config.authGraceMs);

  if (meta.tokenRecord) {
    clearTimeout(authTimer);
    attachDevice(ws, {
      deviceId: ws.suggestedDeviceId,
      tokenRecord: meta.tokenRecord,
      appVersion: meta.appVersion,
      remoteAddress: ws.remoteAddress,
    });
  }

  ws.on('message', (raw) => {
    try {
      handleFrame(ws, raw);
    } catch (err) {
      logger.error('ws frame handler crashed:', err);
      sendJson(ws, { type: 'error', code: 'internal_error', message: 'Frame failed.' });
    }
  });

  ws.on('error', (err) => logger.warn(`ws error device=${ws.deviceId || '?'}: ${err.message}`));

  ws.on('close', (code) => {
    clearTimeout(authTimer);
    const deviceId = ws.deviceId;
    if (!deviceId) return;

    const current = store.devices.get(deviceId);
    if (current && current.socket === ws) {
      store.devices.delete(deviceId);
      requeue(deviceId, `device ${deviceId} disconnected before confirming delivery`);
    }
    logger.info(`gateway disconnected device=${deviceId} code=${code}`);
  });
});

/* ==========================================================================
 * 7. BACKGROUND WORKERS
 * ========================================================================== */

/** Requeue messages stuck in Sending and expire old pending ones. */
function reap() {
  const now = Date.now();

  for (const [deviceId, messageId] of inFlight) {
    const message = store.messages.get(messageId);
    if (!message) {
      inFlight.delete(deviceId);
      continue;
    }
    const age = now - Date.parse(message.updatedAt);
    if (message.status === 'Sending' && age > config.stuckTimeoutMs) {
      inFlight.delete(deviceId);
      if (message.attempts >= config.maxAttempts) {
        message.status = 'Failed';
        message.error = 'Gateway did not confirm delivery in time.';
      } else {
        message.status = 'Pending';
      }
      message.deviceId = null;
      message.updatedAt = nowIso();
      logger.warn(`reaped stuck sms id=${messageId} device=${deviceId}`);
    }
  }

  for (const message of store.messages.values()) {
    if (message.status !== 'Pending') continue;
    if (now - Date.parse(message.createdAt) > config.messageTtlMs) {
      message.status = 'Failed';
      message.error = 'Message expired before a gateway could deliver it.';
      message.updatedAt = nowIso();
    }
  }

  // Retry pending work for every connected device (covers dropped sends).
  for (const deviceId of store.devices.keys()) flush(deviceId);
}

/** Native ping/pong sweep: terminates half-open TCP sockets. */
function sweepSockets() {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    try {
      ws.ping();
    } catch {
      /* socket already gone */
    }
  }
}

/* ==========================================================================
 * 8. HTTP APP ASSEMBLY
 * ========================================================================== */

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', 1);

app.use(
  cors({
    origin: config.corsOrigins.includes('*') ? true : config.corsOrigins,
    methods: ['GET', 'POST', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'X-API-KEY', 'Authorization', 'Idempotency-Key', 'X-Request-Id'],
    exposedHeaders: ['X-Request-Id', 'X-RateLimit-Limit', 'X-RateLimit-Remaining', 'X-RateLimit-Reset'],
    maxAge: 600,
  }),
);
app.use(requestContext);
app.use(accessLog);
app.use(express.json({ limit: config.bodyLimit }));

app.get('/', (_req, res) => {
  res.json({
    service: 'opensms-relay',
    version: config.version,
    docs: '/health, POST /api/v1/sms/send, GET /api/v1/sms/status/:id, WS /ws',
  });
});

app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    version: config.version,
    env: config.env,
    uptimeSeconds: Math.round(process.uptime()),
    devicesOnline: store.devices.size,
    queueDepth: queueDepth(),
  });
});

app.use('/api/v1/sms', apiKeyAuth, smsRouter);
app.use('/api/v1/admin', adminRouter);

// 404
app.use((req, res) => {
  jsonError(res, 404, 'route_not_found', `Cannot ${req.method} ${req.path}`);
});

// Central error handler — Express identifies it by the 4-argument signature.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, _next) => {
  if (err?.type === 'entity.parse.failed') {
    return jsonError(res, 400, 'invalid_json', 'Request body is not valid JSON.');
  }
  if (err?.type === 'entity.too.large') {
    return jsonError(res, 413, 'payload_too_large', `Body exceeds ${config.bodyLimit}.`);
  }
  logger.error(`unhandled error rid=${req.id}:`, err);
  return jsonError(res, 500, 'internal_error', 'Unexpected server error.');
});

/* ==========================================================================
 * 9. BOOTSTRAP + GRACEFUL SHUTDOWN
 * ========================================================================== */

function bootstrap() {
  for (const key of config.seedApiKeys) createApiKey(key, 'env:API_KEYS');
  for (const token of config.seedDeviceTokens) createDeviceToken(token, 'env:DEVICE_TOKENS');

  // Zero-config developer experience: mint credentials on first boot and print
  // them once. In production set API_KEYS / DEVICE_TOKENS explicitly.
  if (store.apiKeys.size === 0) {
    const generated = `sk_${config.env}_${crypto.randomBytes(24).toString('base64url')}`;
    createApiKey(generated, 'generated-at-boot');
    logger.warn(`No API_KEYS configured. Generated API key: ${generated}`);
  }
  if (store.deviceTokens.size === 0) {
    const generated = `dt_${crypto.randomBytes(24).toString('base64url')}`;
    createDeviceToken(generated, 'generated-at-boot');
    logger.warn(`No DEVICE_TOKENS configured. Generated device token: ${generated}`);
  }
  if (!config.adminToken) {
    logger.warn('ADMIN_TOKEN is empty — /api/v1/admin/* is disabled.');
  }
}

const server = http.createServer(app);

// Authenticate the upgrade *before* the WebSocket handshake completes.
server.on('upgrade', (req, socket, head) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch {
    socket.destroy();
    return;
  }

  if (url.pathname !== config.wsPath) {
    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }

  const bearer = req.headers.authorization || '';
  const headerToken =
    req.headers['x-device-token'] ||
    (bearer.toLowerCase().startsWith('bearer ') ? bearer.slice(7).trim() : '');
  const rawToken = url.searchParams.get('token') || headerToken || '';
  const tokenRecord = rawToken ? findDeviceToken(rawToken) || findApiKey(rawToken) : null;

  // No token yet is allowed: the client may authenticate with a `hello` frame
  // inside the grace window (keeps the secret out of proxy access logs).
  if (rawToken && (!tokenRecord || !tokenRecord.active)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, (ws) => {
    wss.emit('connection', ws, req, {
      tokenRecord,
      deviceId: sanitizeDeviceId(url.searchParams.get('deviceId')),
      appVersion: url.searchParams.get('appVersion'),
    });
  });
});

bootstrap();

server.listen(config.port, config.host, () => {
  logger.info(`OpenSMS relay ${config.version} (${config.env}) listening on http://${config.host}:${config.port}`);
  logger.info(`WebSocket endpoint: ws://${config.host}:${config.port}${config.wsPath}`);
});

const reaperTimer = setInterval(reap, 15_000);
const socketTimer = setInterval(sweepSockets, config.wsHeartbeatMs);

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info(`${signal} received — shutting down`);

  clearInterval(reaperTimer);
  clearInterval(socketTimer);

  for (const ws of wss.clients) {
    sendJson(ws, { type: 'server_shutdown', retryInMs: 3000 });
    closeSocket(ws, 1012, 'server restarting');
  }
  wss.close();

  server.close(() => {
    logger.info('HTTP server closed. Bye.');
    process.exit(0);
  });

  // Don't hang forever on keep-alive connections.
  setTimeout(() => process.exit(0), 5000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('unhandledRejection', (reason) => logger.error('unhandledRejection:', reason));
process.on('uncaughtException', (err) => logger.error('uncaughtException:', err));

export { app, server, wss, store, config, flush };
