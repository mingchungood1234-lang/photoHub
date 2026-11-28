/**
 * GLOBAL ERROR HANDLER MIDDLEWARE
 *
 * Where this belongs: `src/middleware/errorMiddleware.js`.
 * Where it is used: Registered LAST in `src/app.js` (`app.use(errorMiddleware)`).
 * Express identifies error middleware by its 4 parameters `(err, req, res, next)`.
 * Whenever any middleware/multer upload calls `next(err)`, execution jumps here and safely
 * responds with `canDelete: false` so phones NEVER delete an original photo after a failure.
 */
function errorMiddleware(err, req, res, _next) {
  if (!err) return;
  console.error(`[${new Date().toISOString()}] SERVER ERROR (${req.method} ${req.path}):`, err.message || err);

  if (res.headersSent || res.writableEnded || res.destroyed) {
    return;
  }

  // Normalize Express body-parser & Multer limit errors into accurate HTTP status codes
  if (err.type === 'entity.too.large' || err.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({
      success: false,
      canDelete: false,
      error: 'Uploaded payload exceeds maximum allowed size.',
    });
  }
  if (
    err.code === 'LIMIT_FILE_COUNT' ||
    err.code === 'LIMIT_PART_COUNT' ||
    err.code === 'LIMIT_FIELD_COUNT' ||
    err.code === 'LIMIT_FIELD_VALUE'
  ) {
    return res.status(400).json({
      success: false,
      canDelete: false,
      error: 'Upload request exceeds allowed multipart field or file limits.',
    });
  }
  if (err.type === 'entity.parse.failed' || (err instanceof SyntaxError && err.status === 400)) {
    return res.status(400).json({
      success: false,
      canDelete: false,
      error: 'Malformed JSON request body.',
    });
  }

  const status = Number(err.statusCode || err.status) || 500;
  const safeMessage =
    status >= 500 && !err.expose
      ? 'Internal server error'
      : err.message || 'Unexpected request error';

  return res.status(status).json({
    success: false,
    canDelete: false,
    error: safeMessage,
  });
}

module.exports = { errorMiddleware };
