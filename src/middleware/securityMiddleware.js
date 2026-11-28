/**
 * BACKEND SECURITY & ABUSE-PREVENTION MIDDLEWARE (Zero External Dependencies)
 *
 * Protects PhotoHub against:
 *   - Clickjacking, MIME-sniffing XSS, referrer leaks, and server fingerprinting
 *   - Brute-force attacks against API keys, Admin keys, OAuth exchange, and Share passcodes
 *   - API flooding & heavy-operation CPU/disk exhaustion (ZIP, cleanup, proxy transcode, rescans)
 *   - Prototype pollution (`__proto__`, `constructor`, `prototype`) & deeply nested JSON bombs
 *   - Malformed URI encodings, null-byte injections, and excessively long request URLs
 *   - Timing side-channel leaks on API keys
 */

const crypto = require('crypto');

const DANGEROUS_KEYS = new Set(['__proto__', 'constructor', 'prototype']);
const MAX_URL_LENGTH = 4096;
const MAX_JSON_DEPTH = 20;
const MAX_JSON_KEYS = 10000;
const MAX_RATE_LIMIT_TRACKED_KEYS = 20000;

function timingSafeEqualStr(a, b) {
  const bufA = Buffer.from(String(a || ''), 'utf8');
  const bufB = Buffer.from(String(b || ''), 'utf8');
  if (bufA.length === 0 || bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function safeDecodeURIComponent(raw) {
  const str = String(raw ?? '');
  if (!str) return '';
  try {
    return decodeURIComponent(str);
  } catch {
    return str;
  }
}

function getClientIp(req) {
  const ip = req.ip || (req.socket && req.socket.remoteAddress) || 'unknown';
  return String(ip).replace(/^::ffff:/, '').slice(0, 64);
}

/**
 * Sets hardened HTTP security headers on every response without breaking
 * Google OAuth login, Leaflet/Google Maps tiles, or authenticated media streaming.
 */
function securityHeadersMiddleware(req, res, next) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'SAMEORIGIN');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('X-Permitted-Cross-Domain-Policies', 'none');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(), usb=()');
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin-allow-popups');

  const proto = String(req.headers['x-forwarded-proto'] || req.protocol || '')
    .split(',')[0]
    .trim()
    .toLowerCase();
  if (req.secure || proto === 'https') {
    res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  }
  return next();
}

/**
 * Rejects oversized URLs, null-byte path injections, and malformed percent-encodings
 * before any route or controller runs.
 */
function requestSanityMiddleware(req, res, next) {
  const rawUrl = String(req.url || '');
  if (rawUrl.length > MAX_URL_LENGTH) {
    return res.status(414).json({
      success: false,
      canDelete: false,
      error: 'Request URL is too long.',
    });
  }
  if (rawUrl.includes('\0') || /%00/i.test(rawUrl)) {
    return res.status(400).json({
      success: false,
      canDelete: false,
      error: 'Invalid null byte in request URL.',
    });
  }
  const qIdx = rawUrl.indexOf('?');
  const pathPart = qIdx >= 0 ? rawUrl.slice(0, qIdx) : rawUrl;
  try {
    decodeURIComponent(pathPart);
  } catch {
    return res.status(400).json({
      success: false,
      canDelete: false,
      error: 'Malformed URL encoding.',
    });
  }
  return next();
}

/**
 * Recursively strips prototype-pollution keys (`__proto__`, `constructor`, `prototype`)
 * and enforces bounded object nesting depth & total key count on parsed JSON bodies.
 */
function sanitizeObjectTree(value, depth = 0, counter = { keys: 0 }) {
  if (depth > MAX_JSON_DEPTH) {
    const err = new Error('JSON payload nesting depth exceeds allowed limit.');
    err.status = 400;
    err.statusCode = 400;
    throw err;
  }
  if (value === null || typeof value !== 'object') {
    return value;
  }
  if (Array.isArray(value)) {
    counter.keys += value.length;
    if (counter.keys > MAX_JSON_KEYS) {
      const err = new Error('JSON payload contains too many items.');
      err.status = 400;
      err.statusCode = 400;
      throw err;
    }
    for (let i = 0; i < value.length; i++) {
      value[i] = sanitizeObjectTree(value[i], depth + 1, counter);
    }
    return value;
  }

  for (const key of Object.keys(value)) {
    counter.keys += 1;
    if (counter.keys > MAX_JSON_KEYS) {
      const err = new Error('JSON payload contains too many keys.');
      err.status = 400;
      err.statusCode = 400;
      throw err;
    }
    if (DANGEROUS_KEYS.has(key)) {
      delete value[key];
      continue;
    }
    value[key] = sanitizeObjectTree(value[key], depth + 1, counter);
  }
  return value;
}

function sanitizeJsonBodyMiddleware(req, res, next) {
  if (req.body && typeof req.body === 'object' && !Buffer.isBuffer(req.body)) {
    try {
      sanitizeObjectTree(req.body, 0, { keys: 0 });
    } catch (err) {
      return res.status(err.statusCode || 400).json({
        success: false,
        canDelete: false,
        error: err.message || 'Invalid JSON payload.',
      });
    }
  }
  return next();
}

/**
 * Memory-bounded fixed-window rate limiter with optional failed-only tracking
 * (`countFailuresOnly: true`) so brute-force attempts lock out while valid users flow freely.
 */
function createRateLimiter({
  windowMs = 60_000,
  max = 1200,
  enabled = true,
  countFailuresOnly = false,
  failureStatuses = new Set([401]),
  keyGenerator = (req) => getClientIp(req),
  skip = null,
  message = 'Too many requests. Please slow down and try again shortly.',
} = {}) {
  const buckets = new Map(); // key -> { count, resetAt }
  let opsSinceSweep = 0;

  const sweepExpired = (now) => {
    for (const [k, b] of buckets.entries()) {
      if (b.resetAt <= now) {
        buckets.delete(k);
      }
    }
    // Hard cap prevents RAM growth even under a distributed spoofed-IP flood
    while (buckets.size > MAX_RATE_LIMIT_TRACKED_KEYS) {
      const oldestKey = buckets.keys().next().value;
      if (oldestKey === undefined) break;
      buckets.delete(oldestKey);
    }
  };

  const getOrCreateBucket = (key, now) => {
    let b = buckets.get(key);
    if (!b || b.resetAt <= now) {
      b = { count: 0, resetAt: now + windowMs };
      buckets.set(key, b);
    }
    return b;
  };

  return function rateLimitMiddleware(req, res, next) {
    if (!enabled || max <= 0) return next();
    if (typeof skip === 'function' && skip(req)) return next();

    const now = Date.now();
    opsSinceSweep += 1;
    if (opsSinceSweep >= 250 || buckets.size > MAX_RATE_LIMIT_TRACKED_KEYS) {
      opsSinceSweep = 0;
      sweepExpired(now);
    }

    const key = String(keyGenerator(req) || 'unknown');
    const bucket = getOrCreateBucket(key, now);

    if (bucket.count >= max) {
      const retryAfterSec = Math.max(1, Math.ceil((bucket.resetAt - now) / 1000));
      res.setHeader('Retry-After', String(retryAfterSec));
      res.setHeader('RateLimit-Limit', String(max));
      res.setHeader('RateLimit-Remaining', '0');
      res.setHeader('RateLimit-Reset', String(retryAfterSec));
      return res.status(429).json({
        success: false,
        canDelete: false,
        error: message,
        retryAfterSeconds: retryAfterSec,
      });
    }

    if (countFailuresOnly) {
      // Only penalize failed authentication / passcode guesses (401/403)
      res.on('finish', () => {
        if (failureStatuses.has(res.statusCode)) {
          const finishNow = Date.now();
          const b = getOrCreateBucket(key, finishNow);
          b.count += 1;
        }
      });
      return next();
    }

    bucket.count += 1;
    const remaining = Math.max(0, max - bucket.count);
    const resetSec = Math.max(1, Math.ceil((bucket.resetAt - now) / 1000));
    res.setHeader('RateLimit-Limit', String(max));
    res.setHeader('RateLimit-Remaining', String(remaining));
    res.setHeader('RateLimit-Reset', String(resetSec));
    return next();
  };
}

/**
 * Limits how many concurrent expensive requests (ZIP export, cleanup scan, proxy transcode,
 * GPS rescan) a single user/IP can run simultaneously so one client cannot starve the server.
 */
function createConcurrencyGuard({
  maxConcurrent = 2,
  keyGenerator = (req) =>
    (req.userContext && (req.userContext.folderName || req.userContext.email || req.userContext.apiKey)) ||
    getClientIp(req),
  skip = null,
  message = 'Another heavy operation is already running for your account. Please wait a moment.',
} = {}) {
  const activeByKey = new Map();

  return function concurrencyGuardMiddleware(req, res, next) {
    if (typeof skip === 'function' && skip(req)) return next();

    const key = String(keyGenerator(req) || 'unknown');
    const current = activeByKey.get(key) || 0;
    if (current >= maxConcurrent) {
      res.setHeader('Retry-After', '3');
      return res.status(429).json({
        success: false,
        canDelete: false,
        error: message,
      });
    }

    activeByKey.set(key, current + 1);
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      const cur = (activeByKey.get(key) || 1) - 1;
      if (cur <= 0) activeByKey.delete(key);
      else activeByKey.set(key, cur);
    };

    res.on('finish', release);
    res.on('close', release);
    return next();
  };
}

module.exports = {
  timingSafeEqualStr,
  safeDecodeURIComponent,
  getClientIp,
  securityHeadersMiddleware,
  requestSanityMiddleware,
  sanitizeJsonBodyMiddleware,
  createRateLimiter,
  createConcurrencyGuard,
};
