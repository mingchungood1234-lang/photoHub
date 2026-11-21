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
  assertWithinQuota,
  sanitizeFilename,
  parseDateFolder,
} = require('../services/storageService');
const {
  isS3Configured,
  createPresignedUrl,
  verifyS3ObjectChecksum,
} = require('../services/s3Service');

function createUploadController({ config, contextService }) {
  return {
    async uploadDirect(req, res) {
      try {
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
        });

        result.userFolder = folderName;
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
  };
}

module.exports = { createUploadController };
