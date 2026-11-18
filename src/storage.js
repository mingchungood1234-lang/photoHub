const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { computeBufferSha256, computeFileSha256 } = require('./hashIndex');

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
  if (rawDate) {
    const parsed = new Date(rawDate);
    if (!Number.isNaN(parsed.getTime())) {
      date = parsed;
    }
  }
  const yyyy = String(date.getFullYear());
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const dd = String(date.getDate()).padStart(2, '0');
  return {
    year: yyyy,
    dateFolder: `${yyyy}-${mm}-${dd}`,
    dateObj: date,
  };
}

/**
 * Writes buffer to targetPath atomically when supported by the filesystem,
 * with graceful fallback for Ubuntu FUSE mounts (e.g. rclone / google-drive-ocamlfuse).
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
      try {
        await fileHandle.sync();
      } catch {
        // Ignore ENOSYS / EINVAL on FUSE mounts (e.g. rclone mount)
      }
    } finally {
      await fileHandle.close();
    }
    await fsp.rename(tmpPath, targetPath);
  } catch (err) {
    await fsp.unlink(tmpPath).catch(() => {});
    // Fallback to direct write if FUSE mount does not support atomic rename
    await fsp.writeFile(targetPath, buffer);
  }
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

  // 1. Duplicate check: check both actual uploaded file hash and optional client hash
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
    return {
      success: true,
      backedUp: true,
      canDelete: true,
      canReplaceWithProxy: true,
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

  // 2. Determine date folder (YYYY/YYYY-MM-DD) and target filename
  const { year, dateFolder, dateObj } = parseDateFolder(createdAt);
  const safeName = sanitizeFilename(originalName, mimeType, actualHash);

  // Ensure base storage directory exists before creating subdirectories (especially important on remote / FUSE mounts)
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
  } catch (err) {
    // If recursive mkdir failed (e.g. FUSE/rclone mounts failing on multi-level creation), create each step sequentially
    const yearDir = path.join(storageDir, year);
    await fsp.mkdir(yearDir, { recursive: true }).catch(() => {});
    await fsp.mkdir(targetDir, { recursive: true });
  }

  // Avoid overwriting a different file that happens to share the same filename on the same date
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
  };
}

module.exports = {
  storeAndVerifyPhoto,
  sanitizeFilename,
  parseDateFolder,
};
