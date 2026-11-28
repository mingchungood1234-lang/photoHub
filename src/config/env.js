/**
 * CONFIGURATION LAYER — Reads `.env` & Builds Normalized Settings
 *
 * Where this belongs: `src/config/env.js`.
 * Where it goes: Imported by `src/app.js` at startup (via `getConfig(overrides)`)
 * and `src/models/userModel.js` (uses `sanitizeUserFolder`).
 *
 * In Node.js, `process.env` holds all environment variables (populated from `.env`
 * by `dotenv.config()`). `getConfig(overrides)` lets tests override settings in memory
 * without touching your real `.env` file.
 */

const os = require('os');
const path = require('path');
require('dotenv').config();

function resolvePath(rootDir, rawPath) {
  const trimmed = String(rawPath || '').trim();
  if (trimmed.startsWith('~/') || trimmed === '~') {
    return path.join(os.homedir(), trimmed.slice(1));
  }
  if (path.isAbsolute(trimmed)) {
    return path.normalize(trimmed);
  }
  return path.resolve(rootDir, trimmed);
}

/**
 * Parses USER_KEYS="key1:folder1,key2:folder2" into a Map of apiKey -> safe folder name.
 */
function parseUserKeys(rawUserKeys) {
  const map = new Map();
  if (!rawUserKeys || typeof rawUserKeys !== 'string') {
    return map;
  }

  const entries = rawUserKeys
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  for (const entry of entries) {
    const colonIdx = entry.indexOf(':');
    if (colonIdx === -1) {
      // If only "mingchun" is given without ":", use "mingchun" as both key and folder name
      const keyAndFolder = entry.trim();
      const safeFolder = sanitizeUserFolder(keyAndFolder);
      if (keyAndFolder && safeFolder) {
        map.set(keyAndFolder, safeFolder);
      }
    } else {
      const key = entry.slice(0, colonIdx).trim();
      const rawFolder = entry.slice(colonIdx + 1).trim();
      const safeFolder = sanitizeUserFolder(rawFolder);
      if (key && safeFolder) {
        map.set(key, safeFolder);
      }
    }
  }

  return map;
}

function sanitizeUserFolder(rawFolder) {
  const normalized = String(rawFolder || '')
    .trim()
    .replace(/\\/g, '/')
    .split('/')
    .map((segment) => segment.replace(/[<>:"|?*\x00-\x1F]/g, '_').trim())
    .filter((segment) => segment && segment !== '.' && segment !== '..')
    .join('/');
  return normalized;
}

function parseListCsv(raw) {
  if (!raw || typeof raw !== 'string') return new Set();
  return new Set(
    raw
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean)
  );
}

/**
 * Normalizes a storage node URL without forcing HTTPS.
 * Explicit `http://` or `https://` schemes are preserved; scheme-less hosts default
 * to `http://` (or `https://` if port `:443`) so LAN/VPN/IP storage nodes work over HTTP.
 */
function normalizeNodeUrl(rawUrl, defaultProtocol = 'http') {
  const trimmed = String(rawUrl || '').trim().replace(/\/+$/, '');
  if (!trimmed) return '';
  if (/^https?:\/\//i.test(trimmed)) {
    return trimmed;
  }
  const proto = /:443(?:\/|$)/.test(trimmed) ? 'https' : defaultProtocol;
  return `${proto}://${trimmed}`;
}

/**
 * Parses STORAGE_NODES="node1=https://s1.example.com,node2=http://192.168.1.50:3000"
 * into [{ id, url }].
 */
function parseStorageNodes(rawNodes) {
  if (Array.isArray(rawNodes)) {
    return rawNodes
      .map((item) => ({
        id: String(item.id || '').trim(),
        url: normalizeNodeUrl(item.url, 'http'),
      }))
      .filter((item) => item.id && item.url);
  }
  if (!rawNodes || typeof rawNodes !== 'string') return [];

  const nodes = [];
  const seen = new Set();
  for (const entry of rawNodes.split(',')) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const eqIdx = trimmed.indexOf('=');
    const id = (eqIdx !== -1 ? trimmed.slice(0, eqIdx) : `node${nodes.length + 1}`).trim();
    const rawUrl = eqIdx !== -1 ? trimmed.slice(eqIdx + 1) : trimmed;
    const url = normalizeNodeUrl(rawUrl, 'http');
    if (id && url && !seen.has(id)) {
      seen.add(id);
      nodes.push({ id, url });
    }
  }
  return nodes;
}

/**
 * Parses comma-separated pairs like "alice@gmail.com=node2" or "mingchun:50".
 */
function parsePairMap(raw, valueTransform = (v) => v) {
  const map = new Map();
  if (raw instanceof Map) {
    for (const [k, v] of raw.entries()) {
      const cleanKey = String(k || '').trim().toLowerCase();
      if (cleanKey) map.set(cleanKey, valueTransform(v));
    }
    return map;
  }
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const [k, v] of Object.entries(raw)) {
      const cleanKey = String(k || '').trim().toLowerCase();
      if (cleanKey) map.set(cleanKey, valueTransform(v));
    }
    return map;
  }
  if (!raw || typeof raw !== 'string') return map;

  for (const entry of raw.split(',')) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const eqIdx = trimmed.indexOf('=');
    const sepIdx = eqIdx !== -1 ? eqIdx : trimmed.indexOf(':');
    if (sepIdx === -1) continue;
    const key = trimmed.slice(0, sepIdx).trim().toLowerCase();
    const val = trimmed.slice(sepIdx + 1).trim();
    if (key && val !== '') {
      map.set(key, valueTransform(val));
    }
  }
  return map;
}

function normalizeNodeAllocationMode(rawMode) {
  const clean = String(rawMode || 'ordered').trim().toLowerCase();
  if (clean === 'hash' || clean === 'rendezvous') return 'hash';
  return 'ordered';
}

function gbToBytes(rawGb) {
  const num = Number(rawGb);
  if (!Number.isFinite(num) || num <= 0) return 0;
  // Use SI base-10 GB (1000^3) to match iOS ByteCountFormatter (.file), so 5000 GB displays as 5 TB
  return Math.round(num * 1000 * 1000 * 1000);
}

function getConfig(overrides = {}) {
  const rootDir = path.resolve(__dirname, '..', '..');
  const defaultStorage =
    process.platform === 'linux' ? '/home/ubuntu/gdrive/photoHUB' : './uploads';

  const storageDir = resolvePath(
    rootDir,
    overrides.storageDir || process.env.STORAGE_DIR || defaultStorage
  );
  const dataDir = resolvePath(
    rootDir,
    overrides.dataDir || process.env.DATA_DIR || './data'
  );

  const rawUserKeys = overrides.userKeys ?? process.env.USER_KEYS ?? '';
  const userKeyMap =
    rawUserKeys instanceof Map ? rawUserKeys : parseUserKeys(rawUserKeys);

  const rawEnvMaxMb = Number(process.env.MAX_FILE_SIZE_MB);
  const effectiveMaxMb =
    overrides.maxFileSizeMb !== undefined
      ? Number(overrides.maxFileSizeMb)
      : Number.isFinite(rawEnvMaxMb) && rawEnvMaxMb >= 5000
        ? rawEnvMaxMb
        : 50000;

  const defaultQuotaBytes =
    overrides.defaultQuotaBytes !== undefined
      ? Math.max(0, Number(overrides.defaultQuotaBytes) || 0)
      : gbToBytes(overrides.defaultQuotaGb ?? process.env.DEFAULT_QUOTA_GB ?? 0);

  const userQuotaMap = parsePairMap(
    overrides.userQuotas ?? process.env.USER_QUOTAS ?? '',
    (v) => gbToBytes(v)
  );
  if (overrides.userQuotaBytes) {
    for (const [k, v] of parsePairMap(overrides.userQuotaBytes, (x) => Math.max(0, Number(x) || 0))) {
      userQuotaMap.set(k, v);
    }
  }

  const userFolderMap = parsePairMap(
    overrides.userFolders ?? process.env.USER_FOLDERS ?? '',
    (v) => {
      const trimmed = String(v || '').trim();
      if (trimmed === '/' || trimmed.toLowerCase() === 'root' || trimmed === '.') {
        return '__ROOT__';
      }
      return sanitizeUserFolder(trimmed);
    }
  );

  return {
    port: Number(overrides.port ?? process.env.PORT ?? 3000),
    webPort: Number(overrides.webPort ?? process.env.WEB_PORT ?? 4000),
    protocol: String(overrides.protocol ?? process.env.PROTOCOL ?? 'http')
      .trim()
      .toLowerCase(),
    sslCertPath: (overrides.sslCertPath ?? process.env.SSL_CERT_PATH ?? '').trim(),
    sslKeyPath: (overrides.sslKeyPath ?? process.env.SSL_KEY_PATH ?? '').trim(),
    publicUrl: String(overrides.publicUrl ?? process.env.PUBLIC_URL ?? '')
      .trim()
      .replace(/\/+$/, ''),
    publicWebUrl: String(overrides.publicWebUrl ?? process.env.PUBLIC_WEB_URL ?? '')
      .trim()
      .replace(/\/+$/, ''),
    storageDir,
    dataDir,
    hashIndexFile: path.join(dataDir, 'hash-index.json'),
    apiKey: (overrides.apiKey ?? process.env.API_KEY ?? '').trim(),
    userKeyMap, // Map<apiKey, folderName>
    userFolderMap, // Map<lowercaseEmail, safeFolder | '__ROOT__'>
    requireAuth:
      String(overrides.requireAuth ?? process.env.REQUIRE_AUTH ?? 'false')
        .trim()
        .toLowerCase() === 'true',
    googleClientId: String(
      overrides.googleClientId ?? process.env.GOOGLE_CLIENT_ID ?? ''
    ).trim(),
    googleClientSecret: String(
      overrides.googleClientSecret ?? process.env.GOOGLE_CLIENT_SECRET ?? ''
    ).trim(),
    googleMapsApiKey: String(
      overrides.googleMapsApiKey ?? process.env.GOOGLE_MAPS_API_KEY ?? ''
    ).trim(),
    allowedGoogleDomains:
      overrides.allowedGoogleDomains instanceof Set
        ? overrides.allowedGoogleDomains
        : parseListCsv(
            overrides.allowedGoogleDomains ?? process.env.ALLOWED_GOOGLE_DOMAINS ?? ''
          ),
    allowedGoogleEmails:
      overrides.allowedGoogleEmails instanceof Set
        ? overrides.allowedGoogleEmails
        : parseListCsv(
            overrides.allowedGoogleEmails ?? process.env.ALLOWED_GOOGLE_EMAILS ?? ''
          ),
    authSessionSecret: String(
      overrides.authSessionSecret ?? process.env.AUTH_SESSION_SECRET ?? ''
    ).trim(),
    sessionTtlSeconds: Math.max(
      60,
      Number(overrides.sessionTtlSeconds ?? process.env.AUTH_SESSION_TTL_SECONDS ?? 30 * 24 * 3600) || 30 * 24 * 3600
    ),
    nodeId: String(overrides.nodeId ?? process.env.NODE_ID ?? '').trim(),
    storageNodes: parseStorageNodes(
      overrides.storageNodes ?? process.env.STORAGE_NODES ?? ''
    ),
    nodeAllocationMode: normalizeNodeAllocationMode(
      overrides.nodeAllocationMode ?? process.env.NODE_ALLOCATION_MODE ?? 'ordered'
    ),
    userNodeMap: parsePairMap(
      overrides.userNodeMap ?? process.env.USER_NODE_MAP ?? '',
      (v) => String(v).trim()
    ),
    defaultQuotaBytes,
    userQuotaMap, // Map<lowercaseIdentifier, quotaBytes>
    serverCapacityBytes: gbToBytes(
      overrides.serverCapacityGb ?? process.env.SERVER_CAPACITY_GB ?? 0
    ),
    minFreeDiskBytes: gbToBytes(
      overrides.minFreeDiskGb ?? process.env.MIN_FREE_DISK_GB ?? 0
    ),
    maxUsers: Math.max(
      0,
      Math.floor(Number(overrides.maxUsers ?? process.env.MAX_USERS ?? 0) || 0)
    ),
    adminKey: String(overrides.adminKey ?? process.env.ADMIN_KEY ?? '').trim(),
    adminEmails:
      overrides.adminEmails instanceof Set
        ? overrides.adminEmails
        : parseListCsv(overrides.adminEmails ?? process.env.ADMIN_EMAILS ?? ''),
    maxFileSizeBytes: effectiveMaxMb * 1024 * 1024,
    // Cap RAM-buffered multipart uploads (large videos stream via raw binary or chunked upload)
    maxMultipartFileBytes: Math.min(
      effectiveMaxMb * 1024 * 1024,
      Math.max(
        10,
        Number(overrides.maxMultipartMb ?? process.env.MAX_MULTIPART_MB ?? 150) || 150
      ) *
        1024 *
        1024
    ),
    // Backend abuse / DoS & brute-force rate-limiting guardrails
    rateLimit: {
      enabled:
        String(overrides.rateLimitEnabled ?? process.env.RATE_LIMIT_ENABLED ?? 'true')
          .trim()
          .toLowerCase() !== 'false',
      apiMaxPerMin: Math.max(
        30,
        Number(overrides.rateLimitApiMaxPerMin ?? process.env.RATE_LIMIT_MAX_PER_MIN ?? 1500) || 1500
      ),
      authFailMaxPer15Min: Math.max(
        3,
        Number(overrides.rateLimitAuthFailMax ?? process.env.AUTH_FAIL_MAX_PER_15M ?? 25) || 25
      ),
      shareFailMaxPer15Min: Math.max(
        3,
        Number(overrides.rateLimitShareFailMax ?? process.env.SHARE_FAIL_MAX_PER_15M ?? 15) || 15
      ),
      heavyMaxPerMin: Math.max(
        5,
        Number(overrides.rateLimitHeavyMaxPerMin ?? process.env.HEAVY_OP_MAX_PER_MIN ?? 30) || 30
      ),
    },
    // Set SCAN_STORAGE_ON_STARTUP=false if using a large remote rclone/gdrive mount to avoid slow startup scans
    scanStorageOnStartup:
      String(
        overrides.scanStorageOnStartup ??
          process.env.SCAN_STORAGE_ON_STARTUP ??
          'true'
      ).toLowerCase() !== 'false',
    // Storage mode: 'disk' (default: direct to server STORAGE_DIR) or 's3' (all originals & proxies in MEGA S4 / S3 / MinIO / R2)
    storageBackend: (() => {
      const raw = String(overrides.storageBackend ?? process.env.STORAGE_BACKEND ?? 'disk')
        .trim()
        .toLowerCase();
      if (raw === 's3' || raw === 's4' || raw === 'mega-s4' || raw === 'megas4' || raw === 'object') {
        return 's3';
      }
      return 'disk';
    })(),
    // Optional S3 / MEGA S4 / MinIO / R2 configuration (leave STORAGE_BACKEND=disk to store directly on server)
    s3: {
      endpoint: (overrides.s3Endpoint ?? process.env.S3_ENDPOINT ?? '').trim(),
      region: (overrides.s3Region ?? process.env.S3_REGION ?? 'us-east-1').trim(),
      bucket: (overrides.s3Bucket ?? process.env.S3_BUCKET ?? '').trim(),
      prefix: String(overrides.s3Prefix ?? process.env.S3_PREFIX ?? '')
        .trim()
        .replace(/^\/+|\/+$/g, ''),
      accessKeyId: (overrides.s3AccessKeyId ?? process.env.S3_ACCESS_KEY_ID ?? '').trim(),
      secretAccessKey: (overrides.s3SecretAccessKey ?? process.env.S3_SECRET_ACCESS_KEY ?? '').trim(),
      forcePathStyle:
        String(
          overrides.s3ForcePathStyle ??
            process.env.S3_FORCE_PATH_STYLE ??
            'true'
        ).toLowerCase() !== 'false',
      // Stream S3 reads through the backend (supports full Range seeking & avoids browser CORS errors on MEGA S4)
      streamProxy:
        String(
          overrides.s3StreamProxy ??
            process.env.S3_STREAM_PROXY ??
            'true'
        ).toLowerCase() !== 'false',
      multipartThresholdBytes:
        Math.max(
          5,
          Number(overrides.s3MultipartThresholdMb ?? process.env.S3_MULTIPART_THRESHOLD_MB ?? 64) || 64
        ) *
        1024 *
        1024,
      multipartPartSizeBytes:
        Math.max(
          5,
          Number(overrides.s3MultipartPartSizeMb ?? process.env.S3_MULTIPART_PART_SIZE_MB ?? 16) || 16
        ) *
        1024 *
        1024,
    },
  };
}

module.exports = { getConfig, resolvePath, parseUserKeys, sanitizeUserFolder, normalizeNodeUrl, gbToBytes };
