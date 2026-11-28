/**
 * COMPRESSED PROXY REGISTRATION & GENERATION CONTROLLER
 *
 * Where this belongs: `src/controllers/proxyController.js`.
 * Called by: `src/routes/proxyRoutes.js`:
 *   - `registerProxy`          (`POST /api/proxy/register` — stores phone-generated small JPEG/poster previews under `.proxies/`)
 *   - `uploadVideoProxyStream` (`POST /api/proxy/:masterHash/video` — streams a phone-compressed MP4 proxy directly to disk)
 *   - `generateProxy`          (`POST /api/proxy/generate` — transcodes proxies on the server using `sharp`/`ffmpeg` when possible)
 * Calls: `services/proxyService.js` and `req.userContext.hashIndex`.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const {
  getCapabilities: getProxyCapabilities,
  generateServerSideProxy,
} = require('../services/proxyService');
const {
  isS3Configured,
  isPrimaryS3Backend,
  buildS3ProxyKey,
  putS3Buffer,
  uploadFileToS3,
  downloadS3ObjectToFile,
} = require('../services/s3Service');

const MAX_BASE64_IMAGE_PROXY_BYTES = 10 * 1024 * 1024; // 10 MB
const MAX_BASE64_VIDEO_PROXY_BYTES = 20 * 1024 * 1024; // 20 MB
const MAX_STREAM_VIDEO_PROXY_BYTES = 500 * 1024 * 1024; // 500 MB

function resolveSafeChildPath(baseDir, fileName) {
  const root = path.resolve(baseDir);
  const resolved = path.resolve(root, fileName);
  if (resolved === root || !resolved.startsWith(root + path.sep)) {
    const err = new Error('Invalid proxy path');
    err.statusCode = 400;
    throw err;
  }
  return resolved;
}

function createProxyController({ config }) {
  function shouldStoreProxyInS3(record) {
    return Boolean(
      isS3Configured(config.s3) &&
        (isPrimaryS3Backend(config) || (record && record.storageType === 's3'))
    );
  }

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

        const rawMaster = String(masterHash).trim().toLowerCase();
        if (!/^[a-f0-9]{16,128}$/.test(rawMaster)) {
          return res.status(400).json({
            success: false,
            error: 'Invalid "masterHash" format',
          });
        }

        const { hashIndex, storageDir, folderName } = req.userContext;
        // CRITICAL: Verify master exists in this user's HashIndex BEFORE writing any file to disk/S3!
        const lookupResult = await hashIndex.lookup(rawMaster, { allowStatFastPath: true });
        if (lookupResult.status === 'missing' || !lookupResult.record) {
          return res.status(404).json({
            success: false,
            error: 'Master photo not found or failed disk verification',
          });
        }

        const normMaster = String(lookupResult.masterHash || rawMaster)
          .trim()
          .toLowerCase()
          .replace(/[^a-f0-9]/g, '');
        if (!normMaster || normMaster.length < 16) {
          return res.status(400).json({
            success: false,
            error: 'Invalid canonical master hash',
          });
        }

        const proxyMeta = {};
        const storeInS3 = shouldStoreProxyInS3(lookupResult.record);
        const proxiesDir = path.join(storageDir, '.proxies');

        if (proxyBase64 && typeof proxyBase64 === 'string') {
          if (proxyBase64.length > Math.ceil((MAX_BASE64_IMAGE_PROXY_BYTES * 4) / 3) + 64) {
            return res.status(413).json({
              success: false,
              error: 'Image proxy payload exceeds maximum allowed size (10 MB)',
            });
          }
          const proxyBuf = Buffer.from(proxyBase64, 'base64');
          if (proxyBuf.length > MAX_BASE64_IMAGE_PROXY_BYTES) {
            return res.status(413).json({
              success: false,
              error: 'Image proxy payload exceeds maximum allowed size (10 MB)',
            });
          }
          if (proxyBuf.length > 0) {
            const ext =
              String(proxyFormat || '').toLowerCase() === 'heic'
                ? '.heic'
                : '.jpg';
            if (storeInS3) {
              const objectKey = buildS3ProxyKey({
                folderName,
                masterHash: normMaster,
                ext,
                prefix: config.s3.prefix,
              });
              await putS3Buffer({
                s3Config: config.s3,
                objectKey,
                buffer: proxyBuf,
                contentType: ext === '.heic' ? 'image/heic' : 'image/jpeg',
              });
              proxyMeta.proxyRelativePath = objectKey;
              proxyMeta.proxyStorageType = 's3';
              proxyMeta.proxySize = proxyBuf.length;
            } else {
              await fs.promises.mkdir(proxiesDir, { recursive: true });
              const proxyFileName = `${normMaster}${ext}`;
              const proxyFullPath = resolveSafeChildPath(proxiesDir, proxyFileName);
              await fs.promises.writeFile(proxyFullPath, proxyBuf);
              proxyMeta.proxyRelativePath = `.proxies/${proxyFileName}`;
              proxyMeta.proxyStorageType = 'disk';
              proxyMeta.proxySize = proxyBuf.length;
            }
          }
        }

        if (videoProxyBase64 && typeof videoProxyBase64 === 'string') {
          if (videoProxyBase64.length > Math.ceil((MAX_BASE64_VIDEO_PROXY_BYTES * 4) / 3) + 64) {
            return res.status(413).json({
              success: false,
              error: 'Video proxy base64 payload exceeds maximum allowed size (20 MB)',
            });
          }
          const videoBuf = Buffer.from(videoProxyBase64, 'base64');
          if (videoBuf.length > MAX_BASE64_VIDEO_PROXY_BYTES) {
            return res.status(413).json({
              success: false,
              error: 'Video proxy base64 payload exceeds maximum allowed size (20 MB)',
            });
          }
          if (videoBuf.length > 0) {
            if (storeInS3) {
              const objectKey = buildS3ProxyKey({
                folderName,
                masterHash: normMaster,
                ext: '.mp4',
                prefix: config.s3.prefix,
              });
              await putS3Buffer({
                s3Config: config.s3,
                objectKey,
                buffer: videoBuf,
                contentType: 'video/mp4',
              });
              proxyMeta.videoProxyRelativePath = objectKey;
              proxyMeta.videoProxyStorageType = 's3';
              proxyMeta.videoProxySize = videoBuf.length;
            } else {
              await fs.promises.mkdir(proxiesDir, { recursive: true });
              const videoFileName = `${normMaster}.mp4`;
              const videoFullPath = resolveSafeChildPath(proxiesDir, videoFileName);
              await fs.promises.writeFile(videoFullPath, videoBuf);
              proxyMeta.videoProxyRelativePath = `.proxies/${videoFileName}`;
              proxyMeta.videoProxyStorageType = 'disk';
              proxyMeta.videoProxySize = videoBuf.length;
            }
          }
        }

        const updated = await hashIndex.registerProxy(
          lookupResult.masterHash,
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
          proxyStorageType: updated.proxyStorageType || 'disk',
          videoProxyStorageType: updated.videoProxyStorageType || null,
          savedPath: updated.relativePath,
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async uploadVideoProxyStream(req, res) {
      req.pause();
      let tmpPath = null;
      try {
        const { hashIndex, storageDir, folderName } = req.userContext;
        const lookupResult = await hashIndex.lookup(req.params.masterHash, { allowStatFastPath: true });
        if (lookupResult.status === 'missing' || !lookupResult.record) {
          return res.status(404).json({
            success: false,
            error: 'Master photo not found',
          });
        }

        const normMaster = lookupResult.masterHash.replace(/[^a-f0-9]/gi, '');
        const storeInS3 = shouldStoreProxyInS3(lookupResult.record);
        const videoFileName = `${normMaster}.mp4`;
        let videoFullPath = null;

        if (storeInS3) {
          const stagingDir = path.join(os.tmpdir(), 'photohub-s3-staging');
          await fs.promises.mkdir(stagingDir, { recursive: true });
          tmpPath = path.join(stagingDir, `vp_${normMaster}_${process.pid}_${Date.now()}.tmp`);
        } else {
          const proxiesDir = path.join(storageDir, '.proxies');
          await fs.promises.mkdir(proxiesDir, { recursive: true });
          videoFullPath = resolveSafeChildPath(proxiesDir, videoFileName);
          tmpPath = `${videoFullPath}.${process.pid}.${Date.now()}.tmp`;
        }

        const maxVideoProxyBytes = Math.min(
          Number(config.maxFileSizeBytes) || MAX_STREAM_VIDEO_PROXY_BYTES,
          MAX_STREAM_VIDEO_PROXY_BYTES
        );
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
            if (totalBytes > maxVideoProxyBytes) {
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
          tmpPath = null;
          return res.status(400).json({
            success: false,
            error: 'Empty video proxy stream',
          });
        }

        const proxyMeta = { videoProxySize: totalBytes };
        if (storeInS3) {
          const objectKey = buildS3ProxyKey({
            folderName,
            masterHash: normMaster,
            ext: '.mp4',
            prefix: config.s3.prefix,
          });
          await uploadFileToS3({
            s3Config: config.s3,
            objectKey,
            filePath: tmpPath,
            contentType: 'video/mp4',
          });
          await fs.promises.unlink(tmpPath).catch(() => {});
          tmpPath = null;
          proxyMeta.videoProxyRelativePath = objectKey;
          proxyMeta.videoProxyStorageType = 's3';
        } else {
          await fs.promises.rename(tmpPath, videoFullPath);
          tmpPath = null;
          proxyMeta.videoProxyRelativePath = `.proxies/${videoFileName}`;
          proxyMeta.videoProxyStorageType = 'disk';
        }

        const resolvedProxyHash =
          providedProxyHash ||
          lookupResult.record.proxyHash ||
          (shaHasher ? shaHasher.digest('hex') : normMaster);

        const updated = await hashIndex.registerProxy(
          lookupResult.masterHash,
          resolvedProxyHash,
          assetId,
          proxyMeta
        );

        return res.json({
          success: true,
          masterHash: lookupResult.masterHash,
          proxyHash: updated?.proxyHash || resolvedProxyHash,
          videoProxySize: totalBytes,
          videoProxyStorageType: proxyMeta.videoProxyStorageType,
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
      let tmpWorkDir = null;
      try {
        const { masterHash, maxPixelSize, quality } = req.body || {};
        if (!masterHash) {
          return res.status(400).json({
            success: false,
            error: 'masterHash is required',
          });
        }

        const { hashIndex, storageDir, folderName } = req.userContext;
        const lookupResult = await hashIndex.lookup(masterHash, { allowStatFastPath: true });
        if (lookupResult.status === 'missing' || !lookupResult.record) {
          return res.status(404).json({
            success: false,
            error: 'Master photo not found',
          });
        }

        const record = lookupResult.record;
        const isMasterS3 = record.storageType === 's3';
        if (isMasterS3 && !isS3Configured(config.s3)) {
          return res.status(501).json({
            success: false,
            fallbackToClient: true,
            error: 'S3 storage is not configured to fetch master for proxy generation',
          });
        }

        const storeInS3 = shouldStoreProxyInS3(record);
        let sourcePath = null;
        let proxiesDir = path.join(storageDir, '.proxies');

        if (isMasterS3 || storeInS3) {
          tmpWorkDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'photohub-proxy-'));
        }

        if (isMasterS3) {
          const safeSrcName = path.basename(record.originalName || record.relativePath || 'source.bin')
            .replace(/[<>:"/\\|?*\x00-\x1F]/g, '_');
          sourcePath = path.join(tmpWorkDir, safeSrcName);
          await downloadS3ObjectToFile({
            s3Config: config.s3,
            objectKey: record.relativePath,
            destPath: sourcePath,
          });
        } else {
          sourcePath = path.join(storageDir, record.relativePath);
          if (!fs.existsSync(sourcePath)) {
            return res.status(404).json({
              success: false,
              error: 'Master photo file not found on disk',
            });
          }
        }

        if (storeInS3) {
          proxiesDir = path.join(tmpWorkDir, '.proxies');
        }

        const generated = await generateServerSideProxy({
          sourcePath,
          proxiesDir,
          masterHash: lookupResult.masterHash,
          originalName: record.originalName || sourcePath,
          maxPixelSize,
          quality,
        });

        const proxyMeta = { ...generated };
        if (storeInS3) {
          if (generated.proxyRelativePath) {
            const localImgProxy = path.join(proxiesDir, path.basename(generated.proxyRelativePath));
            const ext = path.extname(localImgProxy) || '.jpg';
            const s3ImgKey = buildS3ProxyKey({
              folderName,
              masterHash: lookupResult.masterHash,
              ext,
              prefix: config.s3.prefix,
            });
            await uploadFileToS3({
              s3Config: config.s3,
              objectKey: s3ImgKey,
              filePath: localImgProxy,
              contentType: ext === '.heic' ? 'image/heic' : 'image/jpeg',
            });
            proxyMeta.proxyRelativePath = s3ImgKey;
            proxyMeta.proxyStorageType = 's3';
          }
          if (generated.videoProxyRelativePath) {
            const localVidProxy = path.join(proxiesDir, path.basename(generated.videoProxyRelativePath));
            const s3VidKey = buildS3ProxyKey({
              folderName,
              masterHash: lookupResult.masterHash,
              ext: '.mp4',
              prefix: config.s3.prefix,
            });
            await uploadFileToS3({
              s3Config: config.s3,
              objectKey: s3VidKey,
              filePath: localVidProxy,
              contentType: 'video/mp4',
            });
            proxyMeta.videoProxyRelativePath = s3VidKey;
            proxyMeta.videoProxyStorageType = 's3';
          }
        } else {
          if (proxyMeta.proxyRelativePath) proxyMeta.proxyStorageType = 'disk';
          if (proxyMeta.videoProxyRelativePath) proxyMeta.videoProxyStorageType = 'disk';
        }

        const updated = await hashIndex.registerProxy(
          lookupResult.masterHash,
          proxyMeta.proxyHash,
          record.assetId || '',
          proxyMeta
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
      } finally {
        if (tmpWorkDir) {
          await fs.promises.rm(tmpWorkDir, { recursive: true, force: true }).catch(() => {});
        }
      }
    },
  };
}

module.exports = { createProxyController };
