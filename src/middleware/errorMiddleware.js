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
  console.error(`[${new Date().toISOString()}] SERVER ERROR:`, err.message);
  res.status(err.status || 400).json({
    success: false,
    canDelete: false,
    error: err.message || 'Unexpected upload error',
  });
}

module.exports = { errorMiddleware };
