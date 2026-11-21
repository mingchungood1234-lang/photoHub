/**
 * SERVER GALLERY BROWSING & ORIGINAL DOWNLOAD CONTROLLER
 *
 * Where this belongs: `src/controllers/photoController.js`.
 * Called by: `src/routes/photoRoutes.js` (all protected by `authMiddleware`):
 *   - `listPhotos`         (`GET /api/photos` — returns sorted timeline list w/ year, mediaType, prefix filters & gzip)
 *   - `streamPreview`      (`GET /api/photo/:hash/preview` — fast compressed JPEG preview for grid browsing)
 *   - `streamVideoProxy`   (`GET /api/photo/:hash/video-proxy` — lightweight MP4 video playback w/ Range seek)
 *   - `setProtectOriginal` (`POST /api/photo/:hash/protect-original` — marks restored originals safe from auto re-compression)
 *   - `downloadMaster`     (`GET /api/photo/:hash` — full-resolution original via S3 302 redirect or Express `sendFile` HTTP 206 Ranges)
 * Calls: `req.userContext.hashIndex` (`models/hashIndexModel.js`) and `services/s3Service.js`.
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { promisify } = require('util');
const { isS3Configured, createPresignedUrl } = require('../services/s3Service');
const { isVideoFilename } = require('../services/proxyService');

const gzipAsync = promisify(zlib.gzip);

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

function createPhotoController({ config }) {
  async function lookupPhotoOr404(req, res) {
    const { hashIndex } = req.userContext;
    const lookupResult = await hashIndex.lookup(req.params.hash, { allowStatFastPath: true });
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

  return {
    async listPhotos(req, res) {
      try {
        const { hashIndex, folderName } = req.userContext;
        if (req.query.sync === '1' || req.query.sync === 'true') {
          await hashIndex.syncStorageDir();
        }
        const limit = Math.min(1000, Math.max(1, Number(req.query.limit) || 200));
        const offset = Math.max(0, Number(req.query.offset) || 0);
        let all = hashIndex.listMasters();

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

    async streamPreview(req, res) {
      try {
        const lookupResult = await lookupPhotoOr404(req, res);
        if (!lookupResult) return undefined;

        const { storageDir } = req.userContext;
        const record = lookupResult.record;
        if (record.proxyRelativePath) {
          const proxyPath = path.join(storageDir, record.proxyRelativePath);
          if (fs.existsSync(proxyPath)) {
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
        if (!fs.existsSync(fullPath)) {
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
          if (fs.existsSync(videoProxyPath)) {
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

    async downloadMaster(req, res) {
      try {
        const lookupResult = await lookupPhotoOr404(req, res);
        if (!lookupResult) return undefined;

        const { storageDir } = req.userContext;
        const record = lookupResult.record;
        if (redirectIfS3(res, record)) return undefined;

        const fullPath = path.join(storageDir, record.relativePath);
        const safeName = encodeURIComponent(record.originalName || path.basename(fullPath));
        return sendImmutableMediaFile(res, fullPath, {
          masterHash: lookupResult.masterHash,
          contentDisposition: `inline; filename="${safeName}"`,
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },
  };
}

module.exports = { createPhotoController };
