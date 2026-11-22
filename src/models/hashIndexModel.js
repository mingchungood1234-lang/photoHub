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

const JPEG_EXTS = new Set(['.jpg', '.jpeg']);

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
 * Lightweight dependency-free reader for JPEG APP1 EXIF DateTimeOriginal/DateTime
 * using at most a 64 KB header read so huge photo libraries scan quickly.
 */
async function readJpegExifDateTime(fullPath) {
  const ext = path.extname(fullPath).toLowerCase();
  if (!JPEG_EXTS.has(ext)) return null;

  let fh = null;
  try {
    fh = await fsp.open(fullPath, 'r');
    const maxBytes = 65536;
    const rawBuf = Buffer.allocUnsafe(maxBytes);
    const { bytesRead } = await fh.read(rawBuf, 0, maxBytes, 0);
    if (bytesRead < 16) return null;
    const buf = rawBuf.subarray(0, bytesRead);
    if (buf[0] !== 0xff || buf[1] !== 0xd8) return null;

    let pos = 2;
    while (pos + 4 <= buf.length) {
      while (pos < buf.length && buf[pos] === 0xff && buf[pos + 1] === 0xff) {
        pos += 1;
      }
      if (pos + 4 > buf.length || buf[pos] !== 0xff) break;
      const marker = buf[pos + 1];
      if (marker === 0xda || marker === 0xd9) break; // SOS / EOI
      const segLen = buf.readUInt16BE(pos + 2);
      if (segLen < 2 || pos + 2 + segLen > buf.length) break;

      if (
        marker === 0xe1 &&
        segLen >= 16 &&
        buf.toString('ascii', pos + 4, pos + 10) === 'Exif\0\0'
      ) {
        const tiffStart = pos + 10;
        const endian = buf.toString('ascii', tiffStart, tiffStart + 2);
        if (endian !== 'II' && endian !== 'MM') return null;
        const le = endian === 'II';
        const readU16 = (off) =>
          off + 2 <= buf.length
            ? le
              ? buf.readUInt16LE(off)
              : buf.readUInt16BE(off)
            : 0;
        const readU32 = (off) =>
          off + 4 <= buf.length
            ? le
              ? buf.readUInt32LE(off)
              : buf.readUInt32BE(off)
            : 0;

        if (readU16(tiffStart + 2) !== 0x002a) return null;
        const ifd0Rel = readU32(tiffStart + 4);

        const scanIfd = (ifdRel) => {
          const ifdOff = tiffStart + ifdRel;
          if (ifdOff + 2 > buf.length) return { entries: [] };
          const count = Math.min(readU16(ifdOff), 256);
          const tags = new Map();
          for (let i = 0; i < count; i++) {
            const entryOff = ifdOff + 2 + i * 12;
            if (entryOff + 12 > buf.length) break;
            const tag = readU16(entryOff);
            const type = readU16(entryOff + 2);
            const valCount = readU32(entryOff + 4);
            tags.set(tag, { type, valCount, valueOff: entryOff + 8 });
          }
          return tags;
        };

        const readAsciiTag = (tagEntry) => {
          if (!tagEntry || tagEntry.type !== 2 || tagEntry.valCount < 19) return null;
          const byteCount = Math.min(tagEntry.valCount, 64);
          const dataOff =
            tagEntry.valCount <= 4
              ? tagEntry.valueOff
              : tiffStart + readU32(tagEntry.valueOff);
          if (dataOff < tiffStart || dataOff + byteCount > buf.length) return null;
          return buf.toString('ascii', dataOff, dataOff + byteCount).replace(/\0.*$/, '');
        };

        const ifd0 = scanIfd(ifd0Rel);
        if (ifd0.has(0x8769)) {
          const exifPtr = readU32(ifd0.get(0x8769).valueOff);
          const exifIfd = scanIfd(exifPtr);
          const rawOrig =
            readAsciiTag(exifIfd.get(0x9003)) ||
            readAsciiTag(exifIfd.get(0x9004));
          const parsedOrig = parseExifDateString(rawOrig);
          if (parsedOrig) return parsedOrig;
        }
        const parsedIfd0 = parseExifDateString(readAsciiTag(ifd0.get(0x0132)));
        if (parsedIfd0) return parsedIfd0;
        return null;
      }

      pos += 2 + segLen;
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fh) {
      await fh.close().catch(() => {});
    }
  }
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

  if (pathInfo.day) {
    let takenAt = null;
    if (exif && exif.day === pathInfo.day) {
      takenAt = exif.takenAt;
    } else if (fileDate && fileDate.day === pathInfo.day && fileDate.takenAt) {
      takenAt = fileDate.takenAt;
    } else if (mtimeDay === pathInfo.day) {
      takenAt = stat.mtime.toISOString();
    }
    return { photoDate: pathInfo.day, takenAt };
  }

  if (exif) {
    return { photoDate: exif.day, takenAt: exif.takenAt };
  }

  if (fileDate) {
    const takenAt =
      fileDate.takenAt || (mtimeDay === fileDate.day ? stat.mtime.toISOString() : null);
    return { photoDate: fileDate.day, takenAt };
  }

  if (pathInfo.year && stat.mtime.getFullYear() !== pathInfo.year) {
    return { photoDate: `${pathInfo.year}-01-01`, takenAt: null };
  }

  return {
    photoDate: mtimeDay,
    takenAt: stat.mtime.toISOString(),
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
    this.writePromise = Promise.resolve();
    this.syncPromise = null;
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
            if (this.shouldExcludePath && this.shouldExcludePath(relSlash, false)) {
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
        if (this.shouldExcludePath && relSlash && this.shouldExcludePath(relSlash, false)) {
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
            if (!entry.diskHash && entry.storageType !== 's3' && (!entry.photoDate || !entry.takenAt)) {
              const inferred = await inferDiskMediaDates(
                entry.relativePath,
                entry.originalName || path.basename(fullPath),
                stat,
                fullPath
              );
              if (inferred.photoDate && entry.photoDate !== inferred.photoDate) {
                entry.photoDate = inferred.photoDate;
                changed = true;
              }
              if (inferred.takenAt && !entry.takenAt) {
                entry.takenAt = inferred.takenAt;
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
    for (const pHash of record.proxyHashes) {
      this.proxyToMaster.set(pHash, normMaster);
    }
    await this.persist();
    return record;
  }

  /**
   * Marks or clears whether a master photo was intentionally restored on device and should
   * not be re-proxied or auto-deleted by background/batch compression.
   */
  async setOriginalProtected(masterHash, keepOriginal = true) {
    const lookupResult = await this.lookup(masterHash, { allowStatFastPath: true });
    if (lookupResult.status === 'missing' || !lookupResult.record) {
      return null;
    }
    const normMaster = (lookupResult.masterHash || String(masterHash || '')).trim().toLowerCase();
    const record = this.records.get(normMaster) || lookupResult.record;
    record.keepOriginalOnDevice = Boolean(keepOriginal);
    record.originalProtectedAt = keepOriginal ? new Date().toISOString() : null;
    this.records.set(normMaster, record);
    await this.persist();
    return record;
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
    if (removedCount > 0 && persist) {
      await this.persist();
    }
    return removedCount;
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
      hasProxy: Boolean(entry.proxyHash || entry.proxyRelativePath),
      hasPreview: Boolean(entry.proxyRelativePath),
      proxyHash: entry.proxyHash || null,
      proxySize: entry.proxySize || null,
      hasVideoProxy: Boolean(entry.videoProxyRelativePath),
      videoProxySize: entry.videoProxySize || null,
      keepOriginalOnDevice: Boolean(entry.keepOriginalOnDevice),
    };
  }

  _getUniqueMasterRecords() {
    const seenPaths = new Set();
    const list = [];
    for (const [key, entry] of this.records.entries()) {
      if (!entry || !entry.relativePath) continue;
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
    let mastersBytes = 0;
    let proxiesBytes = 0;
    const unique = this._getUniqueMasterRecords();
    for (const { entry } of unique) {
      mastersBytes += Number(entry.size) || 0;
      proxiesBytes += Number(entry.proxySize) || 0;
      proxiesBytes += Number(entry.videoProxySize) || 0;
    }
    return {
      itemCount: unique.length,
      mastersBytes,
      proxiesBytes,
      usedBytes: mastersBytes + proxiesBytes,
    };
  }

  /**
   * Returns a deduplicated list of backed-up master photo records, sorted newest first
   * by capture day, full capture timestamp (`takenAt`), and upload timestamp.
   */
  listMasters() {
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
