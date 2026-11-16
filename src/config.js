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

  return {
    port: Number(overrides.port ?? process.env.PORT ?? 3000),
    protocol: String(overrides.protocol ?? process.env.PROTOCOL ?? 'http')
      .trim()
      .toLowerCase(),
    sslCertPath: (overrides.sslCertPath ?? process.env.SSL_CERT_PATH ?? '').trim(),
    sslKeyPath: (overrides.sslKeyPath ?? process.env.SSL_KEY_PATH ?? '').trim(),
    storageDir,
    dataDir,
    hashIndexFile: path.join(dataDir, 'hash-index.json'),
    apiKey: (overrides.apiKey ?? process.env.API_KEY ?? '').trim(),
    userKeyMap, // Map<apiKey, folderName>
    maxFileSizeBytes:
      Number(overrides.maxFileSizeMb ?? process.env.MAX_FILE_SIZE_MB ?? 50000) *
      1024 *
      1024,
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

module.exports = { getConfig, resolvePath, parseUserKeys };
