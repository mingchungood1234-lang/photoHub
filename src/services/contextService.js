/**
 * USER CONTEXT & PER-FOLDER ISOLATION SERVICE
 *
 * Where this belongs: `src/services/contextService.js` (Business-logic Service Layer).
 * Created once in `src/app.js` at startup and passed into `authMiddleware`, `healthController`,
 * `authController`, `accountController`, and `uploadController`.
 * Uses: `models/hashIndexModel.js` (one `HashIndex` instance per user folder) & `models/userModel.js` (`resolveQuotaBytes`).
 * Why it exists: Keeps each user's photos (`STORAGE_DIR/<folderName>`) and hash index JSON file
 * (`DATA_DIR/hash-index-<folder>.json`) completely separated even when multiple people share one server.
 */

const fsp = require('fs/promises');
const path = require('path');
const { HashIndex } = require('../models/hashIndexModel');
const {
  resolveQuotaBytes,
  resolveConfiguredUserFolder,
} = require('../models/userModel');

function formatBytesShort(bytes) {
  const num = Number(bytes) || 0;
  if (num >= 1000 ** 4) return `${(num / 1000 ** 4).toFixed(2)} TB`;
  if (num >= 1000 ** 3) return `${(num / 1000 ** 3).toFixed(2)} GB`;
  if (num >= 1000 ** 2) return `${(num / 1000 ** 2).toFixed(1)} MB`;
  if (num >= 1000) return `${(num / 1000).toFixed(1)} KB`;
  return `${num} B`;
}

/**
 * Coordinates per-user storage folders, HashIndex instances, base URL resolution,
 * capacity limits for new user signups, and per-user storage reporting.
 */
function createContextService(config, { userDirectory = null } = {}) {
  const folderContexts = new Map(); // folderName -> { folderName, storageDir, hashIndex }
  const pendingFolderInits = new Map();

  function isOpenLocalRootMode() {
    return (
      config.userKeyMap.size === 0 &&
      !config.googleClientId &&
      !config.requireAuth
    );
  }

  function isRootFolderEnabled() {
    if (config.apiKey) return true;
    if (isOpenLocalRootMode()) return true;
    if (Array.from(config.userFolderMap.values()).includes('__ROOT__')) {
      return true;
    }
    if (
      userDirectory &&
      userDirectory.listAll().some((u) => !u.folderName || u.folderName === '__ROOT__')
    ) {
      return true;
    }
    return false;
  }

  // Root (`defaultHashIndex`) points at `config.storageDir`, which is also the parent directory
  // holding per-user folders (`USER_KEYS`, `USER_FOLDERS`, `google_*`). Exclude every per-user
  // folder from root scans/index loads so multi-user folders never get counted as root photos.
  function shouldExcludeFromDefaultRoot(relPath) {
    const normalized = String(relPath || '')
      .replace(/\\/g, '/')
      .replace(/^\/+/, '');
    if (!normalized) return false;
    const topSegment = normalized.split('/')[0];
    if (!topSegment) return false;

    if (!isOpenLocalRootMode() && topSegment.startsWith('google_')) {
      return true;
    }
    for (const folderName of config.userKeyMap.values()) {
      if (folderName && folderName !== '__ROOT__' && folderName === topSegment) {
        return true;
      }
    }
    for (const folderName of config.userFolderMap.values()) {
      if (folderName && folderName !== '__ROOT__' && folderName === topSegment) {
        return true;
      }
    }
    if (folderContexts.has(topSegment)) return true;
    if (userDirectory) {
      for (const user of userDirectory.listAll()) {
        if (
          user &&
          user.folderName &&
          user.folderName !== '__ROOT__' &&
          user.folderName === topSegment
        ) {
          return true;
        }
      }
    }
    return false;
  }

  const defaultHashIndex = new HashIndex({
    storageDir: config.storageDir,
    hashIndexFile: config.hashIndexFile,
    scanStorageOnStartup: Boolean(
      config.scanStorageOnStartup && isRootFolderEnabled()
    ),
    shouldExcludePath: (relPath) => shouldExcludeFromDefaultRoot(relPath),
  });

  let defaultIndexPromise = null;
  async function ensureDefaultHashIndexReady() {
    if (!defaultIndexPromise) {
      defaultIndexPromise = defaultHashIndex.init();
    }
    return defaultIndexPromise;
  }

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
    if (isRootFolderEnabled()) {
      await ensureDefaultHashIndexReady();
    }
    for (const folderName of new Set(config.userKeyMap.values())) {
      await getOrCreateFolderContext(folderName);
    }
  }

  function resolveEffectiveLocalNodeId(explicitLocalNodeId = null, publicBaseUrl = '') {
    if (explicitLocalNodeId) return explicitLocalNodeId;
    if (config.nodeId) return config.nodeId;
    const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];
    const urls = [config.publicUrl, publicBaseUrl].filter(Boolean);
    for (const node of nodes) {
      for (const candidateUrl of urls) {
        try {
          const u1 = new URL(node.url);
          const u2 = new URL(candidateUrl);
          const p1 = u1.port || (u1.protocol === 'https:' ? '443' : '80');
          const p2 = u2.port || (u2.protocol === 'https:' ? '443' : '80');
          if (
            u1.protocol === u2.protocol &&
            u1.hostname.toLowerCase() === u2.hostname.toLowerCase() &&
            p1 === p2
          ) {
            return node.id;
          }
        } catch {
          // ignore invalid URL formats
        }
      }
    }
    return null;
  }

  function userBelongsToLocalNode(user, localNodeId) {
    if (!user) return false;
    const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];
    if (nodes.length === 0) return true;
    if (!user.nodeId || user.nodeId === 'primary') return true;
    return Boolean(localNodeId && user.nodeId === localNodeId);
  }

  async function discoverExistingGoogleDiskFolders() {
    // Only discover unindexed google_* folders on pure federated worker nodes (no local Google OAuth or USER_KEYS);
    // gateways track active Google accounts strictly in users.json.
    if (config.googleClientId || config.userKeyMap.size > 0) return;
    let entries;
    try {
      entries = await fsp.readdir(config.storageDir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.isDirectory() && entry.name.startsWith('google_')) {
        await getOrCreateFolderContext(entry.name);
      }
    }
  }

  async function ensureKnownUserContextsReady(localNodeId = null, publicBaseUrl = '') {
    const effectiveNodeId = resolveEffectiveLocalNodeId(localNodeId, publicBaseUrl);
    if (isRootFolderEnabled()) {
      await ensureDefaultHashIndexReady();
    }
    await discoverExistingGoogleDiskFolders();
    if (!userDirectory) return;
    for (const user of userDirectory.listAll()) {
      if (
        user &&
        userBelongsToLocalNode(user, effectiveNodeId) &&
        user.folderName &&
        user.folderName !== '__ROOT__'
      ) {
        await getOrCreateFolderContext(user.folderName);
      }
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
    if (userDirectory && userCtx) {
      const record =
        (userCtx.sub && userDirectory.getBySub(userCtx.sub)) ||
        (userCtx.email && userDirectory.getByEmail(userCtx.email));
      if (record && record.quotaBytesOverride !== undefined && record.quotaBytesOverride !== null) {
        return Math.max(0, Number(record.quotaBytesOverride) || 0);
      }
    }
    return resolveQuotaBytes(
      {
        email: userCtx && userCtx.email,
        folderName: userCtx && userCtx.folderName,
        apiKey: userCtx && userCtx.apiKey,
      },
      config
    );
  }

  async function getDiskSpaceInfo(targetDir = config.storageDir) {
    let diskTotalBytes = null;
    let diskFreeBytes = null;
    try {
      if (typeof fsp.statfs === 'function') {
        await fsp.mkdir(targetDir, { recursive: true });
        const fsStats = await fsp.statfs(targetDir);
        const blockSize = Number(fsStats.bsize) || 4096;
        diskTotalBytes = (Number(fsStats.blocks) || 0) * blockSize;
        diskFreeBytes = (Number(fsStats.bavail) || 0) * blockSize;
      }
    } catch {
      // Ignore statfs errors on unsupported filesystems/mounts
    }
    return { diskTotalBytes, diskFreeBytes };
  }

  async function assertDiskFreeForUpload(incomingBytes = 0) {
    const minFree = Number(config.minFreeDiskBytes) || 0;
    if (minFree <= 0) return;
    const { diskFreeBytes } = await getDiskSpaceInfo(config.storageDir);
    if (diskFreeBytes !== null && diskFreeBytes - (Number(incomingBytes) || 0) < minFree) {
      const err = new Error(
        `Server disk free space is below the safety reserve (${formatBytesShort(diskFreeBytes)} free, minimum ${formatBytesShort(minFree)}).`
      );
      err.statusCode = 507;
      throw err;
    }
  }

  async function buildStorageSummary(userCtx) {
    const usage = userCtx.hashIndex.getStorageUsage();
    const quotaBytes = getQuotaBytesForContext(userCtx);
    const { diskTotalBytes, diskFreeBytes } = await getDiskSpaceInfo(userCtx.storageDir);
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

  async function getServerCapacitySummary({ localNodeId = null, publicBaseUrl = '' } = {}) {
    const effectiveNodeId = resolveEffectiveLocalNodeId(localNodeId, publicBaseUrl);
    await ensureKnownUserContextsReady(effectiveNodeId, publicBaseUrl);
    const { diskTotalBytes, diskFreeBytes } = await getDiskSpaceInfo(config.storageDir);

    const folderUsageMap = new Map(); // folderKey -> usage stats (dedupes physical space)
    const getUsageForFolder = (folderName) => {
      const key = folderName || '__ROOT__';
      if (folderUsageMap.has(key)) return folderUsageMap.get(key);
      const idx =
        !folderName || folderName === '__ROOT__'
          ? defaultHashIndex
          : (folderContexts.get(folderName) && folderContexts.get(folderName).hashIndex) || null;
      const usage = idx
        ? idx.getStorageUsage()
        : { itemCount: 0, mastersBytes: 0, proxiesBytes: 0, usedBytes: 0 };
      const entry = { folderKey: key, ...usage };
      folderUsageMap.set(key, entry);
      return entry;
    };

    const userRows = [];
    const seenFolderKeys = new Set();
    let localGoogleUserCount = 0;

    if (userDirectory) {
      for (const user of userDirectory.listAll()) {
        if (!userBelongsToLocalNode(user, effectiveNodeId)) continue;
        localGoogleUserCount += 1;
        const folderName = user.folderName && user.folderName !== '__ROOT__' ? user.folderName : null;
        const folderKey = folderName || '__ROOT__';
        seenFolderKeys.add(folderKey);
        const usage = getUsageForFolder(folderName);
        const quotaBytes = getQuotaBytesForContext({
          sub: user.sub,
          email: user.email,
          folderName,
        });
        userRows.push({
          id: user.sub,
          authType: 'google',
          displayName: user.name || user.email || folderName || 'Google User',
          email: user.email || null,
          folderName: folderName || '/',
          folderKey,
          nodeId: user.nodeId || effectiveNodeId || 'primary',
          itemCount: usage.itemCount,
          mastersBytes: usage.mastersBytes,
          proxiesBytes: usage.proxiesBytes,
          usedBytes: usage.usedBytes,
          quotaBytes: quotaBytes > 0 ? quotaBytes : null,
          usagePercent:
            quotaBytes > 0 ? Math.min(100, Math.round((usage.usedBytes / quotaBytes) * 1000) / 10) : null,
          createdAt: user.createdAt || null,
          lastLoginAt: user.lastLoginAt || null,
        });
      }
    }

    const folderByKeyKeys = new Map();
    for (const [apiKey, folderName] of config.userKeyMap.entries()) {
      const maskedKey = apiKey.length > 6 ? `${apiKey.slice(0, 3)}…${apiKey.slice(-2)}` : folderName;
      if (!folderByKeyKeys.has(folderName)) {
        folderByKeyKeys.set(folderName, { apiKey, maskedKey });
      }
    }

    for (const [folderName, keyInfo] of folderByKeyKeys.entries()) {
      if (seenFolderKeys.has(folderName)) continue;
      seenFolderKeys.add(folderName);
      const usage = getUsageForFolder(folderName);
      const quotaBytes = getQuotaBytesForContext({
        folderName,
        apiKey: keyInfo.apiKey,
      });
      userRows.push({
        id: `key:${folderName}`,
        authType: 'api_key',
        displayName: folderName,
        email: null,
        folderName,
        folderKey: folderName,
        nodeId: 'primary',
        itemCount: usage.itemCount,
        mastersBytes: usage.mastersBytes,
        proxiesBytes: usage.proxiesBytes,
        usedBytes: usage.usedBytes,
        quotaBytes: quotaBytes > 0 ? quotaBytes : null,
        usagePercent:
          quotaBytes > 0 ? Math.min(100, Math.round((usage.usedBytes / quotaBytes) * 1000) / 10) : null,
        createdAt: null,
        lastLoginAt: null,
      });
    }

    // Also include disk folders created on worker storage nodes (`node2`, etc.) where users.json lives on Gateway
    for (const [folderName] of folderContexts.entries()) {
      if (seenFolderKeys.has(folderName)) continue;
      seenFolderKeys.add(folderName);
      const usage = getUsageForFolder(folderName);
      const quotaBytes = getQuotaBytesForContext({ folderName });
      userRows.push({
        id: `folder:${folderName}`,
        authType: 'federated',
        displayName: folderName,
        email: null,
        folderName,
        folderKey: folderName,
        nodeId: effectiveNodeId || 'primary',
        itemCount: usage.itemCount,
        mastersBytes: usage.mastersBytes,
        proxiesBytes: usage.proxiesBytes,
        usedBytes: usage.usedBytes,
        quotaBytes: quotaBytes > 0 ? quotaBytes : null,
        usagePercent:
          quotaBytes > 0 ? Math.min(100, Math.round((usage.usedBytes / quotaBytes) * 1000) / 10) : null,
        createdAt: null,
        lastLoginAt: null,
      });
    }

    if (!seenFolderKeys.has('__ROOT__') && isRootFolderEnabled()) {
      const rootUsage = getUsageForFolder(null);
      if (rootUsage.itemCount > 0 || config.apiKey || isOpenLocalRootMode()) {
        const quotaBytes = getQuotaBytesForContext({ apiKey: config.apiKey || undefined });
        userRows.push({
          id: 'root',
          authType: 'root',
          displayName: config.apiKey ? 'Shared API Key (Root)' : 'Default Root Folder',
          email: null,
          folderName: '/',
          folderKey: '__ROOT__',
          nodeId: 'primary',
          itemCount: rootUsage.itemCount,
          mastersBytes: rootUsage.mastersBytes,
          proxiesBytes: rootUsage.proxiesBytes,
          usedBytes: rootUsage.usedBytes,
          quotaBytes: quotaBytes > 0 ? quotaBytes : null,
          usagePercent:
            quotaBytes > 0 ? Math.min(100, Math.round((rootUsage.usedBytes / quotaBytes) * 1000) / 10) : null,
          createdAt: null,
          lastLoginAt: null,
        });
      }
    }

    let totalUsedBytes = 0;
    let totalMastersBytes = 0;
    let totalProxiesBytes = 0;
    let totalItems = 0;
    for (const usage of folderUsageMap.values()) {
      totalUsedBytes += usage.usedBytes;
      totalMastersBytes += usage.mastersBytes;
      totalProxiesBytes += usage.proxiesBytes;
      totalItems += usage.itemCount;
    }

    // Deduplicate allocated quotas by folderKey too so users sharing a folder don't double-count
    const quotaByFolder = new Map();
    for (const row of userRows) {
      const prev = quotaByFolder.get(row.folderKey) || 0;
      if ((row.quotaBytes || 0) > prev) {
        quotaByFolder.set(row.folderKey, row.quotaBytes || 0);
      }
    }
    let totalAllocatedQuotaBytes = 0;
    for (const q of quotaByFolder.values()) totalAllocatedQuotaBytes += q;

    const registeredUserCount = Math.max(localGoogleUserCount, userRows.length);

    const serverCap = Number(config.serverCapacityBytes) || 0;
    const minFree = Number(config.minFreeDiskBytes) || 0;
    const maxUsers = Number(config.maxUsers) || 0;
    const incomingDefaultQuota = Number(config.defaultQuotaBytes) || 0;

    let newSignupBlockReason = null;
    if (maxUsers > 0 && registeredUserCount >= maxUsers) {
      newSignupBlockReason = `Server user limit reached (${registeredUserCount}/${maxUsers} accounts). New sign-ins are closed.`;
    } else if (minFree > 0 && diskFreeBytes !== null && diskFreeBytes < minFree) {
      newSignupBlockReason = `Server disk is almost full (${formatBytesShort(diskFreeBytes)} free remaining). New sign-ins are paused.`;
    } else if (serverCap > 0) {
      if (totalUsedBytes >= serverCap) {
        newSignupBlockReason = `Server assigned storage is full (${formatBytesShort(totalUsedBytes)} / ${formatBytesShort(serverCap)} used). New sign-ins are closed.`;
      } else if (
        incomingDefaultQuota > 0 &&
        totalAllocatedQuotaBytes + incomingDefaultQuota > serverCap
      ) {
        newSignupBlockReason = `Server assigned storage quota pool is full (${formatBytesShort(totalAllocatedQuotaBytes)} / ${formatBytesShort(serverCap)} allocated). New sign-ins are closed.`;
      }
    }

    userRows.sort((a, b) => b.usedBytes - a.usedBytes || b.itemCount - a.itemCount);

    return {
      diskTotalBytes,
      diskFreeBytes,
      serverCapacityBytes: serverCap > 0 ? serverCap : null,
      minFreeDiskBytes: minFree > 0 ? minFree : null,
      maxUsers: maxUsers > 0 ? maxUsers : null,
      defaultQuotaBytes: incomingDefaultQuota > 0 ? incomingDefaultQuota : null,
      totalUsedBytes,
      totalMastersBytes,
      totalProxiesBytes,
      totalItems,
      totalAllocatedQuotaBytes,
      registeredUserCount,
      isFullForNewUsers: Boolean(newSignupBlockReason),
      newSignupBlockReason,
      users: userRows,
    };
  }

  /**
   * Checks whether a Google account should be allowed to sign in right now.
   * Existing accounts (or emails explicitly mapped via USER_FOLDERS) are ALWAYS permitted
   * so users never lose access to view/restore photos even when storage is full.
   * Brand-new users are blocked when server assigned storage/user capacity is exhausted.
   */
  async function checkNewUserSignupCapacity({ sub, email, localNodeId = null, publicBaseUrl = '' }) {
    const cleanEmail = String(email || '').trim().toLowerCase();
    const isExistingUser = Boolean(
      (userDirectory && sub && userDirectory.getBySub(sub)) ||
        (userDirectory && cleanEmail && userDirectory.getByEmail(cleanEmail)) ||
        resolveConfiguredUserFolder(cleanEmail, config).matched
    );
    if (isExistingUser) {
      return { allowed: true, isExistingUser: true, reason: null };
    }

    const capacity = await getServerCapacitySummary({ localNodeId, publicBaseUrl });
    if (capacity.isFullForNewUsers) {
      return {
        allowed: false,
        isExistingUser: false,
        reason: capacity.newSignupBlockReason,
        capacity,
      };
    }
    return { allowed: true, isExistingUser: false, reason: null, capacity };
  }

  async function rescanFolders(targetFolderKey = null) {
    await ensureKnownUserContextsReady();
    const rescanned = [];
    const shouldScanRoot =
      targetFolderKey === '__ROOT__' ||
      targetFolderKey === '/' ||
      (!targetFolderKey && isRootFolderEnabled());
    if (shouldScanRoot) {
      await ensureDefaultHashIndexReady();
      await defaultHashIndex.syncStorageDir();
      rescanned.push('/');
    }
    for (const [folderName, ctx] of folderContexts.entries()) {
      if (!targetFolderKey || targetFolderKey === folderName) {
        await ctx.hashIndex.syncStorageDir();
        rescanned.push(folderName);
      }
    }
    return rescanned;
  }

  async function flushAllIndexes() {
    await defaultHashIndex.flush().catch(() => {});
    for (const ctx of folderContexts.values()) {
      await ctx.hashIndex.flush().catch(() => {});
    }
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
    getServerCapacitySummary,
    checkNewUserSignupCapacity,
    assertDiskFreeForUpload,
    rescanFolders,
    flushAllIndexes,
  };
}

module.exports = { createContextService };
