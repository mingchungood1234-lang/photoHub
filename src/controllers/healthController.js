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
