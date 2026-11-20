const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const {
  getCapabilities: getProxyCapabilities,
  generateServerSideProxy,
} = require('../services/proxyService');

function createProxyController({ config }) {
  return {
    async registerProxy(req, res) {
      try {
        const {
          masterHash,
          proxyHash,
          assetId,
          proxyBase64,
          proxyFormat,
          videoProxyBase64,
        } = req.body || {};
        if (!masterHash || !proxyHash) {
          return res.status(400).json({
            success: false,
            error: 'Both "masterHash" and "proxyHash" are required',
          });
        }

        const { hashIndex, storageDir } = req.userContext;
        const normMaster = String(masterHash).trim().toLowerCase();
        const proxyMeta = {};
        const proxiesDir = path.join(storageDir, '.proxies');

        if (proxyBase64 && typeof proxyBase64 === 'string') {
          const proxyBuf = Buffer.from(proxyBase64, 'base64');
          if (proxyBuf.length > 0) {
            const ext =
              String(proxyFormat || '').toLowerCase() === 'heic'
                ? '.heic'
                : '.jpg';
            await fs.promises.mkdir(proxiesDir, { recursive: true });
            const proxyFileName = `${normMaster}${ext}`;
            const proxyFullPath = path.join(proxiesDir, proxyFileName);
            await fs.promises.writeFile(proxyFullPath, proxyBuf);
            proxyMeta.proxyRelativePath = `.proxies/${proxyFileName}`;
            proxyMeta.proxySize = proxyBuf.length;
          }
        }

        if (videoProxyBase64 && typeof videoProxyBase64 === 'string') {
          const videoBuf = Buffer.from(videoProxyBase64, 'base64');
          if (videoBuf.length > 0) {
            await fs.promises.mkdir(proxiesDir, { recursive: true });
            const videoFileName = `${normMaster}.mp4`;
            const videoFullPath = path.join(proxiesDir, videoFileName);
            await fs.promises.writeFile(videoFullPath, videoBuf);
            proxyMeta.videoProxyRelativePath = `.proxies/${videoFileName}`;
            proxyMeta.videoProxySize = videoBuf.length;
          }
        }

        const updated = await hashIndex.registerProxy(
          masterHash,
          proxyHash,
          assetId,
          proxyMeta
        );
        if (!updated) {
          return res.status(404).json({
            success: false,
            error: 'Master photo not found or failed disk verification',
          });
        }

        return res.json({
          success: true,
          masterHash: updated.diskHash || updated.hash,
          proxyHash: updated.proxyHash,
          proxySize: updated.proxySize || null,
          videoProxySize: updated.videoProxySize || null,
          savedPath: updated.relativePath,
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async uploadVideoProxyStream(req, res) {
      req.pause();
      let tmpPath = null;
      try {
        const { hashIndex, storageDir } = req.userContext;
        const lookupResult = await hashIndex.lookup(req.params.masterHash, { allowStatFastPath: true });
        if (lookupResult.status === 'missing' || !lookupResult.record) {
          return res.status(404).json({
            success: false,
            error: 'Master photo not found',
          });
        }

        const normMaster = lookupResult.masterHash.replace(/[^a-f0-9_-]/gi, '');
        const proxiesDir = path.join(storageDir, '.proxies');
        await fs.promises.mkdir(proxiesDir, { recursive: true });
        const videoFileName = `${normMaster}.mp4`;
        const videoFullPath = path.join(proxiesDir, videoFileName);
        tmpPath = `${videoFullPath}.${process.pid}.${Date.now()}.tmp`;

        const providedProxyHash = String(req.headers['x-proxy-hash'] || '').trim().toLowerCase();
        const assetId = String(req.headers['x-asset-id'] || '').trim();
        const shaHasher = providedProxyHash ? null : crypto.createHash('sha256');

        let totalBytes = 0;
        await new Promise((resolve, reject) => {
          const ws = fs.createWriteStream(tmpPath);
          let settled = false;
          const fail = (err) => {
            if (settled) return;
            settled = true;
            req.unpipe(ws);
            ws.destroy();
            reject(err);
          };
          ws.on('error', fail);
          req.on('error', fail);
          req.on('data', (chunk) => {
            totalBytes += chunk.length;
            if (totalBytes > config.maxFileSizeBytes) {
              const err = new Error('Video proxy exceeds maximum upload size');
              err.statusCode = 413;
              fail(err);
              return;
            }
            if (shaHasher) shaHasher.update(chunk);
          });
          ws.on('finish', () => {
            if (settled) return;
            settled = true;
            resolve();
          });
          req.resume();
          req.pipe(ws);
        });

        if (totalBytes === 0) {
          await fs.promises.unlink(tmpPath).catch(() => {});
          return res.status(400).json({
            success: false,
            error: 'Empty video proxy stream',
          });
        }

        await fs.promises.rename(tmpPath, videoFullPath);
        tmpPath = null;

        const resolvedProxyHash =
          providedProxyHash ||
          lookupResult.record.proxyHash ||
          (shaHasher ? shaHasher.digest('hex') : normMaster);

        const updated = await hashIndex.registerProxy(
          lookupResult.masterHash,
          resolvedProxyHash,
          assetId,
          {
            videoProxyRelativePath: `.proxies/${videoFileName}`,
            videoProxySize: totalBytes,
          }
        );

        return res.json({
          success: true,
          masterHash: lookupResult.masterHash,
          proxyHash: updated?.proxyHash || resolvedProxyHash,
          videoProxySize: totalBytes,
        });
      } catch (err) {
        if (tmpPath) {
          await fs.promises.unlink(tmpPath).catch(() => {});
        }
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async generateProxy(req, res) {
      try {
        const { masterHash, maxPixelSize, quality } = req.body || {};
        if (!masterHash) {
          return res.status(400).json({
            success: false,
            error: 'masterHash is required',
          });
        }

        const { hashIndex, storageDir } = req.userContext;
        const lookupResult = await hashIndex.lookup(masterHash, { allowStatFastPath: true });
        if (lookupResult.status === 'missing' || !lookupResult.record) {
          return res.status(404).json({
            success: false,
            error: 'Master photo not found',
          });
        }

        const record = lookupResult.record;
        if (record.storageType === 's3') {
          return res.status(501).json({
            success: false,
            fallbackToClient: true,
            error: 'Server-side proxy generation requires local disk storage',
          });
        }

        const fullPath = path.join(storageDir, record.relativePath);
        if (!fs.existsSync(fullPath)) {
          return res.status(404).json({
            success: false,
            error: 'Master photo file not found on disk',
          });
        }

        const proxiesDir = path.join(storageDir, '.proxies');
        const generated = await generateServerSideProxy({
          sourcePath: fullPath,
          proxiesDir,
          masterHash: lookupResult.masterHash,
          originalName: record.originalName || fullPath,
          maxPixelSize,
          quality,
        });

        const updated = await hashIndex.registerProxy(
          lookupResult.masterHash,
          generated.proxyHash,
          record.assetId || '',
          generated
        );
        if (!updated) {
          return res.status(404).json({
            success: false,
            error: 'Master photo not found',
          });
        }

        return res.json({
          success: true,
          capabilities: await getProxyCapabilities(),
          photo: hashIndex.formatMasterSummary(updated, lookupResult.masterHash),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          fallbackToClient: Boolean(err.fallbackToClient),
          error: err.message,
        });
      }
    },
  };
}

module.exports = { createProxyController };
