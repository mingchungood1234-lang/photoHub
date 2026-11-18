const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');

function computeBufferSha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

async function computeFileSha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

class HashIndex {
  constructor({ storageDir, hashIndexFile, scanStorageOnStartup = true }) {
    this.storageDir = storageDir;
    this.hashIndexFile = hashIndexFile;
    this.scanStorageOnStartup = scanStorageOnStartup;
    this.records = new Map(); // sha256 -> { hash, relativePath, originalName, size, photoDate, uploadedAt, proxyHash? }
    this.proxyToMaster = new Map(); // proxySha256 -> masterSha256
    this.writePromise = Promise.resolve();
    this.syncPromise = null;
  }

  async init() {
    try {
      await fsp.mkdir(this.storageDir, { recursive: true });
    } catch (err) {
      console.warn(`Warning: could not mkdir storageDir (${this.storageDir}):`, err.message);
    }

    try {
      await fsp.mkdir(path.dirname(this.hashIndexFile), { recursive: true });
    } catch (err) {
      console.warn(`Warning: could not mkdir dataDir (${path.dirname(this.hashIndexFile)}):`, err.message);
    }

    try {
      const raw = await fsp.readFile(this.hashIndexFile, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') {
        for (const [hash, entry] of Object.entries(parsed)) {
          if (entry && entry.relativePath) {
            const normalizedHash = hash.toLowerCase();
            this.records.set(normalizedHash, entry);
            if (entry.proxyHash && typeof entry.proxyHash === 'string') {
              this.proxyToMaster.set(entry.proxyHash.toLowerCase(), normalizedHash);
            }
          }
        }
      }
    } catch (err) {
      if (err.code !== 'ENOENT') {
        console.warn('Warning: could not read hash index file, starting fresh:', err.message);
      }
    }

    if (this.scanStorageOnStartup) {
      // Run storage scan asynchronously in the background so server startup & Docker healthcheck never block
      this.syncStorageDir().catch((err) => {
        console.warn('Warning: could not complete startup storage scan:', err.message);
      });
    }
  }

  /**
   * Scans the storage directory on startup so any files already on disk are indexed,
   * and removes stale index entries whose files were deleted manually.
   */
  async syncStorageDir() {
    if (this.syncPromise) {
      return this.syncPromise;
    }

    this.syncPromise = (async () => {
      let changed = false;
      const indexedPaths = new Set();

      for (const [hash, entry] of this.records.entries()) {
        if (entry && entry.storageType === 's3') {
          if (entry.relativePath) {
            indexedPaths.add(path.normalize(entry.relativePath));
          }
          continue;
        }
        const fullPath = path.join(this.storageDir, entry.relativePath);
        try {
          const stat = await fsp.stat(fullPath);
          if (!stat.isFile() || (entry.size && stat.size !== entry.size)) {
            this.records.delete(hash);
            changed = true;
          } else {
            indexedPaths.add(path.normalize(entry.relativePath));
          }
        } catch {
          this.records.delete(hash);
          changed = true;
        }
      }

      const walk = async (dir) => {
        const entries = await fsp.readdir(dir, { withFileTypes: true });
        for (const d of entries) {
          if (d.name.startsWith('.')) continue;
          const fullPath = path.join(dir, d.name);
          if (d.isDirectory()) {
            await walk(fullPath);
          } else if (d.isFile() && !d.name.endsWith('.tmp')) {
            const relPath = path.normalize(path.relative(this.storageDir, fullPath));
            if (!indexedPaths.has(relPath)) {
              const stat = await fsp.stat(fullPath);
              const hash = await computeFileSha256(fullPath);
              this.records.set(hash, {
                hash,
                relativePath: relPath.split(path.sep).join('/'),
                originalName: d.name,
                size: stat.size,
                mtimeMs: stat.mtimeMs,
                photoDate: stat.mtime.toISOString().slice(0, 10),
                uploadedAt: (stat.birthtime || stat.mtime).toISOString(),
              });
              indexedPaths.add(relPath);
              changed = true;
            }
          }
        }
      };

      await walk(this.storageDir);
      if (changed) {
        await this.persist();
      }
    })();

    try {
      await this.syncPromise;
    } finally {
      this.syncPromise = null;
    }
  }

  /**
   * Checks if a hash exists in the index AND verifies that the file still physically exists on disk.
   * Pass `allowStatFastPath: true` for already-verified routes like proxy registration or streaming reads
   * so large video files aren't re-hashed when byte size and mtimeMs match cleanly.
   */
  async verifyExisting(rawHash, { allowStatFastPath = false } = {}) {
    if (!rawHash || typeof rawHash !== 'string') return null;
    const hash = rawHash.trim().toLowerCase();
    const record = this.records.get(hash);
    if (!record) return null;

    if (record.storageType === 's3') {
      return record;
    }

    const fullPath = path.join(this.storageDir, record.relativePath);
    try {
      const stat = await fsp.stat(fullPath);
      if (!stat.isFile() || stat.size !== record.size) {
        this.records.delete(hash);
        await this.persist();
        return null;
      }
      if (
        allowStatFastPath &&
        typeof record.mtimeMs === 'number' &&
        stat.mtimeMs === record.mtimeMs
      ) {
        return record;
      }
      const diskHash = await computeFileSha256(fullPath);
      const expectedDiskHash = record.diskHash || hash;
      if (diskHash !== expectedDiskHash) {
        this.records.delete(hash);
        await this.persist();
        return null;
      }
      record.mtimeMs = stat.mtimeMs;
      return record;
    } catch {
      this.records.delete(hash);
      await this.persist();
      return null;
    }
  }

  /**
   * Resolves a hash as either a verified master photo, a known compressed proxy, or missing.
   */
  async lookup(rawHash, options = {}) {
    if (!rawHash || typeof rawHash !== 'string') {
      return { status: 'missing', record: null, masterHash: null };
    }
    const normalized = rawHash.trim().toLowerCase();

    const masterRecord = await this.verifyExisting(normalized, options);
    if (masterRecord) {
      return {
        status: 'master',
        record: masterRecord,
        masterHash: masterRecord.diskHash || masterRecord.hash || normalized,
      };
    }

    const mappedMasterHash = this.proxyToMaster.get(normalized);
    if (mappedMasterHash) {
      const verifiedMaster = await this.verifyExisting(mappedMasterHash, options);
      if (verifiedMaster) {
        return {
          status: 'proxy',
          record: verifiedMaster,
          masterHash: verifiedMaster.diskHash || verifiedMaster.hash || mappedMasterHash,
        };
      }
      this.proxyToMaster.delete(normalized);
    }

    return { status: 'missing', record: null, masterHash: null };
  }

  async registerProxy(masterHash, proxyHash, assetId = '', proxyMeta = {}) {
    const normMaster = String(masterHash || '').trim().toLowerCase();
    const normProxy = String(proxyHash || '').trim().toLowerCase();
    if (!normMaster || !normProxy) {
      throw new Error('masterHash and proxyHash are required');
    }

    const record = await this.verifyExisting(normMaster, { allowStatFastPath: true });
    if (!record) {
      return null;
    }

    if (record.proxyHash && record.proxyHash !== normProxy) {
      this.proxyToMaster.delete(record.proxyHash.toLowerCase());
    }

    record.proxyHash = normProxy;
    if (assetId) {
      record.assetId = String(assetId);
    }
    if (proxyMeta.proxyRelativePath) {
      record.proxyRelativePath = proxyMeta.proxyRelativePath;
    }
    if (proxyMeta.proxySize) {
      record.proxySize = Number(proxyMeta.proxySize);
    }
    if (proxyMeta.videoProxyRelativePath) {
      record.videoProxyRelativePath = proxyMeta.videoProxyRelativePath;
    }
    if (proxyMeta.videoProxySize) {
      record.videoProxySize = Number(proxyMeta.videoProxySize);
    }
    record.proxyRegisteredAt = new Date().toISOString();

    this.records.set(normMaster, record);
    this.proxyToMaster.set(normProxy, normMaster);
    await this.persist();
    return record;
  }

  async set(hash, record) {
    const normalized = hash.trim().toLowerCase();
    this.records.set(normalized, {
      ...record,
      // Keep the real on-disk hash so alias keys (e.g. pre-transcode HEIC hash) still verify
      diskHash: record.diskHash || record.hash || normalized,
      hash: normalized,
    });
    await this.persist();
    return this.records.get(normalized);
  }

  size() {
    return this.records.size;
  }

  formatMasterSummary(entry, fallbackHash = '') {
    const canonicalHash = (entry.diskHash || entry.hash || fallbackHash).toLowerCase();
    return {
      hash: canonicalHash,
      originalName: entry.originalName,
      size: entry.size || 0,
      photoDate: entry.photoDate || '',
      uploadedAt: entry.uploadedAt || '',
      savedPath: entry.relativePath,
      hasProxy: Boolean(entry.proxyHash || entry.proxyRelativePath),
      hasPreview: Boolean(entry.proxyRelativePath),
      proxyHash: entry.proxyHash || null,
      proxySize: entry.proxySize || null,
      hasVideoProxy: Boolean(entry.videoProxyRelativePath),
      videoProxySize: entry.videoProxySize || null,
    };
  }

  /**
   * Returns a deduplicated list of backed-up master photo records, sorted newest first.
   */
  listMasters() {
    const seenPaths = new Set();
    const items = [];
    for (const [key, entry] of this.records.entries()) {
      if (!entry || !entry.relativePath) continue;
      // Skip alias keys (where key != diskHash) so each photo appears once
      const canonicalHash = (entry.diskHash || entry.hash || key).toLowerCase();
      if (key !== canonicalHash && this.records.has(canonicalHash)) continue;
      if (seenPaths.has(entry.relativePath)) continue;
      seenPaths.add(entry.relativePath);
      items.push(this.formatMasterSummary(entry, key));
    }
    items.sort((a, b) => {
      const dateCmp = String(b.photoDate).localeCompare(String(a.photoDate));
      if (dateCmp !== 0) return dateCmp;
      return String(b.uploadedAt).localeCompare(String(a.uploadedAt));
    });
    return items;
  }

  async persist() {
    this.writePromise = this.writePromise.then(async () => {
      const obj = Object.fromEntries(this.records.entries());
      const tmpFile = `${this.hashIndexFile}.tmp`;
      await fsp.writeFile(tmpFile, JSON.stringify(obj, null, 2), 'utf8');
      await fsp.rename(tmpFile, this.hashIndexFile);
    });
    return this.writePromise;
  }
}

module.exports = {
  HashIndex,
  computeBufferSha256,
  computeFileSha256,
};
