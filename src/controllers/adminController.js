/**
 * ADMIN DASHBOARD & SERVER CAPACITY CONTROLLER
 *
 * Where this belongs: `src/controllers/adminController.js`.
 * Called by: `src/routes/adminRoutes.js` (`/admin` HTML page + `/api/admin/*` APIs after `adminAuthMiddleware`).
 * Calls: `services/contextService.js` (`getServerCapacitySummary`, `rescanFolders`),
 *        `models/userModel.js` (`UserDirectory.setQuotaOverride`), `config/env.js` (`gbToBytes`).
 */

const os = require('os');
const path = require('path');
const { isS3Configured } = require('../services/s3Service');
const { isVideoFilename, getCapabilities: getProxyCapabilities } = require('../services/proxyService');
const { gbToBytes } = require('../config/env');

const DASHBOARD_HTML_PATH = path.join(__dirname, '..', 'views', 'adminDashboard.html');

function createAdminController({
  config,
  contextService,
  userDirectory,
  nodeAllocationService = null,
  shareStore = null,
  albumStore = null,
  proxyQueue = null,
  chunkedUploadService = null,
}) {
  function getHashIndexForFolderKey(folderKey) {
    if (!folderKey || folderKey === '__ROOT__' || folderKey === '/') {
      return {
        folderName: null,
        storageDir: config.storageDir,
        hashIndex: contextService.defaultHashIndex,
      };
    }
    return contextService.folderContexts.get(folderKey) || null;
  }

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

        const albumStats = albumStore
          ? albumStore.getStatsByFolder()
          : { totalAlbums: 0, countsByFolder: new Map() };

        // Enrich per-user rows & global analytics (photos vs videos, proxy coverage, GPS, trash, albums)
        let totalPhotosCount = 0;
        let totalVideosCount = 0;
        let totalGeoTagged = 0;
        let totalWithProxy = 0;
        let totalTrashBytes = 0;
        let totalTrashItems = 0;
        const countedFolders = new Set();

        for (const row of capacity.users || []) {
          const ctx = getHashIndexForFolderKey(row.folderKey);
          row.albumCount = albumStats.countsByFolder.get(row.folderKey) || 0;
          if (ctx && ctx.hashIndex) {
            const usage = ctx.hashIndex.getStorageUsage();
            row.trashBytes = usage.trashBytes || 0;
            row.trashItemCount = usage.trashItemCount || 0;
            const masters = ctx.hashIndex.listMasters();
            let withProxy = 0;
            let vidCnt = 0;
            let geoCnt = 0;
            for (const m of masters) {
              if (m.hasProxy || m.hasPreview) withProxy += 1;
              if (isVideoFilename(m.originalName || m.savedPath || '')) vidCnt += 1;
              if (typeof m.gpsLat === 'number' && typeof m.gpsLng === 'number') geoCnt += 1;
            }
            row.videoCount = vidCnt;
            row.photoCount = masters.length - vidCnt;
            row.geoTaggedCount = geoCnt;
            row.proxyCoveragePct =
              masters.length > 0 ? Math.round((withProxy / masters.length) * 100) : 100;

            if (!countedFolders.has(row.folderKey)) {
              countedFolders.add(row.folderKey);
              totalVideosCount += vidCnt;
              totalPhotosCount += masters.length - vidCnt;
              totalGeoTagged += geoCnt;
              totalWithProxy += withProxy;
              totalTrashBytes += usage.trashBytes || 0;
              totalTrashItems += usage.trashItemCount || 0;
            }
          } else {
            row.trashBytes = 0;
            row.trashItemCount = 0;
            row.videoCount = 0;
            row.photoCount = row.itemCount || 0;
            row.geoTaggedCount = 0;
            row.proxyCoveragePct = 100;
          }
        }

        const totalActiveMedia = totalPhotosCount + totalVideosCount;
        const proxyQueueStatus = proxyQueue
          ? await proxyQueue.getStatus()
          : { queued: 0, active: 0, completed: 0, skipped: 0, failed: 0, recentJobs: [], capabilities: await getProxyCapabilities() };
        const activeShares = shareStore ? shareStore.listAll() : [];
        const chunkedUploads = chunkedUploadService ? chunkedUploadService.listActiveSessions() : [];
        const mem = process.memoryUsage();

        return res.json({
          success: true,
          server: {
            storageDir: config.storageDir,
            s3Enabled: isS3Configured(config.s3),
            googleEnabled: Boolean(config.googleClientId && config.googleClientSecret),
            nodeCount: config.storageNodes.length || 1,
            nodeAllocationMode: config.nodeAllocationMode || 'ordered',
          },
          system: {
            nodeVersion: process.version,
            platform: `${os.platform()} ${os.arch()}`,
            uptimeSeconds: Math.round(process.uptime()),
            rssBytes: mem.rss,
            heapUsedBytes: mem.heapUsed,
            heapTotalBytes: mem.heapTotal,
            cpuCount: os.cpus().length,
            loadAvg: os.loadavg ? os.loadavg().map((n) => Math.round(n * 100) / 100) : [0, 0, 0],
            capabilities: proxyQueueStatus.capabilities,
          },
          analytics: {
            totalPhotosCount,
            totalVideosCount,
            totalGeoTagged,
            totalAlbums: albumStats.totalAlbums,
            totalTrashBytes,
            totalTrashItems,
            proxyCoveragePct:
              totalActiveMedia > 0 ? Math.round((totalWithProxy / totalActiveMedia) * 100) : 100,
            activeShareCount: activeShares.length,
            totalShareViews: activeShares.reduce((s, x) => s + (Number(x.viewCount) || 0), 0),
          },
          proxyQueue: proxyQueueStatus,
          activeShares,
          chunkedUploads,
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

    async generateMissingProxies(req, res) {
      try {
        if (!proxyQueue) {
          return res.status(501).json({ success: false, error: 'Background proxy queue is not enabled.' });
        }
        const folderKey = req.body && req.body.folderKey ? String(req.body.folderKey) : null;
        await contextService.getServerCapacitySummary();
        let queuedCount = 0;
        if (folderKey) {
          const ctx = getHashIndexForFolderKey(folderKey);
          if (ctx) {
            queuedCount += proxyQueue.enqueueMissingForContext(ctx);
          }
        } else {
          queuedCount += proxyQueue.enqueueMissingForContext({
            folderName: null,
            storageDir: config.storageDir,
            hashIndex: contextService.defaultHashIndex,
          });
          for (const ctx of contextService.folderContexts.values()) {
            queuedCount += proxyQueue.enqueueMissingForContext(ctx);
          }
        }
        return res.json({
          success: true,
          queuedCount,
          proxyQueue: await proxyQueue.getStatus(),
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async revokeShareAdmin(req, res) {
      try {
        if (!shareStore) {
          return res.status(501).json({ success: false, error: 'Share store unavailable.' });
        }
        const ok = await shareStore.adminRevokeShare(req.params.token);
        if (!ok) {
          return res.status(404).json({ success: false, error: 'Share link not found.' });
        }
        return res.json({ success: true, revoked: true });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async abortChunkedUploadAdmin(req, res) {
      try {
        if (!chunkedUploadService) {
          return res.status(501).json({ success: false, error: 'Chunked upload service unavailable.' });
        }
        const ok = await chunkedUploadService.adminAbortSession(req.params.uploadId);
        if (!ok) {
          return res.status(404).json({ success: false, error: 'Upload session not found.' });
        }
        return res.json({ success: true, aborted: true });
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
