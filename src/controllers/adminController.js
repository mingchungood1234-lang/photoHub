/**
 * ADMIN DASHBOARD & SERVER CAPACITY CONTROLLER
 *
 * Where this belongs: `src/controllers/adminController.js`.
 * Called by: `src/routes/adminRoutes.js` (`/admin` HTML page + `/api/admin/*` APIs after `adminAuthMiddleware`).
 * Calls: `services/contextService.js` (`getServerCapacitySummary`, `rescanFolders`),
 *        `models/userModel.js` (`UserDirectory.setQuotaOverride`), `config/env.js` (`gbToBytes`).
 */

const path = require('path');
const { isS3Configured } = require('../services/s3Service');
const { gbToBytes } = require('../config/env');

const DASHBOARD_HTML_PATH = path.join(__dirname, '..', 'views', 'adminDashboard.html');

function createAdminController({ config, contextService, userDirectory, nodeAllocationService = null }) {
  return {
    getDashboardPage(req, res) {
      return res.sendFile(DASHBOARD_HTML_PATH, { dotfiles: 'allow' });
    },

    async getOverview(req, res) {
      try {
        const reqBaseUrl = contextService.resolveRequestBaseUrl(req);
        const capacity = await contextService.getServerCapacitySummary({ publicBaseUrl: reqBaseUrl });
        const nodeTelemetry = nodeAllocationService
          ? await nodeAllocationService.probeAllStorageNodes({ publicBaseUrl: reqBaseUrl })
          : [];
        const nodes = nodeTelemetry.map((entry) => ({
          id: entry.node.id,
          url: entry.node.url,
          isLocal: entry.isLocal,
          reachable: entry.reachable,
          error: entry.error,
          isFullForNewUsers: entry.capacity ? entry.capacity.isFullForNewUsers : null,
          newSignupBlockReason: entry.capacity ? entry.capacity.newSignupBlockReason : null,
          totalUsedBytes: entry.capacity ? entry.capacity.totalUsedBytes : null,
          totalAllocatedQuotaBytes: entry.capacity ? entry.capacity.totalAllocatedQuotaBytes : null,
          diskFreeBytes: entry.capacity ? entry.capacity.diskFreeBytes : null,
          registeredUserCount: entry.capacity ? entry.capacity.registeredUserCount : null,
          maxUsers: entry.capacity ? entry.capacity.maxUsers : null,
        }));
        return res.json({
          success: true,
          server: {
            storageDir: config.storageDir,
            s3Enabled: isS3Configured(config.s3),
            googleEnabled: Boolean(config.googleClientId && config.googleClientSecret),
            nodeCount: config.storageNodes.length || 1,
            nodeAllocationMode: config.nodeAllocationMode || 'ordered',
          },
          capacity,
          nodes,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async rescanStorage(req, res) {
      try {
        const folderKey = req.body && req.body.folderKey ? String(req.body.folderKey) : null;
        const rescanned = await contextService.rescanFolders(folderKey);
        return res.json({ success: true, rescanned });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async updateUserQuota(req, res) {
      try {
        const { sub, email, quotaGb } = req.body || {};
        const target = String(sub || email || '').trim();
        if (!target) {
          return res.status(400).json({
            success: false,
            error: 'Missing "sub" or "email" in JSON body.',
          });
        }
        const parsedGb = Number(quotaGb);
        if (!Number.isFinite(parsedGb) || parsedGb < 0) {
          return res.status(400).json({
            success: false,
            error: '"quotaGb" must be a non-negative number (0 resets to default/unlimited).',
          });
        }
        const newBytes = parsedGb === 0 ? null : gbToBytes(parsedGb);
        const updated = await userDirectory.setQuotaOverride(target, newBytes);
        if (!updated) {
          return res.status(404).json({
            success: false,
            error: 'Google user record not found in users.json.',
          });
        }
        return res.json({
          success: true,
          user: updated,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },
  };
}

module.exports = { createAdminController };
