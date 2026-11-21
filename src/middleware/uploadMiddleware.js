/**
 * UPLOAD BODY PARSER MIDDLEWARE
 *
 * Where this belongs: `src/middleware/uploadMiddleware.js`.
 * Where it is used:
 *   - `rawUploadParser` is mounted globally on `/api/upload` in `src/app.js` to capture raw
 *     binary file bodies (`Buffer` in `req.body`) sent by mobile clients or Apple Shortcuts.
 *   - `conditionalMultipart` runs per-route in `src/routes/uploadRoutes.js` to parse HTML/form
 *     `multipart/form-data` uploads (`multer` puts uploaded file(s) into `req.files`).
 * Where it goes next: Calls `next()` into `uploadController.uploadDirect`.
 */

const express = require('express');
const multer = require('multer');

function createUploadMiddleware(config) {
  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: config.maxFileSizeBytes },
  });

  // Parse raw binary uploads when Apple Shortcut uses "Request Body: File"
  const rawUploadParser = express.raw({
    type: (req) => {
      const contentType = String(req.headers['content-type'] || '').toLowerCase();
      return (
        !contentType.startsWith('multipart/form-data') &&
        !contentType.startsWith('application/json')
      );
    },
    limit: config.maxFileSizeBytes,
  });

  const conditionalMultipart = (req, res, next) => {
    const contentType = String(req.headers['content-type'] || '').toLowerCase();
    if (contentType.startsWith('multipart/form-data')) {
      return upload.any()(req, res, next);
    }
    return next();
  };

  return {
    rawUploadParser,
    conditionalMultipart,
  };
}

module.exports = { createUploadMiddleware };
