/**
 * PHOTO HASH INDEX & METADATA MODEL (`data/hash-index*.json`)
 *
 * Where this belongs: `src/models/hashIndexModel.js` (Data / Model Layer — the "database" of backed-up media).
 * Created by: `src/services/contextService.js` (one `HashIndex` instance per user folder).
 * Attached to every authenticated request as `req.userContext.hashIndex` by `authMiddleware.js`,
 * and read/updated by `checkController`, `proxyController`, `photoController`, and `storageService`.
 *
 * What it manages:
 *   - `this.records`: Map<masterSha256, metadata> saved atomically to `DATA_DIR/hash-index*.json`
 *   - `this.proxyToMaster`: reverse Map<proxySha256, masterSha256> so compressed proxies aren't re-uploaded as new originals
 *   - `syncStorageDir()`: scans disk folders on startup/`?sync=1` to index manually added photos (using JPEG EXIF & filename dates)
 *   - `verifyExisting()` / `lookup()`: verifies a hash still physically exists on disk (or S3) before confirming delete/proxy actions
 */

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { readMediaExifMetadata, EXIF_SCHEMA_VERSION, reverseGeocodeOffline } = require('../services/exifGeoService');

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

function isValidYmd(y, m, d) {
  if (y < 1990 || y > 2099 || m < 1 || m > 12 || d < 1 || d > 31) return false;
  const check = new Date(Date.UTC(y, m - 1, d));
  return (
    check.getUTCFullYear() === y &&
    check.getUTCMonth() === m - 1 &&
    check.getUTCDate() === d
  );
}

function formatYmd(y, m, d) {
  return `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

function formatLocalYmd(date) {
  return formatYmd(date.getFullYear(), date.getMonth() + 1, date.getDate());
}

function parseExifDateString(str) {
  const m = String(str || '').match(
    /^(\d{4}):(\d{2}):(\d{2})[T\s](\d{2}):(\d{2}):(\d{2})/
  );
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const hh = Number(m[4]);
  const mm = Number(m[5]);
  const ss = Number(m[6]);
  if (!isValidYmd(y, mo, d) || hh > 23 || mm > 59 || ss > 59) return null;
  const dt = new Date(y, mo - 1, d, hh, mm, ss);
  if (Number.isNaN(dt.getTime())) return null;
  return {
    day: formatYmd(y, mo, d),
    takenAt: dt.toISOString(),
  };
}

/**
 * Lightweight dependency-free reader for EXIF/GPS DateTimeOriginal/Camera/GPS across
 * JPEG, HEIC/HEIF/AVIF, MOV/MP4, PNG, WebP, and TIFF/DNG delegated to `exifGeoService.js`.
 */
async function readJpegExifDateTime(fullPath) {
  return readMediaExifMetadata(fullPath);
}

function extractDateFromFilename(fileName) {
  const base = String(fileName || '');
  const dtMatch = base.match(
    /(?:^|[^\da-fA-F])((?:199\d|20\d{2}))[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])[T _.-](\d{2})[-.:]?(\d{2})[-.:]?(\d{2})(?:[^\d]|$)/
  );
  if (dtMatch) {
    const y = Number(dtMatch[1]);
    const mo = Number(dtMatch[2]);
    const d = Number(dtMatch[3]);
    const hh = Number(dtMatch[4]);
    const mm = Number(dtMatch[5]);
    const ss = Number(dtMatch[6]);
    if (isValidYmd(y, mo, d) && hh <= 23 && mm <= 59 && ss <= 59) {
      const dt = new Date(y, mo - 1, d, hh, mm, ss);
      return {
        day: formatYmd(y, mo, d),
        takenAt: Number.isNaN(dt.getTime()) ? null : dt.toISOString(),
      };
    }
  }

  const sepDateMatch = base.match(
    /(?:^|[^\d])((?:199\d|20\d{2}))[-_.](0[1-9]|1[0-2])[-_.](0[1-9]|[12]\d|3[01])(?:[^\d]|$)/
  );
  if (sepDateMatch) {
    const y = Number(sepDateMatch[1]);
    const mo = Number(sepDateMatch[2]);
    const d = Number(sepDateMatch[3]);
    if (isValidYmd(y, mo, d)) {
      return { day: formatYmd(y, mo, d), takenAt: null };
    }
  }

  const compactMatch = base.match(
    /(?:IMG|VID|PXL|MVIMG|Screenshot|Screen)[_-]((?:199\d|20\d{2}))(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?:[^\d]|$)/i
  );
  if (compactMatch) {
    const y = Number(compactMatch[1]);
    const mo = Number(compactMatch[2]);
    const d = Number(compactMatch[3]);
    if (isValidYmd(y, mo, d)) {
      return { day: formatYmd(y, mo, d), takenAt: null };
    }
  }
  return null;
}

function extractDateFromRelPath(relPath) {
  const norm = String(relPath || '').replace(/\\/g, '/');
  const dayMatch = norm.match(
    /(?:^|\/)(\d{4})[-_/](\d{2})[-_/](\d{2})(?:\/|$)/
  );
  if (dayMatch) {
    const y = Number(dayMatch[1]);
    const mo = Number(dayMatch[2]);
    const d = Number(dayMatch[3]);
    if (isValidYmd(y, mo, d)) {
      return { day: formatYmd(y, mo, d), year: y };
    }
  }
  const yearMatch = norm.match(/(?:^|\/)((?:199\d|20\d{2}))(?:\/|$)/);
  if (yearMatch) {
    return { day: null, year: Number(yearMatch[1]) };
  }
  return { day: null, year: null };
}

async function inferDiskMediaDates(relPath, fileName, stat, fullPath) {
  const pathInfo = extractDateFromRelPath(relPath);
  const exif = await readJpegExifDateTime(fullPath);
  const fileDate = extractDateFromFilename(fileName);
  const mtimeDay = formatLocalYmd(stat.mtime);

  const cameraModel = (exif && exif.cameraModel) || null;
  const gpsLat = exif && typeof exif.gpsLat === 'number' ? exif.gpsLat : null;
  const gpsLng = exif && typeof exif.gpsLng === 'number' ? exif.gpsLng : null;
  const locationLabel = (exif && exif.locationLabel) || null;
  const geo = { cameraModel, gpsLat, gpsLng, locationLabel };

  if (pathInfo.day) {
    let takenAt = null;
    if (exif && exif.day === pathInfo.day) {
      takenAt = exif.takenAt;
    } else if (fileDate && fileDate.day === pathInfo.day && fileDate.takenAt) {
      takenAt = fileDate.takenAt;
    } else if (mtimeDay === pathInfo.day) {
      takenAt = stat.mtime.toISOString();
    }
    return { photoDate: pathInfo.day, takenAt, ...geo };
  }

  if (exif && exif.day) {
    return { photoDate: exif.day, takenAt: exif.takenAt, ...geo };
  }

  if (fileDate) {
    const takenAt =
      fileDate.takenAt || (mtimeDay === fileDate.day ? stat.mtime.toISOString() : null);
    return { photoDate: fileDate.day, takenAt, ...geo };
  }

  if (pathInfo.year && stat.mtime.getFullYear() !== pathInfo.year) {
    return { photoDate: `${pathInfo.year}-01-01`, takenAt: null, ...geo };
  }

  return {
    photoDate: mtimeDay,
    takenAt: stat.mtime.toISOString(),
    ...geo,
  };
}

class HashIndex {
  constructor({
    storageDir,
    hashIndexFile,
    scanStorageOnStartup = true,
    shouldExcludePath = null,
  }) {
    this.storageDir = storageDir;
    this.hashIndexFile = hashIndexFile;
    this.scanStorageOnStartup = scanStorageOnStartup;
    this.shouldExcludePath =
      typeof shouldExcludePath === 'function' ? shouldExcludePath : null;
    this.records = new Map(); // sha256 -> { hash, relativePath, originalName, size, photoDate, uploadedAt, proxyHash? }
    this.proxyToMaster = new Map(); // proxySha256 -> masterSha256
    this.instanceNonce = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
    this.version = 1;
    this._cachedMasters = null;
    this._cachedStorageUsage = null;
    // Short-TTL stat verification cache (3s) so parallel HTTP Range segments for the same
    // original don't repeat identical `fsp.stat` syscalls milliseconds apart.
    this._statCache = new Map(); // fullPath -> { stat, size, mtimeMs, expiresAt }
    this.writePromise = Promise.resolve();
    this._isPersisting = false;
    this._dirtyWhilePersisting = false;
    this._pendingPersistWaiters = [];
    this.syncPromise = null;
  }

  _markDirty() {
    this.version += 1;
    this._cachedMasters = null;
    this._cachedStorageUsage = null;
    this._statCache.clear();
  }

  _deleteIndexedRecord(hash, entry) {
    this.records.delete(hash);
    if (entry && entry.proxyHash && typeof entry.proxyHash === 'string') {
      const p = entry.proxyHash.trim().toLowerCase();
      if (this.proxyToMaster.get(p) === hash) {
        this.proxyToMaster.delete(p);
      }
    }
    if (entry && Array.isArray(entry.proxyHashes)) {
      for (const rawP of entry.proxyHashes) {
        if (typeof rawP === 'string' && rawP.trim()) {
          const p = rawP.trim().toLowerCase();
          if (this.proxyToMaster.get(p) === hash) {
            this.proxyToMaster.delete(p);
          }
        }
      }
    }
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

    let prunedExcluded = false;
    try {
      const raw = await fsp.readFile(this.hashIndexFile, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') {
        for (const [hash, entry] of Object.entries(parsed)) {
          if (entry && entry.relativePath) {
            const relSlash = String(entry.relativePath).replace(/\\/g, '/');
            if (entry.storageType !== 's3' && this.shouldExcludePath && this.shouldExcludePath(relSlash, false)) {
              prunedExcluded = true;
              continue;
            }
            const normalizedHash = hash.toLowerCase();
            this.records.set(normalizedHash, entry);
            if (entry.proxyHash && typeof entry.proxyHash === 'string') {
              this.proxyToMaster.set(entry.proxyHash.toLowerCase(), normalizedHash);
            }
            if (Array.isArray(entry.proxyHashes)) {
              for (const pHash of entry.proxyHashes) {
                if (typeof pHash === 'string' && pHash.trim()) {
                  this.proxyToMaster.set(pHash.trim().toLowerCase(), normalizedHash);
                }
              }
            }
          }
        }
      }
    } catch (err) {
      if (err.code !== 'ENOENT') {
        console.warn('Warning: could not read hash index file, starting fresh:', err.message);
      }
    }

    if (prunedExcluded) {
      await this.persist().catch((err) => {
        console.warn('Warning: could not persist pruned hash index:', err.message);
      });
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
        const relSlash = String((entry && entry.relativePath) || '').replace(/\\/g, '/');
        if (entry && entry.storageType !== 's3' && this.shouldExcludePath && relSlash && this.shouldExcludePath(relSlash, false)) {
          this._deleteIndexedRecord(hash, entry);
          changed = true;
          continue;
        }
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
            this._deleteIndexedRecord(hash, entry);
            changed = true;
          } else {
            indexedPaths.add(path.normalize(entry.relativePath));
            const needsMetaBackfill =
              entry.storageType !== 's3' &&
              ((!entry.diskHash && (!entry.photoDate || !entry.takenAt)) ||
                (typeof entry.gpsLat !== 'number' &&
                  (!entry._exifScanned || (entry._exifVersion || 0) < EXIF_SCHEMA_VERSION)));
            if (needsMetaBackfill) {
              const inferred = await inferDiskMediaDates(
                entry.relativePath,
                entry.originalName || path.basename(fullPath),
                stat,
                fullPath
              );
              if (!entry.diskHash) {
                if (inferred.photoDate && entry.photoDate !== inferred.photoDate) {
                  entry.photoDate = inferred.photoDate;
                  changed = true;
                }
                if (inferred.takenAt && !entry.takenAt) {
                  entry.takenAt = inferred.takenAt;
                  changed = true;
                }
              }
              if (inferred.cameraModel && !entry.cameraModel) {
                entry.cameraModel = inferred.cameraModel;
                changed = true;
              }
              if (typeof inferred.gpsLat === 'number' && typeof inferred.gpsLng === 'number') {
                entry.gpsLat = inferred.gpsLat;
                entry.gpsLng = inferred.gpsLng;
                entry.locationLabel = inferred.locationLabel || entry.locationLabel || null;
                changed = true;
              }
              if (!entry._exifScanned || entry._exifVersion !== EXIF_SCHEMA_VERSION) {
                entry._exifScanned = true;
                entry._exifVersion = EXIF_SCHEMA_VERSION;
                changed = true;
              }
            }
          }
        } catch {
          this._deleteIndexedRecord(hash, entry);
          changed = true;
        }
      }

      const ignoredDirs = new Set([
        '@eaDir',
        '#recycle',
        'lost+found',
        '$RECYCLE.BIN',
        'System Volume Information',
      ]);

      const walk = async (dir) => {
        let entries;
        try {
          entries = await fsp.readdir(dir, { withFileTypes: true });
        } catch (err) {
          console.warn(`[hashIndex] Skipping unreadable directory ${dir}:`, err.message);
          return;
        }
        for (const d of entries) {
          if (d.name.startsWith('.') || ignoredDirs.has(d.name)) continue;
          const fullPath = path.join(dir, d.name);
          const relPath = path.normalize(path.relative(this.storageDir, fullPath));
          const relSlash = relPath.split(path.sep).join('/');
          const isDir = d.isDirectory();
          if (this.shouldExcludePath && this.shouldExcludePath(relSlash, isDir)) {
            continue;
          }
          if (isDir) {
            await walk(fullPath);
          } else if (d.isFile() && !d.name.endsWith('.tmp')) {
            if (!indexedPaths.has(relPath)) {
              try {
                const stat = await fsp.stat(fullPath);
                const hash = await computeFileSha256(fullPath);
                const inferred = await inferDiskMediaDates(relSlash, d.name, stat, fullPath);
                this.records.set(hash, {
                  hash,
                  relativePath: relSlash,
                  originalName: d.name,
                  size: stat.size,
                  mtimeMs: stat.mtimeMs,
                  photoDate: inferred.photoDate,
                  takenAt: inferred.takenAt,
                  cameraModel: inferred.cameraModel || null,
                  gpsLat: inferred.gpsLat,
                  gpsLng: inferred.gpsLng,
                  locationLabel: inferred.locationLabel || null,
                  _exifScanned: true,
                  _exifVersion: EXIF_SCHEMA_VERSION,
                  uploadedAt: (stat.birthtime || stat.mtime).toISOString(),
                });
                indexedPaths.add(relPath);
                changed = true;
              } catch (err) {
                console.warn(`[hashIndex] Skipping unreadable file ${fullPath}:`, err.message);
              }
            }
          }
        }
      };

      await walk(this.storageDir);
      if (changed) {
        this._markDirty();
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
   * Backfills GPS/camera/date EXIF metadata for active disk files that have not yet been
   * scanned by the multi-format parser (HEIC/HEIF, MOV/MP4, JPEG, WebP, PNG, TIFF/DNG).
   * Safe to call on demand from `GET /api/photos/map` without blocking large libraries.
   */
  async backfillExifGeo({ maxFiles = 350, force = false } = {}) {
    const candidates = [];
    const seenCanonical = new Set();
    let changed = false;

    for (const [key, entry] of this.records.entries()) {
      if (!entry || entry.deletedAt || entry.storageType === 's3' || !entry.relativePath) {
        continue;
      }
      const canonical = String(entry.diskHash || entry.hash || key).toLowerCase();
      if (seenCanonical.has(canonical)) continue;
      seenCanonical.add(canonical);

      // Refresh missing locationLabel if GPS coords already exist
      if (typeof entry.gpsLat === 'number' && typeof entry.gpsLng === 'number') {
        if (!entry.locationLabel) {
          const label = reverseGeocodeOffline(entry.gpsLat, entry.gpsLng);
          if (label) {
            const found = this.findMasterRecordKeys(canonical);
            const aliasKeys = found && Array.isArray(found.keys) ? found.keys : [canonical];
            for (const aliasKey of aliasKeys) {
              const rec = this.records.get(aliasKey);
              if (rec) rec.locationLabel = label;
            }
            changed = true;
          }
        }
        continue;
      }

      const needsScan = force || !entry._exifScanned || (entry._exifVersion || 0) < EXIF_SCHEMA_VERSION;
      if (needsScan) {
        candidates.push({ canonical, entry });
      }
    }

    if (candidates.length === 0) {
      if (changed) {
        this._markDirty();
        await this.persist();
      }
      return { scanned: 0, foundGps: 0, remaining: 0 };
    }

    const limit = Math.max(1, Number(maxFiles) || 350);
    const batch = candidates.slice(0, limit);
    const remaining = Math.max(0, candidates.length - batch.length);
    let scanned = 0;
    let foundGps = 0;

    const concurrency = 8;
    let cursor = 0;
    const worker = async () => {
      while (cursor < batch.length) {
        const idx = cursor++;
        const { canonical, entry } = batch[idx];
        const fullPath = path.join(this.storageDir, entry.relativePath);
        try {
          const exif = await readMediaExifMetadata(fullPath);
          scanned += 1;
          const found = this.findMasterRecordKeys(canonical);
          const keys = found && Array.isArray(found.keys) ? found.keys : [canonical];
          const hasGps = exif && typeof exif.gpsLat === 'number' && typeof exif.gpsLng === 'number';
          if (hasGps) foundGps += 1;
          for (const k of keys) {
            const rec = this.records.get(k);
            if (!rec) continue;
            if (hasGps) {
              rec.gpsLat = exif.gpsLat;
              rec.gpsLng = exif.gpsLng;
              rec.locationLabel = exif.locationLabel || rec.locationLabel || reverseGeocodeOffline(exif.gpsLat, exif.gpsLng);
            }
            if (exif && exif.cameraModel && !rec.cameraModel) {
              rec.cameraModel = exif.cameraModel;
            }
            if (exif && exif.takenAt && !rec.takenAt) {
              rec.takenAt = exif.takenAt;
            }
            rec._exifScanned = true;
            rec._exifVersion = EXIF_SCHEMA_VERSION;
          }
          changed = true;
        } catch {
          // Non-fatal: mark scanned on unreadable file only if missing
        }
      }
    };

    const workers = [];
    for (let i = 0; i < Math.min(concurrency, batch.length); i++) {
      workers.push(worker());
    }
    await Promise.all(workers);

    if (changed) {
      this._markDirty();
      await this.persist();
    }
    return { scanned, foundGps, remaining };
  }

  /**
   * Finds an active (non-trashed) master record whose canonical hash starts with an 8–64 hex prefix.
   * Used to prevent compressed `PHOTOHUB_PROXY_<prefix>` copies from being re-uploaded as duplicates.
   */
  findByMasterHashPrefix(rawPrefix) {
    if (!rawPrefix || typeof rawPrefix !== 'string') return null;
    const prefix = rawPrefix.trim().toLowerCase().replace(/[^a-f0-9]/g, '');
    if (prefix.length < 8) return null;
    if (prefix.length === 64) {
      const exact = this.records.get(prefix);
      if (exact && !exact.deletedAt) {
        return { masterHash: exact.diskHash || exact.hash || prefix, record: exact };
      }
      return null;
    }
    for (const [k, rec] of this.records.entries()) {
      if (!rec || rec.deletedAt) continue;
      const canonical = String(rec.diskHash || rec.hash || k).toLowerCase();
      if (canonical.startsWith(prefix) || String(k).toLowerCase().startsWith(prefix)) {
        return { masterHash: canonical, record: rec };
      }
    }
    return null;
  }

  /**
   * Checks if a hash exists in the index AND verifies that the file still physically exists on disk.
   * Pass `allowStatFastPath: true` for already-verified routes like proxy registration or streaming reads
   * so large video files aren't re-hashed when byte size and mtimeMs match cleanly.
   * Pass `withStat: true` to receive `{ record, stat }` so streaming callers avoid a duplicate `fsp.stat`.
   */
  async verifyExisting(rawHash, { allowStatFastPath = false, withStat = false } = {}) {
    if (!rawHash || typeof rawHash !== 'string') return withStat ? null : null;
    const hash = rawHash.trim().toLowerCase();
    const record = this.records.get(hash);
    if (!record) return null;

    if (record.storageType === 's3') {
      return withStat ? { record, stat: null } : record;
    }

    const fullPath = path.join(this.storageDir, record.relativePath);
    if (allowStatFastPath && typeof record.mtimeMs === 'number') {
      const cached = this._statCache.get(fullPath);
      if (
        cached &&
        cached.expiresAt > Date.now() &&
        cached.size === record.size &&
        cached.mtimeMs === record.mtimeMs
      ) {
        return withStat ? { record, stat: cached.stat } : record;
      }
    }

    try {
      const stat = await fsp.stat(fullPath);
      if (!stat.isFile() || stat.size !== record.size) {
        this._statCache.delete(fullPath);
        this._deleteIndexedRecord(hash, record);
        this._markDirty();
        await this.persist();
        return null;
      }
      if (
        allowStatFastPath &&
        typeof record.mtimeMs === 'number' &&
        stat.mtimeMs === record.mtimeMs
      ) {
        if (this._statCache.size > 2048) {
          this._statCache.clear();
        }
        this._statCache.set(fullPath, {
          stat,
          size: stat.size,
          mtimeMs: stat.mtimeMs,
          expiresAt: Date.now() + 3000,
        });
        return withStat ? { record, stat } : record;
      }
      const diskHash = await computeFileSha256(fullPath);
      const expectedDiskHash = record.diskHash || hash;
      if (diskHash !== expectedDiskHash) {
        this._statCache.delete(fullPath);
        this._deleteIndexedRecord(hash, record);
        this._markDirty();
        await this.persist();
        return null;
      }
      record.mtimeMs = stat.mtimeMs;
      if (this._statCache.size > 2048) {
        this._statCache.clear();
      }
      this._statCache.set(fullPath, {
        stat,
        size: stat.size,
        mtimeMs: stat.mtimeMs,
        expiresAt: Date.now() + 3000,
      });
      return withStat ? { record, stat } : record;
    } catch {
      this._statCache.delete(fullPath);
      this._deleteIndexedRecord(hash, record);
      this._markDirty();
      await this.persist();
      return null;
    }
  }

  /**
   * Resolves a hash as either a verified master photo, a known compressed proxy, or missing.
   */
  async lookup(rawHash, options = {}) {
    if (!rawHash || typeof rawHash !== 'string') {
      return { status: 'missing', record: null, masterHash: null, stat: null };
    }
    const normalized = rawHash.trim().toLowerCase();
    const includeTrashed = Boolean(options.includeTrashed);
    const includeStat = Boolean(options.includeStat);
    const verifyOpts = includeStat ? { ...options, withStat: true } : options;

    const masterRes = await this.verifyExisting(normalized, verifyOpts);
    const masterRecord = includeStat ? (masterRes && masterRes.record) : masterRes;
    const masterStat = includeStat ? (masterRes && masterRes.stat) || null : null;
    if (masterRecord && (includeTrashed || !masterRecord.deletedAt)) {
      return {
        status: 'master',
        record: masterRecord,
        masterHash: masterRecord.diskHash || masterRecord.hash || normalized,
        stat: masterStat,
      };
    }

    const mappedMasterHash = this.proxyToMaster.get(normalized);
    if (mappedMasterHash) {
      const proxyRes = await this.verifyExisting(mappedMasterHash, verifyOpts);
      const verifiedMaster = includeStat ? (proxyRes && proxyRes.record) : proxyRes;
      const verifiedStat = includeStat ? (proxyRes && proxyRes.stat) || null : null;
      if (verifiedMaster && (includeTrashed || !verifiedMaster.deletedAt)) {
        return {
          status: 'proxy',
          record: verifiedMaster,
          masterHash: verifiedMaster.diskHash || verifiedMaster.hash || mappedMasterHash,
          stat: verifiedStat,
        };
      }
      if (!verifiedMaster) {
        this.proxyToMaster.delete(normalized);
      }
    }

    return { status: 'missing', record: null, masterHash: null, stat: null };
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

    const knownProxyHashes = new Set(
      Array.isArray(record.proxyHashes)
        ? record.proxyHashes.map((h) => String(h || '').trim().toLowerCase()).filter(Boolean)
        : []
    );
    if (record.proxyHash && typeof record.proxyHash === 'string') {
      knownProxyHashes.add(record.proxyHash.trim().toLowerCase());
    }
    knownProxyHashes.add(normProxy);

    record.proxyHash = normProxy;
    record.proxyHashes = Array.from(knownProxyHashes);
    if (assetId) {
      record.assetId = String(assetId);
    }
    if (proxyMeta.proxyRelativePath) {
      record.proxyRelativePath = proxyMeta.proxyRelativePath;
    }
    if (proxyMeta.proxyStorageType) {
      record.proxyStorageType = proxyMeta.proxyStorageType;
    }
    if (proxyMeta.proxySize) {
      record.proxySize = Number(proxyMeta.proxySize);
    }
    if (proxyMeta.videoProxyRelativePath) {
      record.videoProxyRelativePath = proxyMeta.videoProxyRelativePath;
    }
    if (proxyMeta.videoProxyStorageType) {
      record.videoProxyStorageType = proxyMeta.videoProxyStorageType;
    }
    if (proxyMeta.videoProxySize) {
      record.videoProxySize = Number(proxyMeta.videoProxySize);
    }
    record.proxyRegisteredAt = new Date().toISOString();

    this.records.set(normMaster, record);
    for (const pHash of record.proxyHashes) {
      this.proxyToMaster.set(pHash, normMaster);
    }
    this._markDirty();
    await this.persist();
    return record;
  }

  /**
   * Marks or clears whether a master photo was intentionally restored on device and should
   * not be re-proxied or auto-deleted by background/batch compression.
   * Updates canonical + all alias keys atomically so cross-device views never diverge.
   */
  async setOriginalProtected(masterHash, keepOriginal = true) {
    const lookupResult = await this.lookup(masterHash, { allowStatFastPath: true });
    if (lookupResult.status === 'missing' || !lookupResult.record) {
      return null;
    }
    const normMaster = (lookupResult.masterHash || String(masterHash || '')).trim().toLowerCase();
    const flag = Boolean(keepOriginal);
    const nowIso = flag ? new Date().toISOString() : null;
    const found = this.findMasterRecordKeys(normMaster);
    if (found && found.keys.length > 0) {
      for (const k of found.keys) {
        const entry = this.records.get(k);
        if (entry) {
          entry.keepOriginalOnDevice = flag;
          entry.originalProtectedAt = nowIso;
        }
      }
      this._markDirty();
      await this.persist();
      return found.record;
    }
    const record = this.records.get(normMaster) || lookupResult.record;
    record.keepOriginalOnDevice = flag;
    record.originalProtectedAt = nowIso;
    this.records.set(normMaster, record);
    this._markDirty();
    await this.persist();
    return record;
  }

  /**
   * Batch version of `setOriginalProtected`: updates up to hundreds of restored photos in one
   * atomic `hash-index.json` persist instead of N separate HTTP round-trips & disk rewrites.
   */
  async setOriginalsProtectedBatch(rawHashes, keepOriginal = true) {
    const flag = Boolean(keepOriginal);
    const nowIso = flag ? new Date().toISOString() : null;
    const updated = [];
    const missing = [];
    const seenCanonical = new Set();
    let changed = false;

    for (const raw of rawHashes || []) {
      const norm = String(raw || '').trim().toLowerCase();
      if (!norm) continue;
      const mapped = this.proxyToMaster.get(norm);
      const targetKey = this.records.has(norm) ? norm : mapped || norm;
      const found = this.findMasterRecordKeys(targetKey);
      if (!found || !found.record) {
        missing.push(norm);
        continue;
      }
      if (seenCanonical.has(found.canonicalHash)) continue;
      seenCanonical.add(found.canonicalHash);

      for (const k of found.keys) {
        const entry = this.records.get(k);
        if (entry) {
          if (Boolean(entry.keepOriginalOnDevice) !== flag) {
            changed = true;
          }
          entry.keepOriginalOnDevice = flag;
          entry.originalProtectedAt = nowIso;
        }
      }
      updated.push(this.formatMasterSummary(found.record, found.canonicalHash));
    }

    if (changed) {
      this._markDirty();
      await this.persist();
    }
    return { updated, missing };
  }

  /**
   * Collects every record key (canonical hash plus any pre-transcode aliases)
   * pointing to the same underlying stored master photo as `rawHash`.
   */
  findMasterRecordKeys(rawHash) {
    const clean = String(rawHash || '').trim().toLowerCase();
    if (!clean) return null;

    const direct = this.records.get(clean);
    if (!direct) return null;

    const canonicalHash = String(direct.diskHash || direct.hash || clean)
      .trim()
      .toLowerCase();
    const canonicalEntry = this.records.get(canonicalHash) || direct;
    const relPath = canonicalEntry.relativePath || direct.relativePath || null;

    const keys = [];
    for (const [k, entry] of this.records.entries()) {
      if (!entry) continue;
      const entryCanonical = String(entry.diskHash || entry.hash || k)
        .trim()
        .toLowerCase();
      if (
        k === clean ||
        k === canonicalHash ||
        entryCanonical === canonicalHash ||
        (relPath && entry.relativePath === relPath)
      ) {
        keys.push(k);
      }
    }

    return {
      canonicalHash,
      record: canonicalEntry,
      keys,
    };
  }

  /**
   * Removes the specified index keys (and their proxyToMaster mappings) and persists once.
   */
  async removeKeys(keysToRemove, { persist = true } = {}) {
    let removedCount = 0;
    for (const key of keysToRemove || []) {
      const entry = this.records.get(key);
      if (!entry) continue;
      this._deleteIndexedRecord(key, entry);
      removedCount += 1;
    }
    if (removedCount > 0) {
      this._markDirty();
      if (persist) {
        await this.persist();
      }
    }
    return removedCount;
  }

  async setFavorite(masterHash, isFavorite = true) {
    const lookupResult = await this.lookup(masterHash, { allowStatFastPath: true });
    if (lookupResult.status === 'missing' || !lookupResult.record) {
      return null;
    }
    const normMaster = (lookupResult.masterHash || String(masterHash || '')).trim().toLowerCase();
    const flag = Boolean(isFavorite);
    const nowIso = flag ? new Date().toISOString() : null;
    const found = this.findMasterRecordKeys(normMaster);
    if (found && found.keys.length > 0) {
      for (const k of found.keys) {
        const entry = this.records.get(k);
        if (entry) {
          entry.isFavorite = flag;
          entry.favoritedAt = nowIso;
        }
      }
      this._markDirty();
      await this.persist();
      return found.record;
    }
    const record = this.records.get(normMaster) || lookupResult.record;
    record.isFavorite = flag;
    record.favoritedAt = nowIso;
    this.records.set(normMaster, record);
    this._markDirty();
    await this.persist();
    return record;
  }

  getCategoryCounts() {
    const unique = this._getUniqueMasterRecords({ includeTrashed: true });
    let totalActive = 0;
    let protectedCount = 0;
    let favoriteCount = 0;
    let trashCount = 0;
    for (const { entry } of unique) {
      if (entry.deletedAt) {
        trashCount += 1;
        continue;
      }
      totalActive += 1;
      if (entry.keepOriginalOnDevice) protectedCount += 1;
      if (entry.isFavorite) favoriteCount += 1;
    }
    return { totalActive, protectedCount, favoriteCount, trashCount };
  }

  async updateVisualMetrics(masterHash, { dHash = null, blurScore = null, width = null, height = null } = {}) {
    const lookupResult = await this.lookup(masterHash, { allowStatFastPath: true });
    if (lookupResult.status === 'missing' || !lookupResult.record) {
      return null;
    }
    const normMaster = (lookupResult.masterHash || String(masterHash || '')).trim().toLowerCase();
    const record = this.records.get(normMaster) || lookupResult.record;
    let mutated = false;
    if (typeof dHash === 'string' && dHash.length === 16 && record.dHash !== dHash) {
      record.dHash = dHash;
      mutated = true;
    }
    if (typeof blurScore === 'number' && Number.isFinite(blurScore) && record.blurScore !== blurScore) {
      record.blurScore = blurScore;
      mutated = true;
    }
    if (width && !record.width) {
      record.width = Number(width);
      mutated = true;
    }
    if (height && !record.height) {
      record.height = Number(height);
      mutated = true;
    }
    if (mutated) {
      this.records.set(normMaster, record);
      this._markDirty();
      await this.persist();
    }
    return record;
  }

  /**
   * Soft-deletes photos into the 30-day Trash bin by setting `deletedAt` across canonical & alias keys.
   */
  async moveToTrash(rawHashes) {
    const nowIso = new Date().toISOString();
    const trashed = [];
    const missing = [];
    const seenCanonical = new Set();
    let changed = false;

    for (const raw of rawHashes || []) {
      const norm = String(raw || '').trim().toLowerCase();
      if (!norm) continue;
      const found = this.findMasterRecordKeys(norm);
      if (!found || !found.record || found.record.deletedAt) {
        missing.push(norm);
        continue;
      }
      if (seenCanonical.has(found.canonicalHash)) continue;
      seenCanonical.add(found.canonicalHash);

      for (const k of found.keys) {
        const entry = this.records.get(k);
        if (entry) {
          entry.deletedAt = nowIso;
          changed = true;
        }
      }
      trashed.push(found.canonicalHash);
    }

    if (changed) {
      this._markDirty();
      await this.persist();
    }
    return { trashed, missing };
  }

  /**
   * Restores soft-deleted photos from Trash back into the active gallery.
   */
  async restoreFromTrash(rawHashes) {
    const restored = [];
    const missing = [];
    const seenCanonical = new Set();
    let changed = false;

    for (const raw of rawHashes || []) {
      const norm = String(raw || '').trim().toLowerCase();
      if (!norm) continue;
      const found = this.findMasterRecordKeys(norm);
      if (!found || !found.record || !found.record.deletedAt) {
        missing.push(norm);
        continue;
      }
      if (seenCanonical.has(found.canonicalHash)) continue;
      seenCanonical.add(found.canonicalHash);

      for (const k of found.keys) {
        const entry = this.records.get(k);
        if (entry) {
          entry.deletedAt = null;
          changed = true;
        }
      }
      restored.push(found.canonicalHash);
    }

    if (changed) {
      this._markDirty();
      await this.persist();
    }
    return { restored, missing };
  }

  getExpiredTrashRecords(retentionMs = 30 * 24 * 60 * 60 * 1000) {
    const cutoff = Date.now() - retentionMs;
    const expired = [];
    for (const { canonicalHash, entry } of this._getUniqueMasterRecords({ onlyTrashed: true })) {
      const delMs = Date.parse(entry.deletedAt || '');
      if (!Number.isNaN(delMs) && delMs <= cutoff) {
        const found = this.findMasterRecordKeys(canonicalHash);
        if (found) expired.push(found);
      }
    }
    return expired;
  }

  listTrashed(retentionDays = 30) {
    const retentionMs = retentionDays * 24 * 60 * 60 * 1000;
    const now = Date.now();
    const items = this._getUniqueMasterRecords({ onlyTrashed: true }).map(({ key, entry }) => {
      const summary = this.formatMasterSummary(entry, key);
      const deletedMs = Date.parse(entry.deletedAt || '') || now;
      const expiresMs = deletedMs + retentionMs;
      const daysRemaining = Math.max(0, Math.ceil((expiresMs - now) / (24 * 60 * 60 * 1000)));
      return {
        ...summary,
        deletedAt: entry.deletedAt,
        expiresAt: new Date(expiresMs).toISOString(),
        daysRemaining,
      };
    });
    items.sort((a, b) => String(b.deletedAt || '').localeCompare(String(a.deletedAt || '')));
    return items;
  }

  async set(hash, record) {
    const normalized = hash.trim().toLowerCase();
    this.records.set(normalized, {
      ...record,
      deletedAt: null,
      // Keep the real on-disk hash so alias keys (e.g. pre-transcode HEIC hash) still verify
      diskHash: record.diskHash || record.hash || normalized,
      hash: normalized,
    });
    this._markDirty();
    await this.persist();
    return this.records.get(normalized);
  }

  size() {
    return this.records.size;
  }

  formatMasterSummary(entry, fallbackHash = '') {
    const canonicalHash = (entry.diskHash || entry.hash || fallbackHash).toLowerCase();
    const fallbackDay =
      entry.photoDate ||
      extractDateFromRelPath(entry.relativePath).day ||
      (entry.takenAt ? String(entry.takenAt).slice(0, 10) : '') ||
      (entry.uploadedAt ? String(entry.uploadedAt).slice(0, 10) : '');
    const yearNum = /^\d{4}/.test(fallbackDay) ? Number(fallbackDay.slice(0, 4)) : null;
    return {
      hash: canonicalHash,
      originalName: entry.originalName,
      size: entry.size || 0,
      photoDate: entry.photoDate || fallbackDay,
      takenAt: entry.takenAt || null,
      year: yearNum,
      uploadedAt: entry.uploadedAt || '',
      savedPath: entry.relativePath,
      storageType: entry.storageType || 'disk',
      hasProxy: Boolean(entry.proxyHash || entry.proxyRelativePath),
      hasPreview: Boolean(entry.proxyRelativePath),
      proxyHash: entry.proxyHash || null,
      proxySize: entry.proxySize || null,
      hasVideoProxy: Boolean(entry.videoProxyRelativePath),
      videoProxySize: entry.videoProxySize || null,
      keepOriginalOnDevice: Boolean(entry.keepOriginalOnDevice),
      isFavorite: Boolean(entry.isFavorite),
      deletedAt: entry.deletedAt || null,
      cameraModel: entry.cameraModel || null,
      gpsLat: typeof entry.gpsLat === 'number' ? entry.gpsLat : null,
      gpsLng: typeof entry.gpsLng === 'number' ? entry.gpsLng : null,
      locationLabel: entry.locationLabel || null,
      dHash: entry.dHash || null,
      blurScore: typeof entry.blurScore === 'number' ? entry.blurScore : null,
      width: entry.width || null,
      height: entry.height || null,
    };
  }

  _getUniqueMasterRecords({ includeTrashed = false, onlyTrashed = false } = {}) {
    const seenPaths = new Set();
    const list = [];
    for (const [key, entry] of this.records.entries()) {
      if (!entry || !entry.relativePath) continue;
      const isTrashed = Boolean(entry.deletedAt);
      if (onlyTrashed && !isTrashed) continue;
      if (!includeTrashed && !onlyTrashed && isTrashed) continue;
      // Skip alias keys (where key != diskHash) so each photo appears once
      const canonicalHash = (entry.diskHash || entry.hash || key).toLowerCase();
      if (key !== canonicalHash && this.records.has(canonicalHash)) continue;
      if (seenPaths.has(entry.relativePath)) continue;
      seenPaths.add(entry.relativePath);
      list.push({ key, canonicalHash, entry });
    }
    return list;
  }

  getStorageUsage() {
    if (this._cachedStorageUsage) {
      return { ...this._cachedStorageUsage };
    }
    let mastersBytes = 0;
    let proxiesBytes = 0;
    let trashBytes = 0;
    let activeItemCount = 0;
    let trashItemCount = 0;
    const unique = this._getUniqueMasterRecords({ includeTrashed: true });
    for (const { entry } of unique) {
      const m = Number(entry.size) || 0;
      const p = (Number(entry.proxySize) || 0) + (Number(entry.videoProxySize) || 0);
      mastersBytes += m;
      proxiesBytes += p;
      if (entry.deletedAt) {
        trashItemCount += 1;
        trashBytes += m + p;
      } else {
        activeItemCount += 1;
      }
    }
    this._cachedStorageUsage = {
      itemCount: activeItemCount,
      trashItemCount,
      mastersBytes,
      proxiesBytes,
      trashBytes,
      usedBytes: mastersBytes + proxiesBytes,
    };
    return { ...this._cachedStorageUsage };
  }

  /**
   * Returns a deduplicated list of backed-up master photo records, sorted newest first
   * by capture day, full capture timestamp (`takenAt`), and upload timestamp.
   */
  listMasters() {
    if (this._cachedMasters) {
      return this._cachedMasters;
    }
    const items = this._getUniqueMasterRecords().map(({ key, entry }) =>
      this.formatMasterSummary(entry, key)
    );
    items.sort((a, b) => {
      const aDay = String(
        a.photoDate || (a.takenAt || '').slice(0, 10) || (a.uploadedAt || '').slice(0, 10)
      );
      const bDay = String(
        b.photoDate || (b.takenAt || '').slice(0, 10) || (b.uploadedAt || '').slice(0, 10)
      );
      const dateCmp = bDay.localeCompare(aDay);
      if (dateCmp !== 0) return dateCmp;

      const aTaken = a.takenAt ? Date.parse(a.takenAt) : Number.NaN;
      const bTaken = b.takenAt ? Date.parse(b.takenAt) : Number.NaN;
      if (!Number.isNaN(bTaken) && !Number.isNaN(aTaken) && bTaken !== aTaken) {
        return bTaken - aTaken;
      }
      if (!Number.isNaN(bTaken) !== !Number.isNaN(aTaken)) {
        return !Number.isNaN(bTaken) ? 1 : -1;
      }

      const upCmp = String(b.uploadedAt || '').localeCompare(String(a.uploadedAt || ''));
      if (upCmp !== 0) return upCmp;
      return String(b.originalName || '').localeCompare(String(a.originalName || ''));
    });
    this._cachedMasters = items;
    return items;
  }

  async _writeSnapshotToDisk() {
    const obj = Object.fromEntries(this.records.entries());
    const tmpFile = `${this.hashIndexFile}.${process.pid}.tmp`;
    // Compact JSON reduces disk footprint & serialize/parse CPU by ~40% vs pretty-printed JSON.
    await fsp.writeFile(tmpFile, JSON.stringify(obj), 'utf8');
    await fsp.rename(tmpFile, this.hashIndexFile);
  }

  /**
   * Coalesces concurrent mutations so burst uploads/restores collapse into minimal atomic disk writes
   * while still resolving each caller only after its update is safely persisted on disk.
   */
  async persist() {
    if (this._isPersisting) {
      this._dirtyWhilePersisting = true;
      return new Promise((resolve, reject) => {
        this._pendingPersistWaiters.push({ resolve, reject });
      });
    }

    this._isPersisting = true;
    const run = (async () => {
      try {
        await this._writeSnapshotToDisk();
        while (this._dirtyWhilePersisting) {
          this._dirtyWhilePersisting = false;
          const batchWaiters = this._pendingPersistWaiters.splice(0);
          try {
            await this._writeSnapshotToDisk();
            for (const w of batchWaiters) w.resolve();
          } catch (err) {
            for (const w of batchWaiters) w.reject(err);
            throw err;
          }
        }
      } finally {
        this._isPersisting = false;
        if (this._pendingPersistWaiters.length > 0) {
          const leftover = this._pendingPersistWaiters.splice(0);
          this.persist().then(
            () => leftover.forEach((w) => w.resolve()),
            (err) => leftover.forEach((w) => w.reject(err))
          );
        }
      }
    })();

    this.writePromise = run.catch(() => {});
    return run;
  }

  async flush() {
    if (this._isPersisting || this._dirtyWhilePersisting) {
      await this.writePromise;
    }
  }
}

module.exports = {
  HashIndex,
  computeBufferSha256,
  computeFileSha256,
};
