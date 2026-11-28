/**
 * DUPLICATE-CHECK & UPLOAD ROUTES (Authenticated via `authMiddleware`)
 *
 * Where this belongs: `src/routes/uploadRoutes.js`, mounted in `src/routes/index.js`.
 * Where requests go:
 *   - `GET /api/check/:hash`, `POST /api/check`, `POST /api/check/batch` -> `controllers/checkController.js`
 *   - `POST /api/upload` -> runs `uploadMiddleware.conditionalMultipart` first -> `controllers/uploadController.js` (`uploadDirect`)
 *   - `POST /api/upload/presign`, `POST /api/upload/confirm` -> S3/MinIO 2-step flow -> `controllers/uploadController.js`
 */

const express = require('express');

function createUploadRoutes({ checkController, uploadController, uploadMiddleware, securityGuards = {} }) {
  const router = express.Router();
  const noop = (_req, _res, next) => next();
  const heavyLimit = securityGuards.heavyOpLimiter || noop;

  router.get('/check/:hash', checkController.checkByParam);
  router.post('/check', checkController.checkByBody);
  router.post('/check/batch', checkController.checkBatch);

  router.post('/upload', uploadMiddleware.conditionalMultipart, uploadController.uploadDirect);
  router.post('/upload/presign', uploadController.presignUpload);
  router.post('/upload/confirm', uploadController.confirmUpload);

  // Resumable chunked uploads for large 4K videos
  router.post('/upload/chunked/init', heavyLimit, uploadController.initChunkedUpload);
  router.get('/upload/chunked/:uploadId', uploadController.getChunkedUploadStatus);
  router.put('/upload/chunked/:uploadId/part/:chunkIndex', uploadController.uploadChunkPart);
  router.post('/upload/chunked/:uploadId/part/:chunkIndex', uploadController.uploadChunkPart);
  router.post('/upload/chunked/:uploadId/complete', uploadController.completeChunkedUpload);
  router.delete('/upload/chunked/:uploadId', uploadController.abortChunkedUpload);

  return router;
}

module.exports = { createUploadRoutes };
