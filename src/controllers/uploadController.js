/**
 * PHOTO & VIDEO UPLOAD CONTROLLER (Direct VPS & S3 Presigned Flows)
 *
 * Where this belongs: `src/controllers/uploadController.js`.
 * Called by: `src/routes/uploadRoutes.js`:
 *   - `uploadDirect`  (`POST /api/upload` after `uploadMiddleware` parses `req.files` or raw `req.body` Buffer)
 *   - `presignUpload` (`POST /api/upload/presign` — checks duplicates/quota & returns temporary S3 PUT URL)
 *   - `confirmUpload` (`POST /api/upload/confirm` — verifies S3 object SHA-256 & records it in `hashIndex`)
 * Calls: `services/storageService.js` (saves & SHA-256 verifies on disk) and `services/s3Service.js`.
 */

const path = require('path');
const {
  storeAndVerifyPhoto,
  storeAndVerifyStream,
  assertWithinQuota,
  sanitizeFilename,
  parseDateFolder,
} = require('../services/storageService');
const {
  isS3Configured,
  createPresignedUrl,
  verifyS3ObjectChecksum,
} = require('../services/s3Service');

function createUploadController({ config, contextService, proxyQueue = null, chunkedUploadService = null }) {
  function maybeEnqueueAutoProxy({ req, result, hashIndex, storageDir, folderName, source = 'upload' }) {
    if (!proxyQueue || !result || !result.success || result.isProxy || !result.hash) {
      return false;
    }
    const skipHeader = String((req && req.headers && req.headers['x-skip-auto-proxy']) || '').trim();
    if (skipHeader === '1' || skipHeader.toLowerCase() === 'true') {
      return false;
    }
    // Auto-generate server proxies for Web & Chunked Web uploads (or when explicitly requested);
    // mobile apps (iOS/Android) already generate & register their own optimized proxies.
    const explicitSource = String((req && req.headers && req.headers['x-upload-source']) || '').trim().toLowerCase();
    const explicitAuto = String((req && req.headers && req.headers['x-auto-proxy']) || '').trim().toLowerCase();
    const isWebUpload =
      explicitSource === 'web' ||
      explicitSource === 'chunked-web' ||
      source === 'chunked-web' ||
      explicitAuto === '1' ||
      explicitAuto === 'true';
    if (!isWebUpload) {
      return false;
    }
    return proxyQueue.enqueue({
      hashIndex,
      storageDir,
      folderName,
      masterHash: result.serverSha256 || result.hash,
      originalName: result.originalName || '',
      source: explicitSource || source,
    });
  }

  return {
    async uploadDirect(req, res) {
      try {
        const contentType = String(req.headers['content-type'] || '').toLowerCase();
        const isMultipart = contentType.startsWith('multipart/form-data');

        // Raw binary uploads stream straight to disk (no 100MB+ RAM Buffer bottleneck).
        if (!isMultipart && (!Array.isArray(req.files) || req.files.length === 0)) {
          const originalName = req.headers['x-file-name']
            ? decodeURIComponent(String(req.headers['x-file-name']))
            : '';
          const mimeType = String(req.headers['content-type'] || 'application/octet-stream');
          const createdAt =
            req.headers['x-photo-date'] ||
            req.headers['x-created-at'] ||
            '';
          const expectedHash =
            req.headers['x-file-sha256'] ||
            req.headers['x-file-hash'] ||
            '';
          const strictChecksum =
            String(req.headers['x-verify-checksum'] ?? req.query.strictChecksum ?? '')
              .trim()
              .toLowerCase() === 'strict' ||
            String(req.query.strictChecksum ?? '').trim().toLowerCase() === 'true';
          const gpsLat = req.headers['x-gps-lat'] !== undefined ? Number(req.headers['x-gps-lat']) : null;
          const gpsLng = req.headers['x-gps-lng'] !== undefined ? Number(req.headers['x-gps-lng']) : null;
          const locationLabel = req.headers['x-location-label']
            ? decodeURIComponent(String(req.headers['x-location-label']))
            : null;

          const { storageDir, hashIndex, folderName } = req.userContext;
          const quotaBytes = contextService.getQuotaBytesForContext(req.userContext);

          const result = await storeAndVerifyStream({
            req,
            originalName,
            mimeType,
            createdAt,
            expectedHash,
            strictChecksum,
            storageDir,
            hashIndex,
            quotaBytes,
            minFreeDiskBytes: config.minFreeDiskBytes,
            maxFileSizeBytes: config.maxFileSizeBytes,
            gpsLat,
            gpsLng,
            locationLabel,
          });

          result.userFolder = folderName;
          result.proxyQueued = maybeEnqueueAutoProxy({
            req,
            result,
            hashIndex,
            storageDir,
            folderName,
            source: 'web',
          });
          const displayPath = folderName
            ? `${folderName}/${result.savedPath}`
            : result.savedPath;

          console.log(
            `[${new Date().toISOString()}] ${result.status.toUpperCase()}${folderName ? ` [${folderName}]` : ''}: ${displayPath} (${result.hash.slice(0, 12)}..., ${result.size} bytes) -> canDelete=${result.canDelete}`
          );

          return res.status(200).json(result);
        }

        let buffer = null;
        let originalName = '';
        let mimeType = '';

        if (Array.isArray(req.files) && req.files.length > 0) {
          const file = req.files[0];
          buffer = file.buffer;
          originalName = file.originalname;
          mimeType = file.mimetype;
        } else if (Buffer.isBuffer(req.body) && req.body.length > 0) {
          buffer = req.body;
          originalName = decodeURIComponent(
            String(req.headers['x-file-name'] || '')
          );
          mimeType = String(
            req.headers['content-type'] || 'application/octet-stream'
          );
        }

        if (!buffer || buffer.length === 0) {
          return res.status(400).json({
            success: false,
            canDelete: false,
            error:
              'No photo file received. In Apple Shortcuts, use "Form" with a File field named "photo" or "File" request body.',
          });
        }

        const bodyFields =
          req.body && !Buffer.isBuffer(req.body) ? req.body : {};
        const createdAt =
          bodyFields.createdAt ||
          bodyFields.photoDate ||
          req.headers['x-photo-date'] ||
          req.headers['x-created-at'] ||
          '';
        const expectedHash =
          bodyFields.hash ||
          bodyFields.expectedHash ||
          bodyFields.sha256 ||
          req.headers['x-file-sha256'] ||
          req.headers['x-file-hash'] ||
          '';
        const customName =
          bodyFields.fileName ||
          bodyFields.filename ||
          (req.headers['x-file-name']
            ? decodeURIComponent(String(req.headers['x-file-name']))
            : '') ||
          originalName;
        const strictChecksum =
          String(
            bodyFields.strictChecksum ??
              req.headers['x-verify-checksum'] ??
              req.query.strictChecksum ??
              ''
          )
            .trim()
            .toLowerCase() === 'strict' ||
          String(
            bodyFields.strictChecksum ?? req.query.strictChecksum ?? ''
          )
            .trim()
            .toLowerCase() === 'true';

        const { storageDir, hashIndex, folderName } = req.userContext;
        const quotaBytes = contextService.getQuotaBytesForContext(req.userContext);

        // Support Apple Shortcuts sending multiple files in a single multipart request
        if (Array.isArray(req.files) && req.files.length > 1) {
          const results = [];
          for (const file of req.files) {
            const itemResult = await storeAndVerifyPhoto({
              buffer: file.buffer,
              originalName: file.originalname,
              mimeType: file.mimetype,
              createdAt,
              expectedHash: '',
              storageDir,
              hashIndex,
              quotaBytes,
              minFreeDiskBytes: config.minFreeDiskBytes,
            });
            itemResult.userFolder = folderName;
            results.push(itemResult);
            const displayPath = folderName
              ? `${folderName}/${itemResult.savedPath}`
              : itemResult.savedPath;
            console.log(
              `[${new Date().toISOString()}] ${itemResult.status.toUpperCase()}${folderName ? ` [${folderName}]` : ''}: ${displayPath} (${itemResult.hash.slice(0, 12)}..., ${itemResult.size} bytes)`
            );
          }
          return res.status(200).json({
            success: true,
            backedUp: true,
            canDelete: true,
            count: results.length,
            userFolder: folderName,
            files: results,
          });
        }

        const result = await storeAndVerifyPhoto({
          buffer,
          originalName: customName,
          mimeType,
          createdAt,
          expectedHash,
          strictChecksum,
          storageDir,
          hashIndex,
          quotaBytes,
          minFreeDiskBytes: config.minFreeDiskBytes,
          gpsLat: bodyFields.gpsLat !== undefined ? Number(bodyFields.gpsLat) : null,
          gpsLng: bodyFields.gpsLng !== undefined ? Number(bodyFields.gpsLng) : null,
          locationLabel: bodyFields.locationLabel || null,
        });

        result.userFolder = folderName;
        result.proxyQueued = maybeEnqueueAutoProxy({
          req,
          result,
          hashIndex,
          storageDir,
          folderName,
          source: 'multipart',
        });
        const displayPath = folderName
          ? `${folderName}/${result.savedPath}`
          : result.savedPath;

        console.log(
          `[${new Date().toISOString()}] ${result.status.toUpperCase()}${folderName ? ` [${folderName}]` : ''}: ${displayPath} (${result.hash.slice(0, 12)}..., ${result.size} bytes) -> canDelete=${result.canDelete}`
        );

        return res.status(200).json(result);
      } catch (err) {
        const status = err.statusCode || 500;
        console.error(`[${new Date().toISOString()}] UPLOAD ERROR:`, err.message);
        if (res.headersSent || res.writableEnded || res.destroyed) {
          return;
        }
        return res.status(status).json({
          success: false,
          canDelete: false,
          canReplaceWithProxy: false,
          checksumVerified: false,
          error: err.message,
          ...(err.storage ? { storage: err.storage } : {}),
        });
      }
    },

    async presignUpload(req, res) {
      try {
        if (!isS3Configured(config.s3)) {
          return res.status(501).json({
            success: false,
            error:
              'S3/MinIO is not configured on this server. Use direct VPS upload via POST /api/upload.',
          });
        }

        const { fileName, mimeType, createdAt, expectedHash, fileSize } = req.body || {};
        const cleanHash = String(expectedHash || '').trim().toLowerCase();
        if (!cleanHash || cleanHash.length !== 64) {
          return res.status(400).json({
            success: false,
            error: 'Valid 64-character SHA-256 "expectedHash" is required.',
          });
        }

        const { hashIndex, folderName } = req.userContext;
        const lookupResult = await hashIndex.lookup(cleanHash);
        if (lookupResult.status !== 'missing' && lookupResult.record) {
          const existing = lookupResult.record;
          const isProxy = lookupResult.status === 'proxy';
          const keepOriginalOnDevice = Boolean(existing.keepOriginalOnDevice);
          return res.json({
            success: true,
            alreadyExists: true,
            isProxy,
            isProtectedOriginal: keepOriginalOnDevice,
            keepOriginalOnDevice,
            checksumVerified: !isProxy,
            canDelete: !isProxy && !keepOriginalOnDevice,
            canReplaceWithProxy: !isProxy && !keepOriginalOnDevice,
            masterHash: lookupResult.masterHash,
            serverSha256: existing.diskHash || existing.hash,
            savedPath: existing.relativePath,
          });
        }

        const quotaBytes = contextService.getQuotaBytesForContext(req.userContext);
        assertWithinQuota(hashIndex, quotaBytes, Number(fileSize) || 0);
        await contextService.assertDiskFreeForUpload(Number(fileSize) || 0);

        const { year, dateFolder } = parseDateFolder(createdAt);
        const safeName = sanitizeFilename(fileName, mimeType, cleanHash);
        const prefix = folderName ? `${folderName}/` : '';
        const objectKey = `${prefix}${year}/${dateFolder}/${cleanHash.slice(0, 8)}_${safeName}`;

        const uploadUrl = createPresignedUrl({
          s3Config: config.s3,
          method: 'PUT',
          objectKey,
          expiresIn: 900,
        });

        return res.json({
          success: true,
          alreadyExists: false,
          uploadUrl,
          objectKey,
          expiresIn: 900,
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
          ...(err.storage ? { storage: err.storage } : {}),
        });
      }
    },

    async confirmUpload(req, res) {
      try {
        if (!isS3Configured(config.s3)) {
          return res.status(501).json({
            success: false,
            checksumVerified: false,
            canReplaceWithProxy: false,
            error: 'S3/MinIO is not configured on this server.',
          });
        }

        const { objectKey, expectedHash, fileName, createdAt } = req.body || {};
        if (!objectKey || !expectedHash) {
          return res.status(400).json({
            success: false,
            checksumVerified: false,
            canReplaceWithProxy: false,
            error: 'Both "objectKey" and "expectedHash" are required.',
          });
        }

        const { actualSha256, size } = await verifyS3ObjectChecksum({
          s3Config: config.s3,
          objectKey,
          expectedSha256: expectedHash,
        });

        const { hashIndex, folderName } = req.userContext;
        const quotaBytes = contextService.getQuotaBytesForContext(req.userContext);
        assertWithinQuota(hashIndex, quotaBytes, size);

        const { dateFolder, takenAt } = parseDateFolder(createdAt);
        const record = await hashIndex.set(actualSha256, {
          hash: actualSha256,
          diskHash: actualSha256,
          storageType: 's3',
          relativePath: objectKey,
          originalName: fileName || path.basename(objectKey),
          size,
          photoDate: dateFolder,
          takenAt: takenAt || null,
          uploadedAt: new Date().toISOString(),
        });

        return res.json({
          success: true,
          backedUp: true,
          canDelete: true,
          canReplaceWithProxy: true,
          checksumVerified: true,
          serverSha256: actualSha256,
          hash: actualSha256,
          savedPath: record.relativePath,
          size: record.size,
          photoDate: record.photoDate,
          userFolder: folderName,
        });
      } catch (err) {
        const status = err.statusCode || 500;
        return res.status(status).json({
          success: false,
          checksumVerified: false,
          canReplaceWithProxy: false,
          error: err.message,
          ...(err.storage ? { storage: err.storage } : {}),
        });
      }
    },

    async initChunkedUpload(req, res) {
      try {
        if (!chunkedUploadService) {
          return res.status(501).json({ success: false, error: 'Chunked uploads are not enabled.' });
        }
        const { storageDir, hashIndex, folderName } = req.userContext;
        const quotaBytes = contextService.getQuotaBytesForContext(req.userContext);
        const body = req.body || {};
        const result = await chunkedUploadService.initSession({
          storageDir,
          hashIndex,
          folderName,
          quotaBytes,
          minFreeDiskBytes: config.minFreeDiskBytes,
          maxFileSizeBytes: config.maxFileSizeBytes,
          fileName: body.fileName || body.filename || '',
          mimeType: body.mimeType || 'application/octet-stream',
          fileSize: body.fileSize,
          chunkSize: body.chunkSize,
          expectedHash: body.expectedHash || body.sha256 || '',
          strictChecksum: Boolean(body.strictChecksum),
          createdAt: body.createdAt || body.photoDate || '',
          gpsLat: body.gpsLat,
          gpsLng: body.gpsLng,
          locationLabel: body.locationLabel,
          resumeUploadId: body.resumeUploadId || null,
        });
        return res.status(result.alreadyExists ? 200 : 201).json({
          success: true,
          ...result,
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
          ...(err.storage ? { storage: err.storage } : {}),
        });
      }
    },

    async getChunkedUploadStatus(req, res) {
      try {
        if (!chunkedUploadService) {
          return res.status(501).json({ success: false, error: 'Chunked uploads are not enabled.' });
        }
        const { storageDir, folderName } = req.userContext;
        const status = await chunkedUploadService.getSessionStatus({
          uploadId: req.params.uploadId,
          storageDir,
          folderName,
        });
        if (!status) {
          return res.status(404).json({ success: false, error: 'Upload session not found.' });
        }
        return res.json({ success: true, ...status });
      } catch (err) {
        return res.status(err.statusCode || 500).json({ success: false, error: err.message });
      }
    },

    async uploadChunkPart(req, res) {
      try {
        if (!chunkedUploadService) {
          return res.status(501).json({ success: false, error: 'Chunked uploads are not enabled.' });
        }
        const { storageDir, folderName } = req.userContext;
        const expectedChunkSha256 = String(req.headers['x-chunk-sha256'] || '').trim();
        const result = await chunkedUploadService.writeChunkStream({
          uploadId: req.params.uploadId,
          chunkIndex: req.params.chunkIndex,
          req,
          storageDir,
          folderName,
          expectedChunkSha256,
        });
        return res.json({ success: true, ...result });
      } catch (err) {
        if (res.headersSent || res.writableEnded) return;
        return res.status(err.statusCode || 500).json({ success: false, error: err.message });
      }
    },

    async completeChunkedUpload(req, res) {
      try {
        if (!chunkedUploadService) {
          return res.status(501).json({ success: false, error: 'Chunked uploads are not enabled.' });
        }
        const { storageDir, hashIndex, folderName } = req.userContext;
        const quotaBytes = contextService.getQuotaBytesForContext(req.userContext);
        const body = req.body || {};
        const result = await chunkedUploadService.completeSession({
          uploadId: req.params.uploadId,
          storageDir,
          hashIndex,
          folderName,
          quotaBytes,
          minFreeDiskBytes: config.minFreeDiskBytes,
          expectedHash: body.expectedHash || body.sha256 || '',
          strictChecksum: Boolean(body.strictChecksum),
        });
        result.userFolder = folderName;
        result.proxyQueued = maybeEnqueueAutoProxy({
          req,
          result,
          hashIndex,
          storageDir,
          folderName,
          source: 'chunked-web',
        });
        const displayPath = folderName
          ? `${folderName}/${result.savedPath}`
          : result.savedPath;
        console.log(
          `[${new Date().toISOString()}] CHUNKED_${result.status.toUpperCase()}${folderName ? ` [${folderName}]` : ''}: ${displayPath} (${result.hash.slice(0, 12)}..., ${result.size} bytes)`
        );
        return res.json(result);
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
          ...(err.missingChunks ? { missingChunks: err.missingChunks } : {}),
          ...(err.storage ? { storage: err.storage } : {}),
        });
      }
    },

    async abortChunkedUpload(req, res) {
      try {
        if (!chunkedUploadService) {
          return res.status(501).json({ success: false, error: 'Chunked uploads are not enabled.' });
        }
        const { storageDir, folderName } = req.userContext;
        const ok = await chunkedUploadService.abortSession({
          uploadId: req.params.uploadId,
          storageDir,
          folderName,
        });
        return res.json({ success: true, aborted: ok });
      } catch (err) {
        return res.status(err.statusCode || 500).json({ success: false, error: err.message });
      }
    },
  };
}

module.exports = { createUploadController };
