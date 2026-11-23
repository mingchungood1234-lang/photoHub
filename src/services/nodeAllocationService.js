/**
 * STORAGE NODE CAPACITY PROBING & ORDERED FAILOVER ALLOCATION
 *
 * Where this belongs: `src/services/nodeAllocationService.js`.
 * Called by:
 *   - `src/controllers/authController.js` during Google OAuth sign-in (`resolveNodeAndCapacityForLogin`)
 *   - `src/controllers/healthController.js` (`getNodeCapacity` on `GET /api/node/capacity`)
 *   - `src/controllers/adminController.js` (`probeAllStorageNodes` for cluster overview)
 *
 * Behavior:
 *   - `USER_NODE_MAP` overrides and existing pinned users (`existingNodeId` in `users.json`) keep their node.
 *   - Unmapped new users follow `NODE_ALLOCATION_MODE`:
 *       - `ordered` (default): tries `STORAGE_NODES` in configured order (`node1`, then `node2`, ...),
 *         picking the first node with available capacity and spilling to `node2` when `node1` is full.
 *       - `hash`: legacy Rendezvous SHA-256 spread across `STORAGE_NODES`.
 */

const crypto = require('crypto');
const {
  signToken,
  verifyToken,
  selectNodeForUser,
  resolveConfiguredUserFolder,
} = require('../models/userModel');

function normalizeOrigin(rawUrl) {
  const trimmed = String(rawUrl || '').trim();
  if (!trimmed) return '';
  try {
    const parsed = new URL(trimmed);
    const defaultPort = parsed.protocol === 'https:' ? '443' : '80';
    const port = parsed.port || defaultPort;
    return `${parsed.protocol}//${parsed.hostname.toLowerCase()}:${port}`;
  } catch {
    return trimmed.toLowerCase().replace(/\/+$/, '');
  }
}

function urlsShareOrigin(urlA, urlB) {
  const normA = normalizeOrigin(urlA);
  const normB = normalizeOrigin(urlB);
  return Boolean(normA && normB && normA === normB);
}

function identifyLocalNodeId(config, requestBaseUrl = '') {
  const explicitId = String(config.nodeId || '').trim();
  const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];
  if (explicitId) return explicitId;
  for (const node of nodes) {
    if (
      (config.publicUrl && urlsShareOrigin(node.url, config.publicUrl)) ||
      (requestBaseUrl && urlsShareOrigin(node.url, requestBaseUrl))
    ) {
      return node.id;
    }
  }
  return null;
}

function createNodeAllocationService({
  config,
  sessionSecret,
  userDirectory,
  contextService,
}) {
  const instanceId = crypto.randomUUID();
  const probeTimeoutMs = 2500;

  function timingSafeEqualString(a, b) {
    const bufA = Buffer.from(String(a || ''), 'utf8');
    const bufB = Buffer.from(String(b || ''), 'utf8');
    if (bufA.length === 0 || bufA.length !== bufB.length) return false;
    return crypto.timingSafeEqual(bufA, bufB);
  }

  function verifyNodeProbeAuth(req) {
    const authHeader = String(req.headers.authorization || '').trim();
    const bearer = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
    const adminKeyHeader = String(req.headers['x-admin-key'] || '').trim();

    if (config.adminKey && (timingSafeEqualString(adminKeyHeader, config.adminKey) || timingSafeEqualString(bearer, config.adminKey))) {
      return { authorized: true, authType: 'admin_key' };
    }

    if (bearer) {
      const payload = verifyToken(bearer, sessionSecret);
      if (payload && payload.typ === 'node_probe') {
        return { authorized: true, authType: 'node_probe', payload };
      }
    }

    return { authorized: false };
  }

  function computeGatewayAssignedForNode(nodeId) {
    let assignedUserCount = 0;
    let assignedQuotaBytes = 0;
    if (!userDirectory || !nodeId) {
      return { assignedUserCount, assignedQuotaBytes };
    }
    const seenFolders = new Set();
    for (const user of userDirectory.listAll()) {
      if (!user || user.nodeId !== nodeId) continue;
      assignedUserCount += 1;
      const folderKey = user.folderName && user.folderName !== '__ROOT__' ? user.folderName : `sub:${user.sub}`;
      if (!seenFolders.has(folderKey)) {
        seenFolders.add(folderKey);
        const q = Number(user.quotaBytes) || 0;
        if (q > 0) {
          assignedQuotaBytes += q;
        } else if (config.defaultQuotaBytes > 0) {
          assignedQuotaBytes += Number(config.defaultQuotaBytes) || 0;
        }
      }
    }
    return { assignedUserCount, assignedQuotaBytes };
  }

  function mergeGatewayAssignmentsWithRemoteCapacity(nodeId, remoteCap) {
    const { assignedUserCount, assignedQuotaBytes } = computeGatewayAssignedForNode(nodeId);
    const effectiveUserCount = Math.max(Number(remoteCap.registeredUserCount) || 0, assignedUserCount);
    const effectiveAllocQuota = Math.max(Number(remoteCap.totalAllocatedQuotaBytes) || 0, assignedQuotaBytes);
    const maxUsers = Number(remoteCap.maxUsers) || 0;
    const serverCap = Number(remoteCap.serverCapacityBytes) || 0;
    const incomingQuota = Number(remoteCap.defaultQuotaBytes) || Number(config.defaultQuotaBytes) || 0;

    let isFull = Boolean(remoteCap.isFullForNewUsers);
    let reason = remoteCap.newSignupBlockReason || null;

    if (!isFull && maxUsers > 0 && effectiveUserCount >= maxUsers) {
      isFull = true;
      reason = `Server user limit reached (${effectiveUserCount}/${maxUsers} accounts).`;
    } else if (
      !isFull &&
      serverCap > 0 &&
      incomingQuota > 0 &&
      effectiveAllocQuota + incomingQuota > serverCap
    ) {
      isFull = true;
      reason = `Server assigned storage quota pool is full on ${nodeId}.`;
    }

    return {
      ...remoteCap,
      registeredUserCount: effectiveUserCount,
      totalAllocatedQuotaBytes: effectiveAllocQuota,
      isFullForNewUsers: isFull,
      newSignupBlockReason: reason,
    };
  }

  async function probeStorageNodeCapacity(node, { publicBaseUrl = '' } = {}) {
    const localNodeId = identifyLocalNodeId(config, publicBaseUrl);
    const isSelfByConfigOrOrigin =
      (localNodeId && localNodeId === node.id) ||
      (config.publicUrl && urlsShareOrigin(node.url, config.publicUrl)) ||
      (publicBaseUrl && urlsShareOrigin(node.url, publicBaseUrl));

    if (isSelfByConfigOrOrigin) {
      const summary = await contextService.getServerCapacitySummary({
        localNodeId: node.id,
        publicBaseUrl,
      });
      return {
        node,
        isLocal: true,
        reachable: true,
        capacity: summary,
        error: null,
      };
    }

    const probeToken = signToken(
      { typ: 'node_probe', iss: instanceId, targetNodeId: node.id },
      sessionSecret,
      60
    );

    try {
      const response = await fetch(`${node.url}/api/node/capacity`, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${probeToken}`,
          Accept: 'application/json',
        },
        signal: AbortSignal.timeout(probeTimeoutMs),
      });

      const body = await response.json().catch(() => null);
      if (!response.ok || !body || !body.success || !body.capacity) {
        return {
          node,
          isLocal: false,
          reachable: false,
          capacity: null,
          error: (body && body.error) || `HTTP ${response.status}`,
        };
      }

      if (body.instanceId && body.instanceId === instanceId) {
        const summary = await contextService.getServerCapacitySummary({
          localNodeId: node.id,
          publicBaseUrl,
        });
        return {
          node,
          isLocal: true,
          reachable: true,
          capacity: summary,
          error: null,
        };
      }

      return {
        node,
        isLocal: false,
        reachable: true,
        capacity: mergeGatewayAssignmentsWithRemoteCapacity(node.id, body.capacity),
        error: null,
      };
    } catch (err) {
      return {
        node,
        isLocal: false,
        reachable: false,
        capacity: null,
        error: err && err.message ? err.message : 'Node unreachable',
      };
    }
  }

  async function probeAllStorageNodes({ publicBaseUrl = '' } = {}) {
    const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];
    if (nodes.length === 0) return [];
    return Promise.all(
      nodes.map((node) => probeStorageNodeCapacity(node, { publicBaseUrl }))
    );
  }

  /**
   * Determines whether a Google OAuth login is allowed AND which storage node it should use.
   * - Existing users (or `USER_FOLDERS` entries) are always allowed and keep their existing node.
   * - `USER_NODE_MAP` overrides always pick the mapped node directly.
   * - New unmapped users in multi-node `ordered` mode (default) try nodes in order (`node1`, then `node2`, ...),
   *   automatically spilling over to `node2` whenever `node1` has reached capacity.
   */
  async function resolveNodeAndCapacityForLogin({ sub, email, publicBaseUrl }) {
    const cleanEmail = String(email || '').trim().toLowerCase();
    const existingBySub = userDirectory && sub ? userDirectory.getBySub(sub) : null;
    const existingByEmail = userDirectory && cleanEmail ? userDirectory.getByEmail(cleanEmail) : null;
    const existingUser = existingBySub || existingByEmail || null;
    const configuredFolder = resolveConfiguredUserFolder(cleanEmail, config);
    const isExistingAccount = Boolean(existingUser || configuredFolder.matched);

    const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];

    // 1. Existing accounts never lose access and stay pinned to their existing node (unless overridden by USER_NODE_MAP).
    if (isExistingAccount) {
      const selected = selectNodeForUser({
        sub,
        email: cleanEmail,
        publicBaseUrl,
        config,
        existingNodeId: existingUser ? existingUser.nodeId : null,
      });
      return {
        allowed: true,
        isExistingUser: true,
        preferredNodeId: selected.nodeId,
        resolvedNode: selected,
        reason: null,
      };
    }

    // 2. Single-node / gateway-only mode (`STORAGE_NODES` not configured)
    if (nodes.length === 0) {
      const singleCheck = await contextService.checkNewUserSignupCapacity({
        sub,
        email: cleanEmail,
        publicBaseUrl,
      });
      return {
        allowed: singleCheck.allowed,
        isExistingUser: Boolean(singleCheck.isExistingUser),
        preferredNodeId: 'primary',
        resolvedNode: {
          nodeId: 'primary',
          serverUrl: String(publicBaseUrl || '').replace(/\/+$/, ''),
        },
        reason: singleCheck.reason,
      };
    }

    // 3. Explicit USER_NODE_MAP override honors operator's fixed routing
    if (cleanEmail && config.userNodeMap instanceof Map && config.userNodeMap.has(cleanEmail)) {
      const selected = selectNodeForUser({
        sub,
        email: cleanEmail,
        publicBaseUrl,
        config,
        existingNodeId: null,
      });
      return {
        allowed: true,
        isExistingUser: false,
        preferredNodeId: selected.nodeId,
        resolvedNode: selected,
        reason: null,
      };
    }

    // 4. Optional legacy hash mode: pick deterministic node first, verify capacity if reachable/local
    if (config.nodeAllocationMode === 'hash') {
      const hashed = selectNodeForUser({
        sub,
        email: cleanEmail,
        publicBaseUrl,
        config,
        existingNodeId: null,
      });
      const targetNode = nodes.find((n) => n.id === hashed.nodeId);
      if (targetNode) {
        const probe = await probeStorageNodeCapacity(targetNode, { publicBaseUrl });
        if (probe.reachable && probe.capacity && probe.capacity.isFullForNewUsers) {
          return {
            allowed: false,
            isExistingUser: false,
            preferredNodeId: null,
            resolvedNode: null,
            reason: probe.capacity.newSignupBlockReason || `Storage node ${targetNode.id} is full.`,
          };
        }
      }
      return {
        allowed: true,
        isExistingUser: false,
        preferredNodeId: hashed.nodeId,
        resolvedNode: hashed,
        reason: null,
      };
    }

    // 5. Ordered preference (default): try nodes in order (`node1` -> `node2` -> ...), pick first non-full node
    const failureReasons = [];
    for (const node of nodes) {
      const probe = await probeStorageNodeCapacity(node, { publicBaseUrl });
      if (!probe.reachable || !probe.capacity) {
        failureReasons.push(`${node.id}: unavailable (${probe.error || 'offline'})`);
        continue;
      }
      if (probe.capacity.isFullForNewUsers) {
        failureReasons.push(`${node.id}: ${probe.capacity.newSignupBlockReason || 'full'}`);
        continue;
      }
      return {
        allowed: true,
        isExistingUser: false,
        preferredNodeId: node.id,
        resolvedNode: { nodeId: node.id, serverUrl: node.url },
        reason: null,
      };
    }

    return {
      allowed: false,
      isExistingUser: false,
      preferredNodeId: null,
      resolvedNode: null,
      reason: `All storage nodes are currently full or unavailable (${failureReasons.join('; ')}).`,
    };
  }

  return {
    instanceId,
    verifyNodeProbeAuth,
    probeStorageNodeCapacity,
    probeAllStorageNodes,
    resolveNodeAndCapacityForLogin,
    identifyLocalNodeId: (reqBaseUrl = '') => identifyLocalNodeId(config, reqBaseUrl),
  };
}

module.exports = {
  createNodeAllocationService,
  identifyLocalNodeId,
  normalizeOrigin,
  urlsShareOrigin,
};
