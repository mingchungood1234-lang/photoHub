/**
 * HEALTH CHECK CONTROLLER
 *
 * Where this belongs: `src/controllers/healthController.js`.
 * Called by: `src/routes/publicRoutes.js` (`GET /api/health` — no login required).
 * Calls: `contextService.getTotalIndexedCount()` and `s3Service.isS3Configured(...)`.
 * Used by: Docker health checks and Android/iOS apps pre-warming TLS sockets before downloads.
 */

const { isS3Configured, isPrimaryS3Backend } = require('../services/s3Service');
const { getCapabilities: getProxyCapabilities } = require('../services/proxyService');

function createHealthController({ config, contextService, nodeAllocationService = null }) {
  return {
    async getHealth(req, res) {
      const caps = await getProxyCapabilities().catch(() => null);
      res.json({
        success: true,
        status: 'ok',
        indexedPhotos: contextService.getTotalIndexedCount(),
        configuredUsers: contextService.folderContexts.size,
        storageDir: config.storageDir,
        storageBackend: isPrimaryS3Backend(config) ? 's3' : 'disk',
        s3Enabled: isS3Configured(config.s3),
        videoEncoder: caps ? caps.videoEncoder : null,
        nvencEnabled: Boolean(caps && caps.nvenc),
      });
    },

    async getNodeCapacity(req, res) {
      try {
        if (!nodeAllocationService) {
          return res.status(503).json({ success: false, error: 'Node telemetry unavailable.' });
        }
        const auth = nodeAllocationService.verifyNodeProbeAuth(req);
        if (!auth.authorized) {
          return res.status(401).json({ success: false, error: 'Unauthorized node capacity probe.' });
        }
        const reqBaseUrl = contextService.resolveRequestBaseUrl(req);
        const requestedNodeId =
          auth.payload && auth.payload.targetNodeId ? String(auth.payload.targetNodeId) : null;
        const effectiveLocalNodeId =
          config.nodeId || requestedNodeId || nodeAllocationService.identifyLocalNodeId(reqBaseUrl);
        const capacity = await contextService.getServerCapacitySummary({
          localNodeId: effectiveLocalNodeId,
          publicBaseUrl: reqBaseUrl,
        });
        return res.json({
          success: true,
          instanceId: nodeAllocationService.instanceId,
          nodeId: effectiveLocalNodeId || 'primary',
          capacity,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },
  };
}

module.exports = { createHealthController };
