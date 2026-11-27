/**
 * SERVER GALLERY BROWSING & ORIGINAL DOWNLOAD CONTROLLER
 *
 * Where this belongs: `src/controllers/photoController.js`.
 * Called by: `src/routes/photoRoutes.js` (all protected by `authMiddleware`):
 *   - `listPhotos`         (`GET /api/photos` — returns sorted timeline list w/ year, mediaType, prefix filters & gzip)
 *   - `streamPreview`      (`GET /api/photo/:hash/preview` — fast compressed JPEG preview for grid browsing)
 *   - `streamVideoProxy`   (`GET /api/photo/:hash/video-proxy` — lightweight MP4 video playback w/ Range seek)
 *   - `setProtectOriginal` (`POST /api/photo/:hash/protect-original` — marks restored originals safe from auto re-compression)
 *   - `deletePhoto`        (`DELETE /api/photo/:hash` — deletes master + server proxies from storage and HashIndex)
 *   - `deletePhotosBatch`  (`POST /api/photos/delete` / `DELETE /api/photos` — batch delete from storage and HashIndex)
 *   - `downloadMaster`     (`GET /api/photo/:hash` — full-resolution original via S3 302 redirect or Express `sendFile` HTTP 206 Ranges)
 * Calls: `req.userContext.hashIndex` (`models/hashIndexModel.js`) and `services/s3Service.js`.
 */

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const zlib = require('zlib');
const { promisify } = require('util');
const { isS3Configured, createPresignedUrl, deleteS3Object } = require('../services/s3Service');
const { isVideoFilename } = require('../services/proxyService');
const { buildMemories } = require('../services/memoryService');
const { buildCleanupSuggestions } = require('../services/mediaAnalysisService');
const {
  streamZipToResponse,
  createDiskReadStream,
  createHttpReadStream,
} = require('../services/zipStreamService');

const MAX_BATCH_DELETE_COUNT = 500;
const MAX_BATCH_PROTECT_COUNT = 1000;
const MAX_ZIP_ITEMS = 250;
const TRASH_RETENTION_DAYS = 30;
const TRASH_RETENTION_MS = TRASH_RETENTION_DAYS * 24 * 60 * 60 * 1000;
const STREAM_HIGH_WATER_MARK = 512 * 1024; // 512 KB read chunks for fast LAN/WAN/NAS original restores

const MEDIA_MIME_BY_EXT = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.heic': 'image/heic',
  '.heif': 'image/heif',
  '.avif': 'image/avif',
  '.bmp': 'image/bmp',
  '.tif': 'image/tiff',
  '.tiff': 'image/tiff',
  '.dng': 'image/x-adobe-dng',
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.mov': 'video/quicktime',
  '.3gp': 'video/3gpp',
  '.avi': 'video/x-msvideo',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm',
};

function inferMediaContentType(filePath) {
  const ext = path.extname(String(filePath || '')).toLowerCase();
  return MEDIA_MIME_BY_EXT[ext] || 'application/octet-stream';
}

function parseSingleByteRange(rangeHeader, fileSize) {
  if (!rangeHeader || typeof rangeHeader !== 'string') return null;
  const trimmed = rangeHeader.trim();
  if (!/^bytes=/i.test(trimmed)) return null;
  const spec = trimmed.slice(6).trim();
  // Multiple ranges (comma-separated) aren't used by our clients; treat as invalid/ignore
  if (!spec || spec.includes(',')) return null;
  const dashIdx = spec.indexOf('-');
  if (dashIdx < 0) return { invalid: true };
  const startStr = spec.slice(0, dashIdx).trim();
  const endStr = spec.slice(dashIdx + 1).trim();

  if (fileSize <= 0) return { invalid: true };

  if (startStr === '') {
    // Suffix range: bytes=-N
    const suffixLen = Number(endStr);
    if (!Number.isInteger(suffixLen) || suffixLen <= 0) return { invalid: true };
    const start = Math.max(0, fileSize - suffixLen);
    return { start, end: fileSize - 1 };
  }

  const start = Number(startStr);
  if (!Number.isInteger(start) || start < 0 || start >= fileSize) {
    return { invalid: true };
  }

  if (endStr === '') {
    return { start, end: fileSize - 1 };
  }

  const rawEnd = Number(endStr);
  if (!Number.isInteger(rawEnd) || rawEnd < start) {
    return { invalid: true };
  }
  const end = Math.min(fileSize - 1, rawEnd);
  return { start, end };
}

const MONTH_KEYWORDS = [
  ['january', 'jan'],
  ['february', 'feb'],
  ['march', 'mar'],
  ['april', 'apr'],
  ['may'],
  ['june', 'jun'],
  ['july', 'jul'],
  ['august', 'aug'],
  ['september', 'sept', 'sep'],
  ['october', 'oct'],
  ['november', 'nov'],
  ['december', 'dec'],
];

function matchesSmartSearchQuery(item, rawQuery) {
  const q = String(rawQuery || '').trim().toLowerCase();
  if (!q) return true;
  const tokens = q.split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return true;

  const isVid = isVideoFilename(item.originalName || item.savedPath || '');
  const dateStr = String(item.photoDate || (item.takenAt || '').slice(0, 10) || (item.uploadedAt || '').slice(0, 10));
  const monthNum = /^\d{4}-(\d{2})/.test(dateStr) ? Number(dateStr.slice(5, 7)) : 0;
  const monthNames = monthNum >= 1 && monthNum <= 12 ? MONTH_KEYWORDS[monthNum - 1] : [];

  const haystack = [
    item.originalName || '',
    item.photoDate || '',
    item.takenAt || '',
    item.savedPath || '',
    item.cameraModel || '',
    item.locationLabel || '',
    typeof item.gpsLat === 'number' && typeof item.gpsLng === 'number'
      ? `${item.gpsLat.toFixed(2)},${item.gpsLng.toFixed(2)} gps location map`
      : '',
    ...monthNames,
    isVid ? 'video videos movie clip' : 'photo photos image picture',
    item.isFavorite ? 'favorite favorites fav starred heart' : '',
    item.keepOriginalOnDevice ? 'protected restored original' : '',
  ]
    .join(' ')
    .toLowerCase();

  return tokens.every((tok) => haystack.includes(tok));
}

const gzipAsync = promisify(zlib.gzip);

async function fileExistsAsync(filePath) {
  try {
    await fsp.access(filePath, fs.constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

function acceptsGzip(req) {
  return /\bgzip\b/i.test(String((req.headers && req.headers['accept-encoding']) || ''));
}

async function sendJsonOptimized(req, res, payload) {
  const jsonStr = JSON.stringify(payload);
  if (jsonStr.length >= 1024 && acceptsGzip(req)) {
    const gz = await gzipAsync(Buffer.from(jsonStr, 'utf8'));
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Content-Encoding', 'gzip');
    res.setHeader('Vary', 'Accept-Encoding');
    res.setHeader('Content-Length', String(gz.length));
    return res.end(gz);
  }
  return res.type('application/json').send(jsonStr);
}

function sendImmutableMediaFile(
  res,
  filePath,
  { variant = null, masterHash, contentType = null, contentDisposition = null }
) {
  if (variant) res.setHeader('X-Photo-Variant', variant);
  if (masterHash) res.setHeader('X-Master-Sha256', masterHash);
  if (contentDisposition) res.setHeader('Content-Disposition', contentDisposition);

  const headers = {
    'Cache-Control': 'private, max-age=31536000, immutable',
    ...(contentType ? { 'Content-Type': contentType } : {}),
  };

  return res.sendFile(
    path.resolve(filePath),
    {
      dotfiles: 'allow',
      acceptRanges: true,
      cacheControl: false,
      etag: true,
      lastModified: true,
      headers,
    },
    (err) => {
      if (!err) return;
      if (
        err.code === 'ECONNABORTED' ||
        err.code === 'ECONNRESET' ||
        err.message === 'Request aborted'
      ) {
        return;
      }
      if (!res.headersSent) {
        const isNotFound = err.statusCode === 404 || err.code === 'ENOENT';
        res.status(isNotFound ? 404 : err.statusCode || 500).json({
          success: false,
          error: isNotFound ? 'Photo file not found on disk' : err.message,
        });
      }
    }
  );
}

/**
 * High-throughput direct file streamer for full-resolution original downloads (`GET /api/photo/:hash`).
 * Uses 512 KB `fs.createReadStream` chunks (8x larger than Express `sendFile`'s 64 KB default),
 * reuses the already-fetched `stat` (zero duplicate `stat` syscalls), enables `TCP_NODELAY`,
 * and serves full RFC 7233 HTTP 206 `Range` segments + `ETag` 304 + `HEAD`.
 */
async function streamImmutableFileFast(
  req,
  res,
  filePath,
  { stat = null, variant = null, masterHash = null, contentType = null, contentDisposition = null } = {}
) {
  const absPath = path.resolve(filePath);
  let fileStat = stat;
  if (!fileStat) {
    try {
      fileStat = await fsp.stat(absPath);
    } catch (err) {
      const isNotFound = err && err.code === 'ENOENT';
      return res.status(isNotFound ? 404 : 500).json({
        success: false,
        error: isNotFound ? 'Photo file not found on disk' : err.message,
      });
    }
  }

  if (req.socket && typeof req.socket.setNoDelay === 'function') {
    req.socket.setNoDelay(true);
  }

  const totalSize = Number(fileStat.size) || 0;
  const mtimeMs = Math.trunc(Number(fileStat.mtimeMs) || 0);
  const etag = `W/"${totalSize.toString(16)}-${mtimeMs.toString(16)}"`;
  const lastModified = new Date(fileStat.mtimeMs || Date.now()).toUTCString();

  res.setHeader('Accept-Ranges', 'bytes');
  res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
  res.setHeader('ETag', etag);
  res.setHeader('Last-Modified', lastModified);
  res.setHeader('Content-Type', contentType || inferMediaContentType(absPath));
  if (variant) res.setHeader('X-Photo-Variant', variant);
  if (masterHash) res.setHeader('X-Master-Sha256', masterHash);
  if (contentDisposition) res.setHeader('Content-Disposition', contentDisposition);

  const ifNoneMatch = String((req.headers && req.headers['if-none-match']) || '').trim();
  if (
    ifNoneMatch &&
    !req.headers.range &&
    (ifNoneMatch === etag || ifNoneMatch.split(',').map((s) => s.trim()).includes(etag))
  ) {
    return res.status(304).end();
  }

  let statusCode = 200;
  let start = 0;
  let end = totalSize > 0 ? totalSize - 1 : 0;

  if (req.headers && req.headers.range) {
    const parsed = parseSingleByteRange(req.headers.range, totalSize);
    if (parsed && parsed.invalid) {
      res.setHeader('Content-Range', `bytes */${totalSize}`);
      return res.status(416).end();
    }
    if (parsed) {
      statusCode = 206;
      start = parsed.start;
      end = parsed.end;
      res.setHeader('Content-Range', `bytes ${start}-${end}/${totalSize}`);
    }
  }

  const chunkLength = totalSize === 0 ? 0 : end - start + 1;
  res.setHeader('Content-Length', String(chunkLength));
  res.status(statusCode);

  if (req.method === 'HEAD' || chunkLength === 0) {
    return res.end();
  }

  return new Promise((resolve) => {
    const readStream = fs.createReadStream(absPath, {
      start,
      end,
      highWaterMark: STREAM_HIGH_WATER_MARK,
    });

    let finished = false;
    const done = () => {
      if (finished) return;
      finished = true;
      resolve();
    };

    const cleanup = () => {
      if (!readStream.destroyed) readStream.destroy();
      done();
    };

    res.on('close', cleanup);
    res.on('finish', done);

    readStream.on('error', (err) => {
      res.off('close', cleanup);
      if (!res.headersSent) {
        const isNotFound = err && err.code === 'ENOENT';
        res.status(isNotFound ? 404 : 500).json({
          success: false,
          error: isNotFound ? 'Photo file not found on disk' : err.message,
        });
      } else if (!res.writableEnded) {
        res.destroy(err);
      }
      done();
    });

    readStream.pipe(res);
  });
}

function createPhotoController({ config }) {
  async function lookupPhotoOr404(req, res, { includeTrashed = true, includeStat = false } = {}) {
    const { hashIndex } = req.userContext;
    const lookupResult = await hashIndex.lookup(req.params.hash, {
      allowStatFastPath: true,
      includeTrashed,
      includeStat,
    });
    if (lookupResult.status === 'missing' || !lookupResult.record) {
      res.status(404).json({
        success: false,
        error: 'Photo not found',
      });
      return null;
    }
    return lookupResult;
  }

  function redirectIfS3(res, record) {
    if (record.storageType !== 's3' || !isS3Configured(config.s3)) {
      return false;
    }
    const downloadUrl = createPresignedUrl({
      s3Config: config.s3,
      method: 'GET',
      objectKey: record.relativePath,
      expiresIn: 300,
    });
    res.redirect(downloadUrl);
    return true;
  }

  function resolveInsideStorageDir(storageDir, relativePath) {
    if (!relativePath || typeof relativePath !== 'string') return null;
    const root = path.resolve(storageDir);
    const resolved = path.resolve(root, relativePath);
    if (resolved !== root && !resolved.startsWith(root + path.sep)) {
      throw new Error('Unsafe relative path outside storage root');
    }
    return resolved;
  }

  async function unlinkIfExists(filePath) {
    if (!filePath) return;
    try {
      await fsp.unlink(filePath);
    } catch (err) {
      if (err && err.code !== 'ENOENT') {
        throw err;
      }
    }
  }

  async function pruneEmptyParentDirs(storageDir, deletedFilePath) {
    const root = path.resolve(storageDir);
    let current = path.dirname(path.resolve(deletedFilePath));
    while (current !== root && current.startsWith(root + path.sep)) {
      if (path.basename(current) === '.proxies') break;
      try {
        await fsp.rmdir(current);
      } catch {
        break;
      }
      current = path.dirname(current);
    }
  }

  async function deleteRecordFiles({ storageDir, record }) {
    if (!record) return 0;

    if (record.storageType === 's3') {
      if (record.relativePath && isS3Configured(config.s3)) {
        await deleteS3Object({
          s3Config: config.s3,
          objectKey: record.relativePath,
        });
      }
    } else if (record.relativePath) {
      const masterFullPath = resolveInsideStorageDir(storageDir, record.relativePath);
      if (masterFullPath) {
        await unlinkIfExists(masterFullPath);
        await pruneEmptyParentDirs(storageDir, masterFullPath);
      }
    }

    if (record.proxyRelativePath) {
      const proxyFullPath = resolveInsideStorageDir(storageDir, record.proxyRelativePath);
      await unlinkIfExists(proxyFullPath);
    }
    if (record.videoProxyRelativePath) {
      const videoProxyFullPath = resolveInsideStorageDir(storageDir, record.videoProxyRelativePath);
      await unlinkIfExists(videoProxyFullPath);
    }

    return (
      (Number(record.size) || 0) +
      (Number(record.proxySize) || 0) +
      (Number(record.videoProxySize) || 0)
    );
  }

  const lastTrashPurgeByIndex = new WeakMap();

  async function purgeExpiredTrashIfDue(hashIndex, storageDir, force = false) {
    const now = Date.now();
    const last = lastTrashPurgeByIndex.get(hashIndex) || 0;
    if (!force && now - last < 60 * 60 * 1000) return 0;
    lastTrashPurgeByIndex.set(hashIndex, now);

    const expired = hashIndex.getExpiredTrashRecords(TRASH_RETENTION_MS);
    if (expired.length === 0) return 0;

    const keysToRemove = new Set();
    let purgedCount = 0;
    for (const found of expired) {
      try {
        await deleteRecordFiles({ storageDir, record: found.record });
        for (const k of found.keys) keysToRemove.add(k);
        purgedCount += 1;
      } catch {
        // retry on next cycle
      }
    }
    if (keysToRemove.size > 0) {
      await hashIndex.removeKeys(Array.from(keysToRemove), { persist: true });
    }
    return purgedCount;
  }

  return {
    async listPhotos(req, res) {
      try {
        const { hashIndex, folderName, storageDir } = req.userContext;
        if (req.query.sync === '1' || req.query.sync === 'true') {
          await hashIndex.syncStorageDir();
        }
        await purgeExpiredTrashIfDue(hashIndex, storageDir, false);

        const limit = Math.min(1000, Math.max(1, Number(req.query.limit) || 200));
        const offset = Math.max(0, Number(req.query.offset) || 0);
        const yearParam = req.query.year ? String(req.query.year).trim() : '';
        const mediaTypeParam = req.query.mediaType ? String(req.query.mediaType).trim() : '';
        const prefixParam = req.query.prefix ? String(req.query.prefix).trim().toLowerCase() : '';
        const favoriteParam = req.query.favorite === '1' || req.query.favorite === 'true' ? '1' : '';
        const searchParam = req.query.q ? String(req.query.q).trim() : '';
        const orderParam = req.query.order === 'asc' ? 'asc' : 'desc';

        const etag = `W/"v${hashIndex.version || 1}-${hashIndex.size()}-${offset}-${limit}-${yearParam}-${mediaTypeParam}-${prefixParam}-${favoriteParam}-${encodeURIComponent(searchParam)}-${orderParam}"`;
        res.setHeader('ETag', etag);
        res.setHeader('Cache-Control', 'private, no-cache');
        const ifNoneMatch = String(req.headers['if-none-match'] || '').trim();
        if (ifNoneMatch && (ifNoneMatch === etag || ifNoneMatch.split(',').map((s) => s.trim()).includes(etag))) {
          return res.status(304).end();
        }

        let all = hashIndex.listMasters();
        const storageUsage = hashIndex.getStorageUsage();

        const yearCountsMap = new Map();
        for (const item of all) {
          if (item.year) {
            yearCountsMap.set(item.year, (yearCountsMap.get(item.year) || 0) + 1);
          }
        }
        const years = Array.from(yearCountsMap.entries())
          .sort((a, b) => b[0] - a[0])
          .map(([year, count]) => ({ year, count }));

        if (req.query.year && /^\d{4}$/.test(String(req.query.year).trim())) {
          const targetYear = Number(String(req.query.year).trim());
          all = all.filter((item) => item.year === targetYear);
        }
        if (req.query.mediaType === 'video' || req.query.mediaType === 'photo') {
          const wantVideo = req.query.mediaType === 'video';
          all = all.filter((item) => {
            const isVid = isVideoFilename(item.originalName || item.savedPath || '');
            return wantVideo ? isVid : !isVid;
          });
        }
        if (favoriteParam === '1') {
          all = all.filter((item) => Boolean(item.isFavorite));
        }
        if (searchParam) {
          all = all.filter((item) => matchesSmartSearchQuery(item, searchParam));
        }
        if (req.query.prefix && /^[0-9a-f]{8,64}$/i.test(String(req.query.prefix).trim())) {
          const targetPrefix = String(req.query.prefix).trim().toLowerCase();
          all = all.filter((item) => String(item.hash || '').toLowerCase().startsWith(targetPrefix));
        }
        if (req.query.order === 'asc') {
          all = all.slice().reverse();
        }

        const photos = all.slice(offset, offset + limit);
        return sendJsonOptimized(req, res, {
          success: true,
          userFolder: folderName,
          total: all.length,
          trashCount: storageUsage.trashItemCount || 0,
          hasMore: offset + photos.length < all.length,
          years,
          photos,
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async getMemories(req, res) {
      try {
        const { hashIndex } = req.userContext;
        const all = hashIndex.listMasters();
        const refDate = req.query.date ? String(req.query.date).trim() : null;
        const memories = buildMemories(all, { referenceDate: refDate });
        return sendJsonOptimized(req, res, {
          success: true,
          referenceDate: refDate || new Date().toISOString().slice(0, 10),
          memories,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async getPhotoMap(req, res) {
      try {
        const { hashIndex } = req.userContext;
        const all = hashIndex.listMasters();
        const geoPhotos = all.filter(
          (p) => typeof p.gpsLat === 'number' && typeof p.gpsLng === 'number'
        );

        // Cluster nearby photos (~0.15 deg grid cell ~ 15km) for snappy map markers
        const clusterMap = new Map();
        for (const p of geoPhotos) {
          const cellLat = Math.round(p.gpsLat * 6) / 6;
          const cellLng = Math.round(p.gpsLng * 6) / 6;
          const key = p.locationLabel ? `loc:${p.locationLabel}` : `cell:${cellLat.toFixed(2)},${cellLng.toFixed(2)}`;
          if (!clusterMap.has(key)) {
            clusterMap.set(key, {
              id: key,
              label: p.locationLabel || `${p.gpsLat.toFixed(2)}, ${p.gpsLng.toFixed(2)}`,
              latSum: 0,
              lngSum: 0,
              coverHash: p.hash,
              photos: [],
            });
          }
          const c = clusterMap.get(key);
          c.latSum += p.gpsLat;
          c.lngSum += p.gpsLng;
          c.photos.push(p);
        }

        const clusters = Array.from(clusterMap.values())
          .map((c) => ({
            id: c.id,
            label: c.label,
            lat: Math.round((c.latSum / c.photos.length) * 1e6) / 1e6,
            lng: Math.round((c.lngSum / c.photos.length) * 1e6) / 1e6,
            count: c.photos.length,
            coverHash: c.coverHash,
            hashes: c.photos.map((p) => p.hash),
            latestDate: c.photos[0]?.photoDate || '',
          }))
          .sort((a, b) => b.count - a.count);

        return sendJsonOptimized(req, res, {
          success: true,
          totalPhotos: all.length,
          geoTaggedCount: geoPhotos.length,
          clusterCount: clusters.length,
          clusters,
          photos: geoPhotos.slice(0, 1000),
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async getCleanupSuggestions(req, res) {
      try {
        const { hashIndex, storageDir } = req.userContext;
        const scan = req.query.scan !== '0' && req.query.scan !== 'false';
        const blurThreshold = Number(req.query.blurThreshold) > 0 ? Number(req.query.blurThreshold) : 35;
        const maxScan = Math.min(200, Math.max(10, Number(req.query.maxScan) || 80));
        const report = await buildCleanupSuggestions({
          hashIndex,
          storageDir,
          scan,
          maxScan,
          blurThreshold,
        });
        return sendJsonOptimized(req, res, {
          success: true,
          ...report,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async streamPreview(req, res) {
      try {
        const lookupResult = await lookupPhotoOr404(req, res);
        if (!lookupResult) return undefined;

        const { storageDir } = req.userContext;
        const record = lookupResult.record;
        if (record.proxyRelativePath) {
          const proxyPath = path.join(storageDir, record.proxyRelativePath);
          if (await fileExistsAsync(proxyPath)) {
            return sendImmutableMediaFile(res, proxyPath, {
              variant: 'proxy',
              masterHash: lookupResult.masterHash,
            });
          }
        }

        if (isVideoFilename(record.originalName || record.relativePath || '')) {
          return res.status(404).json({
            success: false,
            needsProxy: true,
            error: 'Compressed video preview not created yet',
          });
        }

        if (redirectIfS3(res, record)) return undefined;

        const fullPath = path.join(storageDir, record.relativePath);
        if (!(await fileExistsAsync(fullPath))) {
          return res.status(404).json({
            success: false,
            error: 'Photo file not found on disk',
          });
        }
        return sendImmutableMediaFile(res, fullPath, {
          variant: 'master',
          masterHash: lookupResult.masterHash,
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async streamVideoProxy(req, res) {
      try {
        const lookupResult = await lookupPhotoOr404(req, res);
        if (!lookupResult) return undefined;

        const { storageDir } = req.userContext;
        const record = lookupResult.record;
        if (record.videoProxyRelativePath) {
          const videoProxyPath = path.join(storageDir, record.videoProxyRelativePath);
          if (await fileExistsAsync(videoProxyPath)) {
            return sendImmutableMediaFile(res, videoProxyPath, {
              variant: 'video-proxy',
              masterHash: lookupResult.masterHash,
              contentType: 'video/mp4',
            });
          }
        }

        return res.status(404).json({
          success: false,
          error: 'Compressed video proxy not available for this item',
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async setProtectOriginal(req, res) {
      try {
        const { hashIndex } = req.userContext;
        const body = req.body || {};
        const keepOriginal =
          body.keepOriginalOnDevice !== undefined
            ? Boolean(body.keepOriginalOnDevice)
            : body.protected !== undefined
              ? Boolean(body.protected)
              : true;

        const updated = await hashIndex.setOriginalProtected(req.params.hash, keepOriginal);
        if (!updated) {
          return res.status(404).json({
            success: false,
            error: 'Photo not found',
          });
        }

        return res.json({
          success: true,
          keepOriginalOnDevice: Boolean(updated.keepOriginalOnDevice),
          photo: hashIndex.formatMasterSummary(updated, req.params.hash),
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async setProtectOriginalsBatch(req, res) {
      try {
        const { hashIndex } = req.userContext;
        const body = req.body || {};
        const rawHashes = Array.isArray(body.hashes) ? body.hashes : null;
        if (!rawHashes || rawHashes.length === 0) {
          return res.status(400).json({
            success: false,
            error: 'JSON body must include a non-empty "hashes" array.',
          });
        }
        const keepOriginal =
          body.keepOriginalOnDevice !== undefined
            ? Boolean(body.keepOriginalOnDevice)
            : body.protected !== undefined
              ? Boolean(body.protected)
              : true;

        const cleaned = rawHashes.slice(0, MAX_BATCH_PROTECT_COUNT);
        const { updated, missing } = await hashIndex.setOriginalsProtectedBatch(
          cleaned,
          keepOriginal
        );

        return sendJsonOptimized(req, res, {
          success: true,
          keepOriginalOnDevice: keepOriginal,
          updatedCount: updated.length,
          photos: updated,
          missing,
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async setFavorite(req, res) {
      try {
        const { hashIndex } = req.userContext;
        const body = req.body || {};
        const isFav =
          body.isFavorite !== undefined
            ? Boolean(body.isFavorite)
            : body.favorite !== undefined
              ? Boolean(body.favorite)
              : true;

        const updated = await hashIndex.setFavorite(req.params.hash, isFav);
        if (!updated) {
          return res.status(404).json({
            success: false,
            error: 'Photo not found',
          });
        }

        return res.json({
          success: true,
          isFavorite: Boolean(updated.isFavorite),
          photo: hashIndex.formatMasterSummary(updated, req.params.hash),
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async listTrash(req, res) {
      try {
        const { hashIndex, storageDir } = req.userContext;
        await purgeExpiredTrashIfDue(hashIndex, storageDir, true);
        const photos = hashIndex.listTrashed(TRASH_RETENTION_DAYS);
        const usage = hashIndex.getStorageUsage();
        return sendJsonOptimized(req, res, {
          success: true,
          retentionDays: TRASH_RETENTION_DAYS,
          total: photos.length,
          trashBytes: usage.trashBytes || 0,
          photos,
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async moveToTrash(req, res) {
      try {
        const { hashIndex } = req.userContext;
        const rawHashes = req.body && Array.isArray(req.body.hashes) ? req.body.hashes : null;
        if (!rawHashes || rawHashes.length === 0) {
          return res.status(400).json({
            success: false,
            error: 'JSON body must include a non-empty "hashes" array.',
          });
        }
        const { trashed, missing } = await hashIndex.moveToTrash(
          rawHashes.slice(0, MAX_BATCH_DELETE_COUNT)
        );
        return res.json({
          success: true,
          mode: 'trash',
          trashed,
          deleted: trashed,
          missing,
          trashedCount: trashed.length,
          deletedCount: trashed.length,
          freedBytes: 0,
          retentionDays: TRASH_RETENTION_DAYS,
          storage: hashIndex.getStorageUsage(),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async restoreFromTrash(req, res) {
      try {
        const { hashIndex } = req.userContext;
        const rawHashes = req.body && Array.isArray(req.body.hashes) ? req.body.hashes : null;
        if (!rawHashes || rawHashes.length === 0) {
          return res.status(400).json({
            success: false,
            error: 'JSON body must include a non-empty "hashes" array.',
          });
        }
        const { restored, missing } = await hashIndex.restoreFromTrash(
          rawHashes.slice(0, MAX_BATCH_DELETE_COUNT)
        );
        return res.json({
          success: true,
          restored,
          missing,
          restoredCount: restored.length,
          storage: hashIndex.getStorageUsage(),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async emptyTrash(req, res) {
      try {
        const { hashIndex, storageDir } = req.userContext;
        const rawHashes = req.body && Array.isArray(req.body.hashes) && req.body.hashes.length > 0
          ? req.body.hashes.slice(0, MAX_BATCH_DELETE_COUNT)
          : hashIndex.listTrashed(TRASH_RETENTION_DAYS).map((p) => p.hash);

        const keysToRemove = new Set();
        const handledCanonical = new Set();
        const deleted = [];
        const failed = [];
        let freedBytes = 0;

        for (const raw of rawHashes) {
          const norm = String(raw || '').trim().toLowerCase();
          const found = hashIndex.findMasterRecordKeys(norm);
          if (!found || !found.record || !found.record.deletedAt) continue;
          if (handledCanonical.has(found.canonicalHash)) continue;
          handledCanonical.add(found.canonicalHash);
          try {
            const bytes = await deleteRecordFiles({ storageDir, record: found.record });
            freedBytes += bytes;
            deleted.push(found.canonicalHash);
            for (const k of found.keys) keysToRemove.add(k);
          } catch (err) {
            failed.push({ hash: found.canonicalHash, error: err.message || 'Delete failed' });
          }
        }

        if (keysToRemove.size > 0) {
          await hashIndex.removeKeys(Array.from(keysToRemove), { persist: true });
        }

        return res.json({
          success: failed.length === 0,
          deleted,
          failed,
          deletedCount: deleted.length,
          freedBytes,
          storage: hashIndex.getStorageUsage(),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async downloadZip(req, res) {
      try {
        const { hashIndex, storageDir } = req.userContext;
        const rawHashes = req.body && Array.isArray(req.body.hashes) ? req.body.hashes : null;
        if (!rawHashes || rawHashes.length === 0) {
          return res.status(400).json({
            success: false,
            error: 'JSON body must include a non-empty "hashes" array.',
          });
        }

        const entries = [];
        const seen = new Set();
        for (const raw of rawHashes) {
          const norm = String(raw || '').trim().toLowerCase();
          if (!norm || seen.has(norm)) continue;
          seen.add(norm);
          const found = await hashIndex.lookup(norm, { allowStatFastPath: true, includeTrashed: true });
          if (found.status === 'missing' || !found.record) continue;
          const record = found.record;
          const entryDate = record.takenAt
            ? new Date(record.takenAt)
            : record.uploadedAt
              ? new Date(record.uploadedAt)
              : new Date();
          const name = record.originalName || path.basename(record.relativePath || `${found.masterHash.slice(0, 12)}.bin`);

          if (record.storageType === 's3' && isS3Configured(config.s3)) {
            entries.push({
              name,
              date: entryDate,
              openStream: () => {
                const url = createPresignedUrl({
                  s3Config: config.s3,
                  method: 'GET',
                  objectKey: record.relativePath,
                  expiresIn: 300,
                });
                return createHttpReadStream(url);
              },
            });
          } else if (record.relativePath) {
            const fullPath = resolveInsideStorageDir(storageDir, record.relativePath);
            if (fullPath && (await fileExistsAsync(fullPath))) {
              entries.push({
                name,
                date: entryDate,
                openStream: async () => createDiskReadStream(fullPath),
              });
            }
          }
          if (entries.length >= MAX_ZIP_ITEMS) break;
        }

        if (entries.length === 0) {
          return res.status(404).json({
            success: false,
            error: 'No downloadable files found for the selected items.',
          });
        }

        const stamp = new Date().toISOString().slice(0, 10);
        res.setHeader('Content-Type', 'application/zip');
        res.setHeader('Content-Disposition', `attachment; filename="PhotoHub-${stamp}.zip"`);
        res.setHeader('Cache-Control', 'no-store');
        return streamZipToResponse(res, entries);
      } catch (err) {
        if (!res.headersSent) {
          return res.status(500).json({ success: false, error: err.message });
        }
        return res.end();
      }
    },

    async deletePhoto(req, res) {
      try {
        const { hashIndex, storageDir } = req.userContext;
        const found = hashIndex.findMasterRecordKeys(req.params.hash);
        if (!found) {
          return res.status(404).json({
            success: false,
            error: 'Photo not found',
          });
        }

        const freedBytes = await deleteRecordFiles({
          storageDir,
          record: found.record,
        });
        await hashIndex.removeKeys(found.keys, { persist: true });

        return res.json({
          success: true,
          hash: found.canonicalHash,
          deleted: [found.canonicalHash],
          freedBytes,
          storage: hashIndex.getStorageUsage(),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async deletePhotosBatch(req, res) {
      try {
        const { hashIndex, storageDir } = req.userContext;
        const rawHashes =
          req.body && Array.isArray(req.body.hashes) ? req.body.hashes : null;
        if (!rawHashes) {
          return res.status(400).json({
            success: false,
            error: 'JSON body must include a "hashes" array.',
          });
        }

        // Optional 30-day soft-delete mode (`mode: 'trash'` or `soft: true`)
        if (req.body && (req.body.mode === 'trash' || req.body.soft === true)) {
          const { trashed, missing } = await hashIndex.moveToTrash(
            rawHashes.slice(0, MAX_BATCH_DELETE_COUNT)
          );
          return res.json({
            success: true,
            mode: 'trash',
            trashed,
            deleted: trashed,
            missing,
            failed: [],
            deletedCount: trashed.length,
            freedBytes: 0,
            retentionDays: TRASH_RETENTION_DAYS,
            storage: hashIndex.getStorageUsage(),
          });
        }

        const cleaned = [];
        const seenInput = new Set();
        for (const h of rawHashes) {
          const norm = String(h || '').trim().toLowerCase();
          if (!norm || seenInput.has(norm)) continue;
          seenInput.add(norm);
          cleaned.push(norm);
          if (cleaned.length >= MAX_BATCH_DELETE_COUNT) break;
        }
        if (cleaned.length === 0) {
          return res.status(400).json({
            success: false,
            error: 'At least one photo hash is required.',
          });
        }

        const keysToRemove = new Set();
        const handledCanonical = new Set();
        const deleted = [];
        const missing = [];
        const failed = [];
        let freedBytes = 0;

        for (const normHash of cleaned) {
          const found = hashIndex.findMasterRecordKeys(normHash);
          if (!found) {
            missing.push(normHash);
            continue;
          }
          if (handledCanonical.has(found.canonicalHash)) {
            continue;
          }
          handledCanonical.add(found.canonicalHash);

          try {
            const bytes = await deleteRecordFiles({
              storageDir,
              record: found.record,
            });
            freedBytes += bytes;
            deleted.push(found.canonicalHash);
            for (const k of found.keys) {
              keysToRemove.add(k);
            }
          } catch (err) {
            failed.push({
              hash: found.canonicalHash,
              error: err.message || 'Delete failed',
            });
          }
        }

        if (keysToRemove.size > 0) {
          await hashIndex.removeKeys(Array.from(keysToRemove), { persist: true });
        }

        return res.json({
          success: failed.length === 0,
          deleted,
          missing,
          failed,
          deletedCount: deleted.length,
          freedBytes,
          storage: hashIndex.getStorageUsage(),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async downloadMaster(req, res) {
      try {
        const lookupResult = await lookupPhotoOr404(req, res, { includeStat: true });
        if (!lookupResult) return undefined;

        const { storageDir } = req.userContext;
        const record = lookupResult.record;
        if (redirectIfS3(res, record)) return undefined;

        const fullPath = path.join(storageDir, record.relativePath);
        const safeName = encodeURIComponent(record.originalName || path.basename(fullPath));
        return await streamImmutableFileFast(req, res, fullPath, {
          stat: lookupResult.stat || null,
          masterHash: lookupResult.masterHash,
          contentDisposition: `inline; filename="${safeName}"`,
        });
      } catch (err) {
        if (!res.headersSent) {
          return res.status(500).json({
            success: false,
            error: err.message,
          });
        }
        return undefined;
      }
    },
  };
}

module.exports = { createPhotoController };
