/**
 * PHOTO STORAGE & SHA-256 VERIFICATION SERVICE
 *
 * Where this belongs: `src/services/storageService.js` (Service Layer).
 * Called by: `src/controllers/uploadController.js` (`uploadDirect`, `presignUpload`, `confirmUpload`).
 * Uses: `models/hashIndexModel.js` (`computeBufferSha256`, `computeFileSha256`, `hashIndex.lookup`/`set`).
 * Where files go on disk:
 *   Writes uploaded originals into `<storageDir>/<YYYY>/<YYYY-MM-DD>/<filename>`, reads the saved
 *   file back from disk to double-check its SHA-256 hash, and only then returns `canDelete: true`.
 */

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { computeBufferSha256, computeFileSha256 } = require('../models/hashIndexModel');
const {
  EXIF_SCHEMA_VERSION,
  parseMediaExifFromBuffer,
  readMediaExifMetadata,
  normalizeGpsCoords,
  reverseGeocodeOffline,
} = require('./exifGeoService');

function resolveGeoFields({ exifMeta, gpsLat, gpsLng, locationLabel }) {
  const clientCoords = normalizeGpsCoords(gpsLat, gpsLng);
  const resolvedLat = clientCoords
    ? clientCoords.gpsLat
    : exifMeta && typeof exifMeta.gpsLat === 'number'
      ? exifMeta.gpsLat
      : null;
  const resolvedLng = clientCoords
    ? clientCoords.gpsLng
    : exifMeta && typeof exifMeta.gpsLng === 'number'
      ? exifMeta.gpsLng
      : null;
  const cleanLabel = locationLabel ? String(locationLabel).trim().slice(0, 120) : '';
  const resolvedLabel =
    cleanLabel ||
    (exifMeta && exifMeta.locationLabel) ||
    (resolvedLat !== null && resolvedLng !== null ? reverseGeocodeOffline(resolvedLat, resolvedLng) : null);
  return {
    cameraModel: (exifMeta && exifMeta.cameraModel) || null,
    gpsLat: resolvedLat,
    gpsLng: resolvedLng,
    locationLabel: resolvedLabel,
  };
}

const MIME_EXT_MAP = {
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/png': '.png',
  'image/heic': '.heic',
  'image/heif': '.heif',
  'image/webp': '.webp',
  'image/gif': '.gif',
  'video/quicktime': '.mov',
  'video/mp4': '.mp4',
};

function sanitizeFilename(rawName, mimeType, fallbackHash) {
  let base = path.basename(String(rawName || '').trim());
  // Replace characters unsafe across Linux/macOS/Windows/FUSE filesystems
  base = base.replace(/[<>:"/\\|?*\x00-\x1F]/g, '_');

  if (!base || base === '.' || base === '..') {
    const ext = MIME_EXT_MAP[String(mimeType || '').toLowerCase()] || '.jpg';
    return `IMG_${fallbackHash.slice(0, 8).toUpperCase()}${ext}`;
  }

  if (!path.extname(base)) {
    const ext = MIME_EXT_MAP[String(mimeType || '').toLowerCase()] || '.jpg';
    base = `${base}${ext}`;
  }

  return base;
}

function parseDateFolder(rawDate) {
  let date = new Date();
  let hasExplicitTime = true;
  if (rawDate !== undefined && rawDate !== null && String(rawDate).trim() !== '') {
    const rawStr = String(rawDate).trim();
    const ymdMatch = rawStr.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (ymdMatch) {
      const y = Number(ymdMatch[1]);
      const m = Number(ymdMatch[2]);
      const d = Number(ymdMatch[3]);
      date = new Date(y, m - 1, d, 12, 0, 0, 0);
      hasExplicitTime = false;
    } else {
      const parsed = new Date(rawStr);
      if (!Number.isNaN(parsed.getTime())) {
        date = parsed;
      }
    }
  }
  const yyyy = String(date.getFullYear());
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const dd = String(date.getDate()).padStart(2, '0');
  return {
    year: yyyy,
    dateFolder: `${yyyy}-${mm}-${dd}`,
    dateObj: date,
    takenAt: hasExplicitTime ? date.toISOString() : null,
  };
}

const TRANSIENT_LOCK_CODES = new Set(['EBUSY', 'EPERM', 'EACCES']);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function renameWithRetry(srcPath, destPath, maxAttempts = 6) {
  let lastErr = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await fsp.rename(srcPath, destPath);
      return;
    } catch (err) {
      lastErr = err;
      if (!err || !TRANSIENT_LOCK_CODES.has(err.code) || attempt === maxAttempts) {
        throw err;
      }
      // Retry briefly when Windows Defender / Docker VirtioFS/9p holds a lock on newly written video files
      await sleep(120 * attempt);
    }
  }
  if (lastErr) throw lastErr;
}

async function ensureTargetDateDir(storageDir, year, dateFolder) {
  try {
    await fsp.mkdir(storageDir, { recursive: true });
  } catch (err) {
    if (err.code !== 'EEXIST') {
      console.warn(`[storage] Warning: could not ensure base storageDir ${storageDir}:`, err.message);
    }
  }

  const targetDir = path.join(storageDir, year, dateFolder);
  try {
    await fsp.mkdir(targetDir, { recursive: true });
  } catch {
    // If recursive mkdir failed (e.g. FUSE/rclone mounts failing on multi-level creation), create each step sequentially
    const yearDir = path.join(storageDir, year);
    await fsp.mkdir(yearDir, { recursive: true }).catch(() => {});
    await fsp.mkdir(targetDir, { recursive: true });
  }
  return targetDir;
}

async function resolveUniqueTargetPath(targetDir, safeName, actualHash) {
  const ext = path.extname(safeName);
  const stem = path.basename(safeName, ext);
  let finalFileName = safeName;
  let targetPath = path.join(targetDir, finalFileName);

  try {
    const existingStat = await fsp.stat(targetPath);
    if (existingStat.isFile()) {
      const existingDiskHash = await computeFileSha256(targetPath);
      if (existingDiskHash !== actualHash) {
        finalFileName = `${stem}_${actualHash.slice(0, 8)}${ext}`;
        targetPath = path.join(targetDir, finalFileName);
      }
    }
  } catch {
    // Target path does not exist yet
  }

  return { finalFileName, targetPath };
}

/**
 * Writes buffer to targetPath atomically when supported by the filesystem,
 * with Windows Defender / WSL2 lock retries and FUSE fallback.
 */
async function writePhotoFile(targetDir, targetPath, finalFileName, buffer) {
  const tmpPath = path.join(
    targetDir,
    `.${finalFileName}.${crypto.randomBytes(4).toString('hex')}.tmp`
  );

  try {
    const fileHandle = await fsp.open(tmpPath, 'w');
    try {
      await fileHandle.writeFile(buffer);
    } finally {
      await fileHandle.close();
    }
    await renameWithRetry(tmpPath, targetPath);
  } catch (err) {
    await fsp.unlink(tmpPath).catch(() => {});
    // Fallback to direct write if FUSE mount does not support atomic rename
    await fsp.writeFile(targetPath, buffer);
  }
}

function assertWithinQuota(hashIndex, quotaBytes, incomingBytes = 0) {
  const limit = Number(quotaBytes) || 0;
  if (limit <= 0) return null;
  const usage = hashIndex.getStorageUsage();
  if (usage.usedBytes + (Number(incomingBytes) || 0) > limit) {
    const err = new Error('Storage quota exceeded. Free up space or increase your storage limit.');
    err.statusCode = 507;
    err.storage = {
      ...usage,
      quotaBytes: limit,
      remainingBytes: Math.max(0, limit - usage.usedBytes),
    };
    throw err;
  }
  return usage;
}

async function assertMinimumFreeDisk(storageDir, minFreeDiskBytes, incomingBytes = 0) {
  const minFree = Number(minFreeDiskBytes) || 0;
  if (minFree <= 0 || typeof fsp.statfs !== 'function') return;
  try {
    await fsp.mkdir(storageDir, { recursive: true });
    const fsStats = await fsp.statfs(storageDir);
    const blockSize = Number(fsStats.bsize) || 4096;
    const diskFreeBytes = (Number(fsStats.bavail) || 0) * blockSize;
    if (diskFreeBytes - (Number(incomingBytes) || 0) < minFree) {
      const err = new Error('Server disk free space is below the safety reserve.');
      err.statusCode = 507;
      throw err;
    }
  } catch (err) {
    if (err.statusCode === 507) throw err;
  }
}

const PROXY_FILENAME_PREFIX_RE = /^PHOTOHUB_PROXY_([a-f0-9]{8,64})/i;
const PROXY_MARKER_RE = /PhotoHubProxy:([a-f0-9]{16,64})/i;
const inFlightUploadLocks = new Map();

/**
 * Serializes concurrent uploads of the exact same `(storageDir, sha256)` so simultaneous
 * requests from multiple devices/tabs deduplicate cleanly instead of racing on disk.
 */
async function withUploadHashLock(lockKey, fn) {
  const prev = inFlightUploadLocks.get(lockKey) || Promise.resolve();
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const tail = prev.then(() => gate, () => gate);
  inFlightUploadLocks.set(lockKey, tail);
  await prev.catch(() => {});
  try {
    return await fn();
  } finally {
    release();
    if (inFlightUploadLocks.get(lockKey) === tail) {
      inFlightUploadLocks.delete(lockKey);
    }
  }
}

async function readHeadAndTailSamples(filePath, sampleLimit = 256 * 1024) {
  let fh;
  try {
    fh = await fsp.open(filePath, 'r');
    const stat = await fh.stat();
    const size = stat.size || 0;
    if (size <= 0) return { head: Buffer.alloc(0), tail: Buffer.alloc(0) };
    const headLen = Math.min(size, sampleLimit);
    const head = Buffer.alloc(headLen);
    await fh.read(head, 0, headLen, 0);
    if (size <= sampleLimit) {
      return { head, tail: Buffer.alloc(0) };
    }
    const tailLen = Math.min(size - headLen, sampleLimit);
    const tail = Buffer.alloc(tailLen);
    await fh.read(tail, 0, tailLen, size - tailLen);
    return { head, tail };
  } catch {
    return { head: Buffer.alloc(0), tail: Buffer.alloc(0) };
  } finally {
    if (fh) await fh.close().catch(() => {});
  }
}

function extractProxyHintHex(originalName, headBuf, tailBuf) {
  const base = path.basename(String(originalName || '').trim());
  const nameMatch = base.match(PROXY_FILENAME_PREFIX_RE);
  if (nameMatch && nameMatch[1]) {
    return nameMatch[1].toLowerCase();
  }
  for (const buf of [headBuf, tailBuf]) {
    if (!Buffer.isBuffer(buf) || buf.length === 0) continue;
    const latin = buf.toString('latin1');
    const markerMatch = latin.match(PROXY_MARKER_RE);
    if (markerMatch && markerMatch[1]) {
      return markerMatch[1].toLowerCase();
    }
  }
  return null;
}

async function detectUploadedProxyMaster({ originalName, headBuf, tailBuf, hashIndex }) {
  if (!hashIndex || typeof hashIndex.findByMasterHashPrefix !== 'function') return null;
  const hintHex = extractProxyHintHex(originalName, headBuf, tailBuf);
  if (!hintHex) return null;
  return hashIndex.findByMasterHashPrefix(hintHex);
}

/**
 * Stores a photo buffer into STORAGE_DIR/YYYY/YYYY-MM-DD/<filename>,
 * verifies its SHA-256 on disk, and updates the HashIndex.
 * Works regardless of whether the Apple Shortcut includes a Delete step or Hash step.
 */
async function storeAndVerifyPhoto({
  buffer,
  originalName,
  mimeType,
  createdAt,
  expectedHash,
  strictChecksum = false,
  storageDir,
  hashIndex,
  quotaBytes = 0,
  minFreeDiskBytes = 0,
  gpsLat = null,
  gpsLng = null,
  locationLabel = null,
}) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) {
    const err = new Error('Uploaded photo buffer is empty');
    err.statusCode = 400;
    throw err;
  }

  const actualHash = computeBufferSha256(buffer);
  const cleanClientHash =
    expectedHash && typeof expectedHash === 'string'
      ? expectedHash.trim().toLowerCase()
      : '';

  if (strictChecksum && cleanClientHash && actualHash !== cleanClientHash) {
    const err = new Error(
      `Checksum mismatch: expected ${cleanClientHash}, got ${actualHash}`
    );
    err.statusCode = 422;
    throw err;
  }

  return withUploadHashLock(`${storageDir}|${actualHash}`, async () => {
    // 1. Proxy guard: never store a known proxy hash or PhotoHub-tagged compressed proxy as a new master original
    const proxyCheck = await hashIndex.lookup(actualHash, { allowStatFastPath: true });
    if (proxyCheck.status === 'proxy' && proxyCheck.record) {
      return {
        success: true,
        backedUp: true,
        canDelete: false,
        canReplaceWithProxy: false,
        checksumVerified: false,
        isDuplicate: true,
        isProxy: true,
        status: 'existing_proxy',
        message: 'Uploaded bytes match an existing compressed proxy; master is already stored.',
        hash: actualHash,
        masterHash: proxyCheck.masterHash,
        serverSha256: proxyCheck.masterHash,
        savedPath: proxyCheck.record.relativePath,
        originalName: proxyCheck.record.originalName,
        size: proxyCheck.record.size,
      };
    }

    const headSample = buffer.subarray(0, Math.min(buffer.length, 256 * 1024));
    const tailSample =
      buffer.length > 256 * 1024
        ? buffer.subarray(Math.max(256 * 1024, buffer.length - 256 * 1024))
        : Buffer.alloc(0);
    const taggedProxyMaster = await detectUploadedProxyMaster({
      originalName,
      headBuf: headSample,
      tailBuf: tailSample,
      hashIndex,
    });
    if (taggedProxyMaster && taggedProxyMaster.record) {
      return {
        success: true,
        backedUp: true,
        canDelete: false,
        canReplaceWithProxy: false,
        checksumVerified: false,
        isDuplicate: true,
        isProxy: true,
        status: 'existing_proxy',
        message: 'Uploaded file is a PhotoHub compressed proxy; full original is already stored.',
        hash: actualHash,
        masterHash: taggedProxyMaster.masterHash,
        serverSha256: taggedProxyMaster.masterHash,
        savedPath: taggedProxyMaster.record.relativePath,
        originalName: taggedProxyMaster.record.originalName,
        size: taggedProxyMaster.record.size,
      };
    }

    // 2. Duplicate check: check both actual uploaded file hash and optional client hash
    const existingRecord =
      (await hashIndex.verifyExisting(actualHash)) ||
      (!strictChecksum && cleanClientHash
        ? await hashIndex.verifyExisting(cleanClientHash)
        : null);

    if (existingRecord) {
      // Also alias cleanClientHash if not yet recorded so future /api/check/:hash calls hit immediately
      if (cleanClientHash && cleanClientHash !== existingRecord.hash) {
        await hashIndex.set(cleanClientHash, existingRecord);
      }
      const isProtectedOriginal = Boolean(existingRecord.keepOriginalOnDevice);
      return {
        success: true,
        backedUp: true,
        canDelete: !isProtectedOriginal,
        canReplaceWithProxy: !isProtectedOriginal,
        isProtectedOriginal,
        keepOriginalOnDevice: isProtectedOriginal,
        checksumVerified: true,
        isDuplicate: true,
        status: 'duplicate_verified',
        message:
          'Photo already exists on server and passed disk verification.',
        hash: actualHash,
        serverSha256: actualHash,
        savedPath: existingRecord.relativePath,
        originalName: existingRecord.originalName,
        size: existingRecord.size,
        photoDate: existingRecord.photoDate,
      };
    }

    assertWithinQuota(hashIndex, quotaBytes, buffer.length);
    await assertMinimumFreeDisk(storageDir, minFreeDiskBytes, buffer.length);

    // 2. Extract EXIF/GPS/date metadata (JPEG, HEIC/HEIF, MOV/MP4, PNG, WebP, TIFF) and determine date folder
    const exifMeta = parseMediaExifFromBuffer(buffer);
    const effectiveCreatedAt =
      createdAt !== undefined && createdAt !== null && String(createdAt).trim() !== ''
        ? createdAt
        : (exifMeta && (exifMeta.takenAt || exifMeta.day)) || '';
    const { year, dateFolder, dateObj, takenAt } = parseDateFolder(effectiveCreatedAt);
    const geo = resolveGeoFields({ exifMeta, gpsLat, gpsLng, locationLabel });
    const safeName = sanitizeFilename(originalName, mimeType, actualHash);
    const targetDir = await ensureTargetDateDir(storageDir, year, dateFolder);
    const { finalFileName, targetPath } = await resolveUniqueTargetPath(targetDir, safeName, actualHash);

    // 3. Write to storage (supports both local Linux/Windows disks and Ubuntu gdrive FUSE mounts)
    await writePhotoFile(targetDir, targetPath, finalFileName, buffer);

    // Preserve original photo timestamp on the file if supported
    try {
      await fsp.utimes(targetPath, dateObj, dateObj);
    } catch {
      // Ignore timestamp errors on FUSE/gdrive filesystems
    }

    // 4. Read back the saved file from disk and verify SHA-256 & byte size
    const writtenStat = await fsp.stat(targetPath);
    const diskHash = await computeFileSha256(targetPath);

    if (writtenStat.size !== buffer.length || diskHash !== actualHash) {
      await fsp.unlink(targetPath).catch(() => {});
      const err = new Error('Disk verification failed after writing file');
      err.statusCode = 500;
      throw err;
    }

    const relativePath = path
      .relative(storageDir, targetPath)
      .split(path.sep)
      .join('/');

    const entryData = {
      hash: actualHash,
      diskHash: actualHash,
      relativePath,
      originalName: finalFileName,
      size: writtenStat.size,
      mtimeMs: writtenStat.mtimeMs,
      photoDate: dateFolder,
      takenAt: takenAt || (exifMeta && exifMeta.takenAt) || null,
      cameraModel: geo.cameraModel,
      gpsLat: geo.gpsLat,
      gpsLng: geo.gpsLng,
      locationLabel: geo.locationLabel,
      _exifScanned: true,
      _exifVersion: EXIF_SCHEMA_VERSION,
      uploadedAt: new Date().toISOString(),
    };

    const record = await hashIndex.set(actualHash, entryData);

    // If iOS Shortcut generated a pre-transcode hash (e.g. HEIC hash before iOS converted to JPEG),
    // index that client hash too so /api/check/:hash recognizes it on future runs!
    if (cleanClientHash && cleanClientHash !== actualHash) {
      await hashIndex.set(cleanClientHash, entryData);
    }

    return {
      success: true,
      backedUp: true,
      canDelete: true,
      canReplaceWithProxy: true,
      checksumVerified: true,
      isDuplicate: false,
      status: 'stored_verified',
      message: 'Photo backed up and verified on disk.',
      hash: actualHash,
      serverSha256: actualHash,
      savedPath: record.relativePath,
      originalName: record.originalName,
      size: record.size,
      photoDate: record.photoDate,
      locationLabel: record.locationLabel || null,
      gpsLat: record.gpsLat,
      gpsLng: record.gpsLng,
    };
  });
}

/**
 * Finalizes an already-staged upload file on disk (used by both raw streaming uploads and
 * resumable chunked 4K video uploads): enforces strict checksum, proxy/duplicate guards,
 * quota/disk limits, moves to YYYY/YYYY-MM-DD, verifies disk SHA-256, extracts EXIF/GPS,
 * and registers in `hashIndex`.
 */
async function finalizeStagedUpload({
  stagingPath,
  totalBytes,
  actualHash,
  originalName,
  mimeType,
  createdAt,
  expectedHash,
  strictChecksum = false,
  storageDir,
  hashIndex,
  quotaBytes = 0,
  minFreeDiskBytes = 0,
  gpsLat = null,
  gpsLng = null,
  locationLabel = null,
}) {
  const cleanClientHash =
    expectedHash && typeof expectedHash === 'string'
      ? expectedHash.trim().toLowerCase()
      : '';

  if (strictChecksum && cleanClientHash && actualHash !== cleanClientHash) {
    const err = new Error(
      `Checksum mismatch: expected ${cleanClientHash}, got ${actualHash}`
    );
    err.statusCode = 422;
    throw err;
  }

  return withUploadHashLock(`${storageDir}|${actualHash}`, async () => {
    const proxyCheck = await hashIndex.lookup(actualHash, { allowStatFastPath: true });
    if (proxyCheck.status === 'proxy' && proxyCheck.record) {
      await fsp.unlink(stagingPath).catch(() => {});
      return {
        success: true,
        backedUp: true,
        canDelete: false,
        canReplaceWithProxy: false,
        checksumVerified: false,
        isDuplicate: true,
        isProxy: true,
        status: 'existing_proxy',
        message: 'Uploaded bytes match an existing compressed proxy; master is already stored.',
        hash: actualHash,
        masterHash: proxyCheck.masterHash,
        serverSha256: proxyCheck.masterHash,
        savedPath: proxyCheck.record.relativePath,
        originalName: proxyCheck.record.originalName,
        size: proxyCheck.record.size,
      };
    }

    const { head, tail } = await readHeadAndTailSamples(stagingPath);
    const taggedProxyMaster = await detectUploadedProxyMaster({
      originalName,
      headBuf: head,
      tailBuf: tail,
      hashIndex,
    });
    if (taggedProxyMaster && taggedProxyMaster.record) {
      await fsp.unlink(stagingPath).catch(() => {});
      return {
        success: true,
        backedUp: true,
        canDelete: false,
        canReplaceWithProxy: false,
        checksumVerified: false,
        isDuplicate: true,
        isProxy: true,
        status: 'existing_proxy',
        message: 'Uploaded file is a PhotoHub compressed proxy; full original is already stored.',
        hash: actualHash,
        masterHash: taggedProxyMaster.masterHash,
        serverSha256: taggedProxyMaster.masterHash,
        savedPath: taggedProxyMaster.record.relativePath,
        originalName: taggedProxyMaster.record.originalName,
        size: taggedProxyMaster.record.size,
      };
    }

    const existingRecord =
      (await hashIndex.verifyExisting(actualHash)) ||
      (!strictChecksum && cleanClientHash
        ? await hashIndex.verifyExisting(cleanClientHash)
        : null);

    if (existingRecord) {
      await fsp.unlink(stagingPath).catch(() => {});
      if (cleanClientHash && cleanClientHash !== existingRecord.hash) {
        await hashIndex.set(cleanClientHash, existingRecord);
      }
      const isProtectedOriginal = Boolean(existingRecord.keepOriginalOnDevice);
      return {
        success: true,
        backedUp: true,
        canDelete: !isProtectedOriginal,
        canReplaceWithProxy: !isProtectedOriginal,
        isProtectedOriginal,
        keepOriginalOnDevice: isProtectedOriginal,
        checksumVerified: true,
        isDuplicate: true,
        status: 'duplicate_verified',
        message: 'Photo already exists on server and passed disk verification.',
        hash: actualHash,
        serverSha256: actualHash,
        savedPath: existingRecord.relativePath,
        originalName: existingRecord.originalName,
        size: existingRecord.size,
        photoDate: existingRecord.photoDate,
      };
    }

    assertWithinQuota(hashIndex, quotaBytes, totalBytes);
    await assertMinimumFreeDisk(storageDir, minFreeDiskBytes, totalBytes);

    const exifMeta =
      (await readMediaExifMetadata(stagingPath)) ||
      parseMediaExifFromBuffer(head);
    const effectiveCreatedAt =
      createdAt !== undefined && createdAt !== null && String(createdAt).trim() !== ''
        ? createdAt
        : (exifMeta && (exifMeta.takenAt || exifMeta.day)) || '';
    const { year, dateFolder, dateObj, takenAt } = parseDateFolder(effectiveCreatedAt);
    const geo = resolveGeoFields({ exifMeta, gpsLat, gpsLng, locationLabel });
    const safeName = sanitizeFilename(originalName, mimeType, actualHash);
    const targetDir = await ensureTargetDateDir(storageDir, year, dateFolder);
    const { finalFileName, targetPath } = await resolveUniqueTargetPath(targetDir, safeName, actualHash);

    try {
      await renameWithRetry(stagingPath, targetPath);
    } catch {
      await fsp.copyFile(stagingPath, targetPath);
      await fsp.unlink(stagingPath).catch(() => {});
    }

    try {
      await fsp.utimes(targetPath, dateObj, dateObj);
    } catch {
      // Ignore timestamp errors on FUSE mounts
    }

    const writtenStat = await fsp.stat(targetPath);
    const diskHash = await computeFileSha256(targetPath);
    if (writtenStat.size !== totalBytes || diskHash !== actualHash) {
      await fsp.unlink(targetPath).catch(() => {});
      const err = new Error('Disk verification failed after writing file');
      err.statusCode = 500;
      throw err;
    }

    const relativePath = path
      .relative(storageDir, targetPath)
      .split(path.sep)
      .join('/');

    const entryData = {
      hash: actualHash,
      diskHash: actualHash,
      relativePath,
      originalName: finalFileName,
      size: writtenStat.size,
      mtimeMs: writtenStat.mtimeMs,
      photoDate: dateFolder,
      takenAt: takenAt || (exifMeta && exifMeta.takenAt) || null,
      cameraModel: geo.cameraModel,
      gpsLat: geo.gpsLat,
      gpsLng: geo.gpsLng,
      locationLabel: geo.locationLabel,
      _exifScanned: true,
      _exifVersion: EXIF_SCHEMA_VERSION,
      uploadedAt: new Date().toISOString(),
    };

    const record = await hashIndex.set(actualHash, entryData);
    if (cleanClientHash && cleanClientHash !== actualHash) {
      await hashIndex.set(cleanClientHash, entryData);
    }

    return {
      success: true,
      backedUp: true,
      canDelete: true,
      canReplaceWithProxy: true,
      checksumVerified: true,
      isDuplicate: false,
      status: 'stored_verified',
      message: 'Photo backed up and verified on disk.',
      hash: actualHash,
      serverSha256: actualHash,
      savedPath: record.relativePath,
      originalName: record.originalName,
      size: record.size,
      photoDate: record.photoDate,
      locationLabel: record.locationLabel || null,
      gpsLat: record.gpsLat,
      gpsLng: record.gpsLng,
    };
  });
}

/**
 * Streams a raw binary upload directly into a temporary file inside `storageDir` while
 * computing SHA-256 on the fly — preventing 100MB+–multi-GB video RAM spikes and post-100% HDD stalls.
 */
async function storeAndVerifyStream({
  req,
  originalName,
  mimeType,
  createdAt,
  expectedHash,
  strictChecksum = false,
  storageDir,
  hashIndex,
  quotaBytes = 0,
  minFreeDiskBytes = 0,
  maxFileSizeBytes = 0,
  gpsLat = null,
  gpsLng = null,
  locationLabel = null,
}) {
  if (req && req.socket && typeof req.socket.setTimeout === 'function') {
    req.socket.setTimeout(0);
  }
  await fsp.mkdir(storageDir, { recursive: true });

  const declaredLen = Number(req.headers && req.headers['content-length']);
  if (maxFileSizeBytes > 0 && Number.isFinite(declaredLen) && declaredLen > maxFileSizeBytes) {
    const err = new Error('Uploaded file exceeds maximum upload size');
    err.statusCode = 413;
    throw err;
  }

  const stagingPath = path.join(
    storageDir,
    `.upload_${process.pid}_${Date.now()}_${crypto.randomBytes(4).toString('hex')}.tmp`
  );

  let totalBytes = 0;
  let streamCompleted = false;
  const hasher = crypto.createHash('sha256');

  try {
    await new Promise((resolve, reject) => {
      const ws = fs.createWriteStream(stagingPath, { highWaterMark: 256 * 1024 });
      let settled = false;
      const fail = (err) => {
        if (settled) return;
        settled = true;
        req.unpipe(ws);
        ws.destroy();
        reject(err);
      };

      const onAborted = () => {
        const abortErr = new Error('request aborted');
        abortErr.statusCode = 400;
        fail(abortErr);
      };

      ws.on('error', fail);
      req.on('aborted', onAborted);
      req.on('error', fail);
      req.on('close', () => {
        if (!settled && !req.complete) {
          onAborted();
        }
      });
      req.on('data', (chunk) => {
        totalBytes += chunk.length;
        if (maxFileSizeBytes > 0 && totalBytes > maxFileSizeBytes) {
          const err = new Error('Uploaded file exceeds maximum upload size');
          err.statusCode = 413;
          fail(err);
          return;
        }
        hasher.update(chunk);
      });
      ws.on('finish', () => {
        if (settled) return;
        settled = true;
        streamCompleted = true;
        resolve();
      });
      req.pipe(ws);
    });

    if (!streamCompleted || totalBytes === 0) {
      const err = new Error(
        'No photo file received. In Apple Shortcuts, use "Form" with a File field named "photo" or "File" request body.'
      );
      err.statusCode = 400;
      throw err;
    }

    const actualHash = hasher.digest('hex');
    return await finalizeStagedUpload({
      stagingPath,
      totalBytes,
      actualHash,
      originalName,
      mimeType,
      createdAt,
      expectedHash,
      strictChecksum,
      storageDir,
      hashIndex,
      quotaBytes,
      minFreeDiskBytes,
      gpsLat,
      gpsLng,
      locationLabel,
    });
  } catch (err) {
    await fsp.unlink(stagingPath).catch(() => {});
    throw err;
  }
}

module.exports = {
  storeAndVerifyPhoto,
  storeAndVerifyStream,
  finalizeStagedUpload,
  assertWithinQuota,
  sanitizeFilename,
  parseDateFolder,
};
