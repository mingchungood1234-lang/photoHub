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
  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: config.maxFileSizeBytes },
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
