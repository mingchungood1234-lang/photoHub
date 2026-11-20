/**
 * Global Multer and Express error handler — always guarantees `canDelete: false` on error.
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
