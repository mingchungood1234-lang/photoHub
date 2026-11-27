/**
 * USERS, SESSION TOKENS (JWT), PKCE & NODE ROUTING MODEL
 *
 * Where this belongs: `src/models/userModel.js` (Data / Model Layer).
 * Used by:
 *   - `src/app.js` (`resolveSessionSecret`, `UserDirectory`, `OneTimeExchangeStore`)
 *   - `src/middleware/authMiddleware.js` (`verifyToken`, `resolveConfiguredUserFolder`)
 *   - `src/controllers/authController.js` (`signToken`, `verifyToken`, `isAllowedAppRedirectUri`, `selectNodeForUser`)
 *   - `src/services/contextService.js` (`resolveQuotaBytes`)
 * Where data goes on disk:
 *   - `DATA_DIR/auth-secret.key` (auto-generated HMAC secret for signing session tokens)
 *   - `DATA_DIR/users.json` (persistent JSON map of Google user `sub` -> folder, assigned node, quota)
 */

const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { sanitizeUserFolder, normalizeNodeUrl } = require('../config/env');

function toBase64Url(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(String(input), 'utf8');
  return buf
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function fromBase64Url(str) {
  const normalized = String(str || '')
    .replace(/-/g, '+')
    .replace(/_/g, '/');
  const padLen = (4 - (normalized.length % 4)) % 4;
  return Buffer.from(normalized + '='.repeat(padLen), 'base64');
}

async function resolveSessionSecret(configuredSecret, dataDir) {
  if (configuredSecret && typeof configuredSecret === 'string' && configuredSecret.trim()) {
    return configuredSecret.trim();
  }
  await fsp.mkdir(dataDir, { recursive: true });
  const secretPath = path.join(dataDir, 'auth-secret.key');
  try {
    const existing = (await fsp.readFile(secretPath, 'utf8')).trim();
    if (existing.length >= 32) {
      return existing;
    }
  } catch (err) {
    if (err.code !== 'ENOENT') {
      throw err;
    }
  }
  const generated = crypto.randomBytes(32).toString('hex');
  await fsp.writeFile(secretPath, `${generated}\n`, { encoding: 'utf8', mode: 0o600 });
  return generated;
}

function signToken(payload, secret, ttlSeconds = 3600) {
  const nowSec = Math.floor(Date.now() / 1000);
  const header = toBase64Url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = toBase64Url(
    JSON.stringify({
      ...payload,
      iat: nowSec,
      exp: nowSec + Math.max(1, Number(ttlSeconds) || 3600),
    })
  );
  const signingInput = `${header}.${body}`;
  const sig = toBase64Url(
    crypto.createHmac('sha256', secret).update(signingInput).digest()
  );
  return `${signingInput}.${sig}`;
}

function verifyToken(token, secret) {
  if (!token || typeof token !== 'string' || !secret) return null;
  const parts = token.trim().split('.');
  if (parts.length !== 3) return null;
  const [headerB64, bodyB64, sigB64] = parts;
  if (!headerB64 || !bodyB64 || !sigB64) return null;

  const signingInput = `${headerB64}.${bodyB64}`;
  const expectedSig = crypto
    .createHmac('sha256', secret)
    .update(signingInput)
    .digest();
  let providedSig;
  try {
    providedSig = fromBase64Url(sigB64);
  } catch {
    return null;
  }
  if (
    providedSig.length !== expectedSig.length ||
    !crypto.timingSafeEqual(providedSig, expectedSig)
  ) {
    return null;
  }

  try {
    const payload = JSON.parse(fromBase64Url(bodyB64).toString('utf8'));
    if (!payload || typeof payload !== 'object') return null;
    const nowSec = Math.floor(Date.now() / 1000);
    if (typeof payload.exp !== 'number' || payload.exp <= nowSec) {
      return null;
    }
    return payload;
  } catch {
    return null;
  }
}

function verifyPkceCodeChallenge(codeVerifier, expectedChallenge) {
  if (
    typeof codeVerifier !== 'string' ||
    typeof expectedChallenge !== 'string' ||
    codeVerifier.length < 32 ||
    codeVerifier.length > 256
  ) {
    return false;
  }
  const actual = Buffer.from(
    toBase64Url(crypto.createHash('sha256').update(codeVerifier, 'utf8').digest()),
    'utf8'
  );
  const expected = Buffer.from(expectedChallenge.trim(), 'utf8');
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

function isAllowedAppRedirectUri(rawUri, allowedWebOrigin = null) {
  if (!rawUri || typeof rawUri !== 'string') return false;
  try {
    const u = new URL(rawUri);
    if (u.protocol === 'photohub:' && u.hostname === 'auth') {
      return true;
    }
    if (allowedWebOrigin && (u.protocol === 'http:' || u.protocol === 'https:')) {
      const expected = new URL(allowedWebOrigin);
      if (
        u.origin === expected.origin &&
        (u.pathname === '/' || u.pathname === '/auth/callback')
      ) {
        return true;
      }
    }
    return false;
  } catch {
    return false;
  }
}

function sanitizeGoogleFolderName(email, sub) {
  const localPart = String(email || 'user')
    .split('@')[0]
    .replace(/[^a-zA-Z0-9_-]/g, '_')
    .replace(/_+/g, '_')
    .slice(0, 24)
    .replace(/^_+|_+$/g, '') || 'user';
  const digest = crypto
    .createHash('sha256')
    .update(String(sub || email))
    .digest('hex')
    .slice(0, 8);
  return sanitizeUserFolder(`google_${localPart}_${digest}`);
}

/**
 * Selects the user's storage server URL using:
 * 1) Explicit USER_NODE_MAP override
 * 2) Gateway itself when STORAGE_NODES is not configured
 * 3) Existing pinned node if still configured in STORAGE_NODES
 * 4) Pre-resolved `preferredNodeId` (from ordered capacity failover)
 * 5) Consistent hashing (when NODE_ALLOCATION_MODE=hash) OR first configured node (`node1`, ordered default)
 */
function selectNodeForUser({ sub, email, publicBaseUrl, config, existingNodeId, preferredNodeId }) {
  const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];
  const lowerEmail = String(email || '').trim().toLowerCase();

  if (lowerEmail && config.userNodeMap instanceof Map && config.userNodeMap.has(lowerEmail)) {
    const mappedId = config.userNodeMap.get(lowerEmail);
    const mappedNode = nodes.find((n) => n.id === mappedId);
    if (mappedNode) {
      return { nodeId: mappedNode.id, serverUrl: mappedNode.url };
    }
    if (/^https?:\/\//i.test(mappedId) || /[:./]/.test(mappedId)) {
      const normalizedCustom = normalizeNodeUrl(mappedId, 'http');
      if (normalizedCustom) {
        return { nodeId: 'custom', serverUrl: normalizedCustom };
      }
    }
  }

  if (nodes.length === 0) {
    return { nodeId: 'primary', serverUrl: String(publicBaseUrl || '').replace(/\/+$/, '') };
  }

  if (existingNodeId) {
    const existingNode = nodes.find((n) => n.id === existingNodeId);
    if (existingNode) {
      return { nodeId: existingNode.id, serverUrl: existingNode.url };
    }
  }

  if (preferredNodeId) {
    const preferredNode = nodes.find((n) => n.id === preferredNodeId);
    if (preferredNode) {
      return { nodeId: preferredNode.id, serverUrl: preferredNode.url };
    }
  }

  if (config.nodeAllocationMode === 'hash') {
    const key = String(sub || lowerEmail || 'default');
    let bestNode = nodes[0];
    let bestScore = '';
    for (const node of nodes) {
      const score = crypto.createHash('sha256').update(`${key}:${node.id}`).digest('hex');
      if (score > bestScore) {
        bestScore = score;
        bestNode = node;
      }
    }
    return { nodeId: bestNode.id, serverUrl: bestNode.url };
  }

  return { nodeId: nodes[0].id, serverUrl: nodes[0].url };
}

function resolveQuotaBytes({ email, folderName, apiKey }, config) {
  const quotaMap = config.userQuotaMap;
  if (quotaMap instanceof Map && quotaMap.size > 0) {
    const candidates = [email, folderName, apiKey]
      .filter((v) => typeof v === 'string' && v.trim() !== '')
      .map((v) => v.trim().toLowerCase());
    for (const key of candidates) {
      if (quotaMap.has(key)) {
        return Math.max(0, Number(quotaMap.get(key)) || 0);
      }
    }
  }
  return Math.max(0, Number(config.defaultQuotaBytes) || 0);
}

function resolveConfiguredUserFolder(email, config) {
  const lower = String(email || '').trim().toLowerCase();
  if (!lower || !(config.userFolderMap instanceof Map) || !config.userFolderMap.has(lower)) {
    return { matched: false, folderName: null };
  }
  const mapped = config.userFolderMap.get(lower);
  if (mapped === '__ROOT__' || !mapped) {
    return { matched: true, folderName: null };
  }
  return { matched: true, folderName: mapped };
}

class UserDirectory {
  constructor(dataDir) {
    this.filePath = path.join(dataDir, 'users.json');
    this.usersBySub = new Map();
    this.writePromise = Promise.resolve();
  }

  async init() {
    await fsp.mkdir(path.dirname(this.filePath), { recursive: true });
    try {
      const raw = await fsp.readFile(this.filePath, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') {
        for (const [sub, rec] of Object.entries(parsed)) {
          if (rec && (rec.folderName !== undefined || rec.email)) {
            this.usersBySub.set(sub, rec);
          }
        }
      }
    } catch (err) {
      if (err.code !== 'ENOENT') {
        console.warn('Warning: could not read users.json, starting fresh:', err.message);
      }
    }
  }

  getBySub(sub) {
    return this.usersBySub.get(String(sub || '')) || null;
  }

  getByEmail(email) {
    const clean = String(email || '').trim().toLowerCase();
    if (!clean) return null;
    for (const rec of this.usersBySub.values()) {
      if (rec && String(rec.email || '').trim().toLowerCase() === clean) {
        return rec;
      }
    }
    return null;
  }

  listAll() {
    return Array.from(this.usersBySub.values());
  }

  async setQuotaOverride(subOrEmail, quotaBytes) {
    const key = String(subOrEmail || '').trim();
    const record = this.getBySub(key) || this.getByEmail(key);
    if (!record) return null;
    if (quotaBytes === null || quotaBytes === undefined) {
      delete record.quotaBytesOverride;
      record.quotaBytes = null;
    } else {
      const cleanBytes = Math.max(0, Number(quotaBytes) || 0);
      record.quotaBytesOverride = cleanBytes;
      record.quotaBytes = cleanBytes;
    }
    this.usersBySub.set(record.sub, record);
    await this.persist();
    return record;
  }

  async upsertGoogleUser({ sub, email, name, picture, publicBaseUrl, config, preferredNodeId = null }) {
    const cleanSub = String(sub || '').trim();
    const cleanEmail = String(email || '').trim().toLowerCase();
    const existing = this.usersBySub.get(cleanSub);

    const configured = resolveConfiguredUserFolder(cleanEmail, config);
    const folderName = configured.matched
      ? configured.folderName
      : (existing && existing.folderName !== undefined
          ? existing.folderName
          : sanitizeGoogleFolderName(cleanEmail, cleanSub));
    const { nodeId, serverUrl } = selectNodeForUser({
      sub: cleanSub,
      email: cleanEmail,
      publicBaseUrl,
      config,
      existingNodeId: existing ? existing.nodeId : null,
      preferredNodeId,
    });
    const quotaBytes =
      existing && existing.quotaBytesOverride !== undefined
        ? Math.max(0, Number(existing.quotaBytesOverride) || 0)
        : resolveQuotaBytes({ email: cleanEmail, folderName }, config);

    const record = {
      sub: cleanSub,
      email: cleanEmail,
      name: String(name || cleanEmail.split('@')[0] || 'User').trim(),
      picture: picture ? String(picture) : null,
      folderName,
      nodeId,
      assignedUrl: serverUrl,
      quotaBytes,
      ...(existing && existing.quotaBytesOverride !== undefined
        ? { quotaBytesOverride: existing.quotaBytesOverride }
        : {}),
      createdAt: (existing && existing.createdAt) || new Date().toISOString(),
      lastLoginAt: new Date().toISOString(),
    };
    this.usersBySub.set(cleanSub, record);
    await this.persist();
    return record;
  }

  async persist() {
    this.writePromise = this.writePromise.then(async () => {
      const obj = Object.fromEntries(this.usersBySub.entries());
      const tmp = `${this.filePath}.tmp`;
      await fsp.writeFile(tmp, JSON.stringify(obj, null, 2), 'utf8');
      await fsp.rename(tmp, this.filePath);
    });
    return this.writePromise;
  }
}

class OneTimeExchangeStore {
  constructor(ttlMs = 120_000) {
    this.ttlMs = ttlMs;
    this.codes = new Map();
  }

  issue({ codeChallenge, sessionPayload }) {
    const now = Date.now();
    for (const [k, entry] of this.codes.entries()) {
      if (entry.expiresAt <= now) {
        this.codes.delete(k);
      }
    }
    const code = crypto.randomBytes(24).toString('hex');
    this.codes.set(code, {
      codeChallenge: String(codeChallenge || '').trim(),
      sessionPayload,
      expiresAt: now + this.ttlMs,
    });
    return code;
  }

  consume({ code, codeVerifier }) {
    const cleanCode = String(code || '').trim();
    const entry = this.codes.get(cleanCode);
    this.codes.delete(cleanCode);
    if (!entry || entry.expiresAt <= Date.now()) {
      return null;
    }
    if (!verifyPkceCodeChallenge(codeVerifier, entry.codeChallenge)) {
      return null;
    }
    return entry.sessionPayload;
  }
}

module.exports = {
  resolveSessionSecret,
  signToken,
  verifyToken,
  verifyPkceCodeChallenge,
  isAllowedAppRedirectUri,
  sanitizeGoogleFolderName,
  selectNodeForUser,
  resolveQuotaBytes,
  resolveConfiguredUserFolder,
  UserDirectory,
  OneTimeExchangeStore,
};
