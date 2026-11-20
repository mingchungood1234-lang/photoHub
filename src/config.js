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
 * Parses STORAGE_NODES="node1=https://s1.example.com,node2=https://s2.example.com"
 * into [{ id, url }].
 */
function parseStorageNodes(rawNodes) {
  if (Array.isArray(rawNodes)) {
    return rawNodes
      .map((item) => ({
        id: String(item.id || '').trim(),
        url: String(item.url || '').trim().replace(/\/+$/, ''),
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
    const url = (eqIdx !== -1 ? trimmed.slice(eqIdx + 1) : trimmed).trim().replace(/\/+$/, '');
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

function gbToBytes(rawGb) {
  const num = Number(rawGb);
  if (!Number.isFinite(num) || num <= 0) return 0;
  // Use SI base-10 GB (1000^3) to match iOS ByteCountFormatter (.file), so 5000 GB displays as 5 TB
  return Math.round(num * 1000 * 1000 * 1000);
}

function getConfig(overrides = {}) {
  const rootDir = path.resolve(__dirname, '..');
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
    protocol: String(overrides.protocol ?? process.env.PROTOCOL ?? 'http')
      .trim()
      .toLowerCase(),
    sslCertPath: (overrides.sslCertPath ?? process.env.SSL_CERT_PATH ?? '').trim(),
    sslKeyPath: (overrides.sslKeyPath ?? process.env.SSL_KEY_PATH ?? '').trim(),
    publicUrl: String(overrides.publicUrl ?? process.env.PUBLIC_URL ?? '')
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
    storageNodes: parseStorageNodes(
      overrides.storageNodes ?? process.env.STORAGE_NODES ?? ''
    ),
    userNodeMap: parsePairMap(
      overrides.userNodeMap ?? process.env.USER_NODE_MAP ?? '',
      (v) => String(v).trim()
    ),
    defaultQuotaBytes,
    userQuotaMap, // Map<lowercaseIdentifier, quotaBytes>
    maxFileSizeBytes: effectiveMaxMb * 1024 * 1024,
    // Set SCAN_STORAGE_ON_STARTUP=false if using a large remote rclone/gdrive mount to avoid slow startup scans
    scanStorageOnStartup:
      String(
        overrides.scanStorageOnStartup ??
          process.env.SCAN_STORAGE_ON_STARTUP ??
          'true'
      ).toLowerCase() !== 'false',
    // Optional S3 / MinIO configuration for pre-signed URL uploads
    s3: {
      endpoint: (overrides.s3Endpoint ?? process.env.S3_ENDPOINT ?? '').trim(),
      region: (overrides.s3Region ?? process.env.S3_REGION ?? 'us-east-1').trim(),
      bucket: (overrides.s3Bucket ?? process.env.S3_BUCKET ?? '').trim(),
      accessKeyId: (overrides.s3AccessKeyId ?? process.env.S3_ACCESS_KEY_ID ?? '').trim(),
      secretAccessKey: (overrides.s3SecretAccessKey ?? process.env.S3_SECRET_ACCESS_KEY ?? '').trim(),
      forcePathStyle:
        String(
          overrides.s3ForcePathStyle ??
            process.env.S3_FORCE_PATH_STYLE ??
            'true'
        ).toLowerCase() !== 'false',
    },
  };
}

module.exports = { getConfig, resolvePath, parseUserKeys, sanitizeUserFolder };
