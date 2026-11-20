const fsp = require('fs/promises');
const path = require('path');
const { HashIndex } = require('../models/hashIndexModel');
const { resolveQuotaBytes } = require('../models/userModel');

/**
 * Coordinates per-user storage folders, HashIndex instances, base URL resolution,
 * and quota/filesystem capacity calculations across single-user, USER_KEYS, and Google logins.
 */
function createContextService(config) {
  const defaultHashIndex = new HashIndex({
    storageDir: config.storageDir,
    hashIndexFile: config.hashIndexFile,
    scanStorageOnStartup:
      config.userKeyMap.size === 0 ? config.scanStorageOnStartup : false,
  });

  let defaultIndexPromise = null;
  async function ensureDefaultHashIndexReady() {
    if (!defaultIndexPromise) {
      defaultIndexPromise = defaultHashIndex.init();
    }
    return defaultIndexPromise;
  }

  const folderContexts = new Map(); // folderName -> { folderName, storageDir, hashIndex }
  const pendingFolderInits = new Map();

  async function getOrCreateFolderContext(folderName) {
    if (folderContexts.has(folderName)) {
      return folderContexts.get(folderName);
    }
    if (pendingFolderInits.has(folderName)) {
      return pendingFolderInits.get(folderName);
    }
    const initPromise = (async () => {
      const userStorageDir = path.join(config.storageDir, folderName);
      const fileSlug = folderName.replace(/[^a-zA-Z0-9_-]/g, '_');
      const userHashIndexFile = path.join(
        config.dataDir,
        `hash-index-${fileSlug}.json`
      );
      const userHashIndex = new HashIndex({
        storageDir: userStorageDir,
        hashIndexFile: userHashIndexFile,
        scanStorageOnStartup: config.scanStorageOnStartup,
      });
      await userHashIndex.init();
      const ctx = {
        folderName,
        storageDir: userStorageDir,
        hashIndex: userHashIndex,
      };
      folderContexts.set(folderName, ctx);
      pendingFolderInits.delete(folderName);
      return ctx;
    })();
    pendingFolderInits.set(folderName, initPromise);
    return initPromise;
  }

  async function init() {
    if (
      config.userKeyMap.size === 0 ||
      config.apiKey ||
      Array.from(config.userFolderMap.values()).includes('__ROOT__')
    ) {
      await ensureDefaultHashIndexReady();
    }
    for (const folderName of new Set(config.userKeyMap.values())) {
      await getOrCreateFolderContext(folderName);
    }
  }

  function getTotalIndexedCount() {
    let total = defaultHashIndex.size();
    for (const ctx of folderContexts.values()) {
      total += ctx.hashIndex.size();
    }
    return total;
  }

  function resolveRequestBaseUrl(req) {
    if (config.publicUrl) return config.publicUrl;
    const proto = String(req.headers['x-forwarded-proto'] || req.protocol || 'http')
      .split(',')[0]
      .trim();
    const host = String(
      req.headers['x-forwarded-host'] || req.get('host') || `localhost:${config.port}`
    )
      .split(',')[0]
      .trim();
    return `${proto}://${host}`;
  }

  function getQuotaBytesForContext(userCtx) {
    return resolveQuotaBytes(
      {
        email: userCtx && userCtx.email,
        folderName: userCtx && userCtx.folderName,
        apiKey: userCtx && userCtx.apiKey,
      },
      config
    );
  }

  async function buildStorageSummary(userCtx) {
    const usage = userCtx.hashIndex.getStorageUsage();
    const quotaBytes = getQuotaBytesForContext(userCtx);
    let diskTotalBytes = null;
    let diskFreeBytes = null;
    try {
      if (typeof fsp.statfs === 'function') {
        await fsp.mkdir(userCtx.storageDir, { recursive: true });
        const fsStats = await fsp.statfs(userCtx.storageDir);
        const blockSize = Number(fsStats.bsize) || 4096;
        diskTotalBytes = (Number(fsStats.blocks) || 0) * blockSize;
        diskFreeBytes = (Number(fsStats.bavail) || 0) * blockSize;
      }
    } catch {
      // Ignore statfs errors on unsupported filesystems/mounts
    }
    const remainingBytes =
      quotaBytes > 0 ? Math.max(0, quotaBytes - usage.usedBytes) : diskFreeBytes;
    return {
      usedBytes: usage.usedBytes,
      mastersBytes: usage.mastersBytes,
      proxiesBytes: usage.proxiesBytes,
      itemCount: usage.itemCount,
      quotaBytes: quotaBytes > 0 ? quotaBytes : null,
      remainingBytes,
      diskTotalBytes,
      diskFreeBytes,
    };
  }

  return {
    defaultHashIndex,
    folderContexts,
    init,
    ensureDefaultHashIndexReady,
    getOrCreateFolderContext,
    getTotalIndexedCount,
    resolveRequestBaseUrl,
    getQuotaBytesForContext,
    buildStorageSummary,
  };
}

module.exports = { createContextService };
