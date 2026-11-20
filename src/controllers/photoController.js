const fs = require('fs');
const path = require('path');
const { isS3Configured, createPresignedUrl } = require('../services/s3Service');
const { isVideoFilename } = require('../services/proxyService');

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
        if (req.query.order === 'asc') {
          all = all.slice().reverse();
        }

        const photos = all.slice(offset, offset + limit);
        return res.json({
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
            res.setHeader('X-Photo-Variant', 'proxy');
            res.setHeader('X-Master-Sha256', lookupResult.masterHash);
            return fs.createReadStream(proxyPath).pipe(res);
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
        res.setHeader('X-Photo-Variant', 'master');
        res.setHeader('X-Master-Sha256', lookupResult.masterHash);
        return fs.createReadStream(fullPath).pipe(res);
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
            res.setHeader('X-Photo-Variant', 'video-proxy');
            res.setHeader('X-Master-Sha256', lookupResult.masterHash);
            res.setHeader('Content-Type', 'video/mp4');
            return res.sendFile(path.resolve(videoProxyPath));
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
        res.setHeader(
          'Content-Disposition',
          `inline; filename="${encodeURIComponent(record.originalName || path.basename(fullPath))}"`
        );
        res.setHeader('X-Master-Sha256', lookupResult.masterHash);
        return fs.createReadStream(fullPath).pipe(res);
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
