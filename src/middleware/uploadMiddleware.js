/**
 * UPLOAD BODY PARSER MIDDLEWARE
 *
 * Where this belongs: `src/middleware/uploadMiddleware.js`.
 * Where it is used:
 *   - `conditionalMultipart` runs per-route in `src/routes/uploadRoutes.js` to parse HTML/form
 *     `multipart/form-data` uploads (`multer` puts uploaded file(s) into `req.files`).
 *   - Raw binary uploads bypass RAM buffering so `uploadController.uploadDirect` can stream
 *     100MB+ / multi-GB videos directly onto `storageDir` via `storeAndVerifyStream`.
 */

const multer = require('multer');

function createUploadMiddleware(config) {
  // Cap RAM-buffered multipart uploads so abusive/oversized multipart requests cannot OOM-kill Node.js.
  // Large 4K videos bypass multer and stream directly to disk via raw binary or chunked upload endpoints.
  const maxMultipartBytes =
    Number(config.maxMultipartFileBytes) > 0
      ? Number(config.maxMultipartFileBytes)
      : Math.min(Number(config.maxFileSizeBytes) || 150 * 1024 * 1024, 150 * 1024 * 1024);

  const upload = multer({
    storage: multer.memoryStorage(),
    limits: {
      fileSize: maxMultipartBytes,
      files: 25,
      fields: 50,
      fieldSize: 1 * 1024 * 1024,
      parts: 80,
    },
  });

  const conditionalMultipart = (req, res, next) => {
    const contentType = String(req.headers['content-type'] || '').toLowerCase();
    if (contentType.startsWith('multipart/form-data')) {
      return upload.any()(req, res, next);
    }
    return next();
  };

  return {
    conditionalMultipart,
  };
}

module.exports = { createUploadMiddleware };
