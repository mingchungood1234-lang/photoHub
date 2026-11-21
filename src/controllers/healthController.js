/**
 * HEALTH CHECK CONTROLLER
 *
 * Where this belongs: `src/controllers/healthController.js`.
 * Called by: `src/routes/publicRoutes.js` (`GET /api/health` — no login required).
 * Calls: `contextService.getTotalIndexedCount()` and `s3Service.isS3Configured(...)`.
 * Used by: Docker health checks and Android/iOS apps pre-warming TLS sockets before downloads.
 */

const { isS3Configured } = require('../services/s3Service');

function createHealthController({ config, contextService }) {
  return {
    getHealth(req, res) {
      res.json({
        success: true,
        status: 'ok',
        indexedPhotos: contextService.getTotalIndexedCount(),
        configuredUsers: contextService.folderContexts.size,
        storageDir: config.storageDir,
        s3Enabled: isS3Configured(config.s3),
      });
    },
  };
}

module.exports = { createHealthController };
