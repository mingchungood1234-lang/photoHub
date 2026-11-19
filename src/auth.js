const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { sanitizeUserFolder } = require('./config');

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

function isAllowedAppRedirectUri(rawUri) {
  if (!rawUri || typeof rawUri !== 'string') return false;
  try {
    const u = new URL(rawUri);
    return u.protocol === 'photohub:' && u.hostname === 'auth';
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
 * 2) Existing pinned node if still configured in STORAGE_NODES
 * 3) Highest-Random-Weight (Rendezvous) consistent hashing across STORAGE_NODES
 * 4) Gateway itself as single-node fallback
 */
function selectNodeForUser({ sub, email, publicBaseUrl, config, existingNodeId }) {
  const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];
  const lowerEmail = String(email || '').trim().toLowerCase();

  if (lowerEmail && config.userNodeMap instanceof Map && config.userNodeMap.has(lowerEmail)) {
    const mappedId = config.userNodeMap.get(lowerEmail);
    const mappedNode = nodes.find((n) => n.id === mappedId);
    if (mappedNode) {
      return { nodeId: mappedNode.id, serverUrl: mappedNode.url };
    }
    if (/^https?:\/\//i.test(mappedId)) {
      return { nodeId: 'custom', serverUrl: mappedId.replace(/\/+$/, '') };
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
          if (rec && rec.folderName) {
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

  async upsertGoogleUser({ sub, email, name, picture, publicBaseUrl, config }) {
    const cleanSub = String(sub || '').trim();
    const cleanEmail = String(email || '').trim().toLowerCase();
    const existing = this.usersBySub.get(cleanSub);

    const folderName =
      (existing && existing.folderName) || sanitizeGoogleFolderName(cleanEmail, cleanSub);
    const { nodeId, serverUrl } = selectNodeForUser({
      sub: cleanSub,
      email: cleanEmail,
      publicBaseUrl,
      config,
      existingNodeId: existing ? existing.nodeId : null,
    });
    const quotaBytes = resolveQuotaBytes(
      { email: cleanEmail, folderName },
      config
    );

    const record = {
      sub: cleanSub,
      email: cleanEmail,
      name: String(name || cleanEmail.split('@')[0] || 'User').trim(),
      picture: picture ? String(picture) : null,
      folderName,
      nodeId,
      assignedUrl: serverUrl,
      quotaBytes,
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

function isGoogleUserAllowed(email, config) {
  const lower = String(email || '').trim().toLowerCase();
  if (!lower || !lower.includes('@')) return false;
  const hasEmailList =
    config.allowedGoogleEmails instanceof Set && config.allowedGoogleEmails.size > 0;
  const hasDomainList =
    config.allowedGoogleDomains instanceof Set && config.allowedGoogleDomains.size > 0;

  if (!hasEmailList && !hasDomainList) return true;
  if (hasEmailList && config.allowedGoogleEmails.has(lower)) return true;
  const domain = lower.split('@')[1] || '';
  if (hasDomainList && config.allowedGoogleDomains.has(domain)) return true;
  return false;
}

async function exchangeGoogleCodeForProfile({
  code,
  redirectUri,
  config,
  fetchFn = fetch,
}) {
  const tokenRes = await fetchFn('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      code: String(code),
      client_id: config.googleClientId,
      client_secret: config.googleClientSecret,
      redirect_uri: redirectUri,
      grant_type: 'authorization_code',
    }),
  });
  const tokenData = await tokenRes.json().catch(() => ({}));
  if (!tokenRes.ok || !tokenData || (!tokenData.id_token && !tokenData.access_token)) {
    const msg =
      (tokenData && (tokenData.error_description || tokenData.error)) ||
      `Google token exchange failed (${tokenRes.status})`;
    const err = new Error(msg);
    err.statusCode = 401;
    throw err;
  }

  let profile = null;
  if (tokenData.id_token) {
    const infoRes = await fetchFn(
      `https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(tokenData.id_token)}`
    );
    const info = await infoRes.json().catch(() => ({}));
    if (!infoRes.ok || !info || !info.sub || !info.email) {
      const err = new Error('Google ID token verification failed.');
      err.statusCode = 401;
      throw err;
    }
    if (config.googleClientId && info.aud !== config.googleClientId) {
      const err = new Error('Google ID token audience mismatch.');
      err.statusCode = 401;
      throw err;
    }
    if (info.email_verified !== true && info.email_verified !== 'true') {
      const err = new Error('Google email address is not verified.');
      err.statusCode = 403;
      throw err;
    }
    profile = {
      sub: info.sub,
      email: info.email,
      name: info.name || info.email,
      picture: info.picture || null,
    };
  } else {
    const userRes = await fetchFn('https://openidconnect.googleapis.com/v1/userinfo', {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    });
    const info = await userRes.json().catch(() => ({}));
    if (!userRes.ok || !info || !info.sub || !info.email || !info.email_verified) {
      const err = new Error('Google user profile verification failed.');
      err.statusCode = 401;
      throw err;
    }
    profile = {
      sub: info.sub,
      email: info.email,
      name: info.name || info.email,
      picture: info.picture || null,
    };
  }

  if (!isGoogleUserAllowed(profile.email, config)) {
    const err = new Error('This Google account is not authorized on this PhotoHub server.');
    err.statusCode = 403;
    throw err;
  }

  return profile;
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
  UserDirectory,
  OneTimeExchangeStore,
  isGoogleUserAllowed,
  exchangeGoogleCodeForProfile,
};
