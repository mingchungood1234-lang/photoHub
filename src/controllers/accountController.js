const { isS3Configured } = require('../services/s3Service');

function createAccountController({ config, contextService }) {
  return {
    async getStorage(req, res) {
      try {
        const storage = await contextService.buildStorageSummary(req.userContext);
        return res.json({
          success: true,
          userFolder: req.userContext.folderName || null,
          nodeId: req.userContext.nodeId || 'primary',
          ...storage,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async getWhoAmI(req, res) {
      try {
        const { folderName, hashIndex, email, name, nodeId } = req.userContext;
        const storage = await contextService.buildStorageSummary(req.userContext);
        return res.json({
          success: true,
          userFolder: folderName || null,
          email: email || null,
          name: name || null,
          nodeId: nodeId || 'primary',
          indexedPhotos: hashIndex.size(),
          s3Enabled: isS3Configured(config.s3),
          storage,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },
  };
}

module.exports = { createAccountController };
