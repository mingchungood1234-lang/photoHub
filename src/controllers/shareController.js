/**
 * PUBLIC & AUTHENTICATED EXPIRING SHARE LINK CONTROLLER
 *
 * Authenticated endpoints:
 *   - `POST /api/shares`       -> creates an expiring, passcode-optional share link (`/s/:token`)
 *   - `GET /api/shares`        -> lists active shares for the signed-in user
 *   - `DELETE /api/shares/:token` -> revokes a share link
 *
 * Public endpoints (no PhotoHub login required):
 *   - `GET /s/:token`                               -> warm-sunset public share viewer webpage
 *   - `GET /api/public/share/:token`                -> share metadata + photo list (checks passcode if protected)
 *   - `GET /api/public/share/:token/preview/:hash`  -> streams preview image for an item in the share
 *   - `GET /api/public/share/:token/download/:hash` -> streams full-resolution original for an item in the share
 */

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const { Readable } = require('stream');
const { isS3Configured, createPresignedUrl } = require('../services/s3Service');
const { isVideoFilename } = require('../services/proxyService');
const {
  streamZipToResponse,
  createDiskReadStream,
  createHttpReadStream,
} = require('../services/zipStreamService');

async function fileExistsAsync(filePath) {
  try {
    await fsp.access(filePath, fs.constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

function resolveInsideStorageDir(storageDir, relativePath) {
  if (!relativePath || typeof relativePath !== 'string') return null;
  const root = path.resolve(storageDir);
  const resolved = path.resolve(root, relativePath);
  if (resolved !== root && !resolved.startsWith(root + path.sep)) {
    return null;
  }
  return resolved;
}

function createShareController({ config, shareStore, contextService, albumStore = null }) {
  const sharePagePath = path.join(__dirname, '..', 'views', 'share.html');

  function findRemoteNodeForToken(token, req) {
    const raw = String(token || '');
    const sepIdx = raw.indexOf('~');
    if (sepIdx <= 0) return null;
    const nodeId = raw.slice(0, sepIdx);
    const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];
    const targetNode = nodes.find((n) => n && n.id === nodeId) || null;
    if (!targetNode) return null;
    const localNodeId = contextService.resolveEffectiveLocalNodeId(
      null,
      contextService.resolveRequestBaseUrl(req)
    );
    if (localNodeId && targetNode.id === localNodeId) return null;
    return targetNode;
  }

  async function proxyPublicShareToNode(req, res, targetNode, remotePath) {
    const queryIdx = req.url.indexOf('?');
    const qs = queryIdx >= 0 ? req.url.slice(queryIdx) : '';
    const upstreamUrl = `${targetNode.url.replace(/\/+$/, '')}${remotePath}${qs}`;
    const headers = {};
    if (req.headers['x-share-passcode']) {
      headers['X-Share-Passcode'] = String(req.headers['x-share-passcode']);
    }
    if (req.headers.range) {
      headers.Range = String(req.headers.range);
    }
    const abortController = new AbortController();
    const timeoutId = setTimeout(() => abortController.abort(), 30_000);
    const onClose = () => {
      if (!res.writableEnded) abortController.abort();
    };
    res.on('close', onClose);
    try {
      const upstreamRes = await fetch(upstreamUrl, {
        method: 'GET',
        headers,
        signal: abortController.signal,
      });
      clearTimeout(timeoutId);
      res.status(upstreamRes.status);
      for (const h of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'content-disposition', 'cache-control']) {
        const val = upstreamRes.headers.get(h);
        if (val !== null) res.setHeader(h, val);
      }
      if (!upstreamRes.body) {
        res.off('close', onClose);
        return res.end();
      }
      const stream = Readable.fromWeb(upstreamRes.body);
      stream.on('error', () => {
        if (!res.writableEnded) res.end();
      });
      res.on('finish', () => res.off('close', onClose));
      return stream.pipe(res);
    } catch {
      clearTimeout(timeoutId);
      res.off('close', onClose);
      if (!res.headersSent) {
        return res.status(502).json({ success: false, error: 'Shared album server is currently unreachable.' });
      }
      return res.end();
    }
  }

  async function resolveContextForShare(share) {
    if (!share.folderName || share.folderName === '__ROOT__') {
      await contextService.ensureDefaultHashIndexReady();
      return {
        storageDir: config.storageDir,
        hashIndex: contextService.defaultHashIndex,
      };
    }
    return contextService.getOrCreateFolderContext(share.folderName);
  }

  function extractPasscode(req) {
    return String(req.headers['x-share-passcode'] || req.query.passcode || '').trim();
  }

  function buildPublicShareUrl(req, token) {
    const base =
      config.publicWebUrl ||
      config.publicUrl ||
      contextService.resolveRequestBaseUrl(req);
    return `${String(base).replace(/\/+$/, '')}/s/${encodeURIComponent(token)}`;
  }

  return {
    getSharePage(req, res) {
      return res.sendFile(sharePagePath, { dotfiles: 'allow' });
    },

    async createShare(req, res) {
      try {
        const { hashIndex, folderName, sub, email, name } = req.userContext;
        const body = req.body || {};
        let rawHashes = Array.isArray(body.hashes)
          ? body.hashes
          : body.hash
            ? [body.hash]
            : [];
        let fallbackTitle = body.title;

        // Support creating a share link directly from an Album ID
        if (body.albumId && albumStore && rawHashes.length === 0) {
          const alb = albumStore.getAlbum(body.albumId, folderName);
          if (!alb) {
            return res.status(404).json({ success: false, error: 'Album not found.' });
          }
          rawHashes = alb.hashes || [];
          if (!fallbackTitle) fallbackTitle = alb.name;
        }

        const verifiedHashes = [];
        for (const h of rawHashes) {
          const found = await hashIndex.lookup(h, { allowStatFastPath: true });
          if (found.status !== 'missing' && found.record && !found.record.deletedAt) {
            verifiedHashes.push(found.masterHash);
          }
        }
        if (verifiedHashes.length === 0) {
          return res.status(400).json({
            success: false,
            error: 'No valid active photos found to share.',
          });
        }

        const localNodeId = contextService.resolveEffectiveLocalNodeId(
          null,
          contextService.resolveRequestBaseUrl(req)
        );
        const created = await shareStore.createShare({
          folderName,
          ownerSub: sub,
          ownerEmail: email,
          ownerName: name,
          title: fallbackTitle,
          hashes: verifiedHashes,
          expiresInHours: body.expiresInHours,
          passcode: body.passcode,
          allowDownload: body.allowDownload !== false,
          maxViews: body.maxViews,
          albumId: body.albumId || null,
          nodeId: localNodeId,
        });

        const publicShareUrl = buildPublicShareUrl(req, created.token);
        return res.status(201).json({
          success: true,
          share: {
            ...created,
            sharePath: `/s/${encodeURIComponent(created.token)}`,
            shareUrl: publicShareUrl,
            url: publicShareUrl,
          },
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({
          success: false,
          error: err.message,
        });
      }
    },

    async updateShare(req, res) {
      try {
        const { folderName } = req.userContext;
        const body = req.body || {};
        const updated = await shareStore.updateShare(req.params.token, folderName, {
          title: body.title,
          allowDownload: body.allowDownload,
          expiresInHours: body.expiresInHours,
          maxViews: body.maxViews,
          passcode: body.passcode,
        });
        if (!updated) {
          return res.status(404).json({ success: false, error: 'Share link not found.' });
        }
        const publicShareUrl = buildPublicShareUrl(req, updated.token);
        return res.json({
          success: true,
          share: {
            ...updated,
            sharePath: `/s/${encodeURIComponent(updated.token)}`,
            shareUrl: publicShareUrl,
            url: publicShareUrl,
          },
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async listShares(req, res) {
      try {
        const { folderName } = req.userContext;
        const items = shareStore.listForFolder(folderName).map((s) => {
          const publicShareUrl = buildPublicShareUrl(req, s.token);
          return {
            ...s,
            sharePath: `/s/${encodeURIComponent(s.token)}`,
            shareUrl: publicShareUrl,
            url: publicShareUrl,
          };
        });
        return res.json({ success: true, shares: items });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async revokeShare(req, res) {
      try {
        const { folderName } = req.userContext;
        const ok = await shareStore.revokeShare(req.params.token, folderName);
        if (!ok) {
          return res.status(404).json({ success: false, error: 'Share link not found.' });
        }
        return res.json({ success: true, revoked: true });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async getPublicShare(req, res) {
      try {
        const token = req.params.token;
        const remoteNode = findRemoteNodeForToken(token, req);
        if (remoteNode) {
          return proxyPublicShareToNode(req, res, remoteNode, `/api/public/share/${encodeURIComponent(token)}`);
        }

        const share = shareStore.getShare(token);
        if (!share) {
          return res.status(404).json({
            success: false,
            error: 'This share link has expired or does not exist.',
          });
        }

        if (shareStore.isViewLimitReached(share)) {
          return res.status(410).json({
            success: false,
            error: 'This share link has reached its maximum view limit.',
          });
        }

        const passcode = extractPasscode(req);
        if (share.passcodeHash && !(await shareStore.verifyPasscodeAsync(share, passcode))) {
          return res.status(401).json({
            success: false,
            requiresPasscode: true,
            title: share.title,
            itemCount: share.hashes.length,
            expiresAt: share.expiresAt,
            error: passcode ? 'Incorrect passcode.' : 'Passcode required.',
          });
        }

        await shareStore.incrementView(share.token);

        const ctx = await resolveContextForShare(share);
        const photos = [];
        for (const h of share.hashes) {
          const found = await ctx.hashIndex.lookup(h, { allowStatFastPath: true });
          if (found.status !== 'missing' && found.record && !found.record.deletedAt) {
            const summary = ctx.hashIndex.formatMasterSummary(found.record, found.masterHash);
            photos.push({
              hash: summary.hash,
              originalName: summary.originalName,
              size: summary.size,
              photoDate: summary.photoDate,
              takenAt: summary.takenAt,
              locationLabel: summary.locationLabel || null,
              isVideo: isVideoFilename(summary.originalName || summary.savedPath || ''),
              hasPreview: summary.hasPreview,
              hasVideoProxy: summary.hasVideoProxy,
            });
          }
        }

        // Always sort shared album items newest-first (matching the main gallery timeline)
        photos.sort((a, b) => {
          const ta = Date.parse(a.takenAt || a.photoDate || '') || 0;
          const tb = Date.parse(b.takenAt || b.photoDate || '') || 0;
          if (tb !== ta) return tb - ta;
          return String(a.originalName || a.hash).localeCompare(String(b.originalName || b.hash));
        });

        return res.json({
          success: true,
          share: {
            token: share.token,
            title: share.title,
            ownerName: share.ownerName || null,
            createdAt: share.createdAt,
            expiresAt: share.expiresAt,
            hasPasscode: Boolean(share.passcodeHash),
            allowDownload: share.allowDownload !== false,
            viewCount: Number(share.viewCount) || 0,
            maxViews: share.maxViews || null,
            itemCount: photos.length,
          },
          photos,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async streamPublicPreview(req, res) {
      try {
        const { token, hash } = req.params;
        const remoteNode = findRemoteNodeForToken(token, req);
        if (remoteNode) {
          return proxyPublicShareToNode(
            req,
            res,
            remoteNode,
            `/api/public/share/${encodeURIComponent(token)}/preview/${encodeURIComponent(hash)}`
          );
        }

        const share = shareStore.getShare(token);
        if (!share) return res.status(404).json({ success: false, error: 'Share expired or not found.' });
        if (share.passcodeHash && !(await shareStore.verifyPasscodeAsync(share, extractPasscode(req)))) {
          return res.status(401).json({ success: false, requiresPasscode: true, error: 'Passcode required.' });
        }
        const normHash = String(hash || '').trim().toLowerCase();
        if (!share.hashes.includes(normHash)) {
          return res.status(404).json({ success: false, error: 'Photo not in this share.' });
        }

        const ctx = await resolveContextForShare(share);
        const found = await ctx.hashIndex.lookup(normHash, { allowStatFastPath: true });
        if (found.status === 'missing' || !found.record || found.record.deletedAt) {
          return res.status(404).json({ success: false, error: 'Photo not found.' });
        }

        const record = found.record;
        if (record.proxyRelativePath) {
          const proxyPath = resolveInsideStorageDir(ctx.storageDir, record.proxyRelativePath);
          if (proxyPath && (await fileExistsAsync(proxyPath))) {
            res.setHeader('Cache-Control', 'public, max-age=3600');
            return res.sendFile(proxyPath, { dotfiles: 'allow' });
          }
        }
        if (isVideoFilename(record.originalName || record.relativePath || '')) {
          return res.status(404).json({ success: false, error: 'Video preview unavailable.' });
        }
        if (record.storageType === 's3' && isS3Configured(config.s3)) {
          const url = createPresignedUrl({
            s3Config: config.s3,
            method: 'GET',
            objectKey: record.relativePath,
            expiresIn: 300,
          });
          return res.redirect(url);
        }
        const fullPath = resolveInsideStorageDir(ctx.storageDir, record.relativePath);
        if (!fullPath || !(await fileExistsAsync(fullPath))) {
          return res.status(404).json({ success: false, error: 'File not found.' });
        }
        res.setHeader('Cache-Control', 'public, max-age=3600');
        return res.sendFile(fullPath, { dotfiles: 'allow' });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async downloadPublicOriginal(req, res) {
      try {
        const { token, hash } = req.params;
        const remoteNode = findRemoteNodeForToken(token, req);
        if (remoteNode) {
          return proxyPublicShareToNode(
            req,
            res,
            remoteNode,
            `/api/public/share/${encodeURIComponent(token)}/download/${encodeURIComponent(hash)}`
          );
        }

        const share = shareStore.getShare(token);
        if (!share) return res.status(404).json({ success: false, error: 'Share expired or not found.' });
        if (share.allowDownload === false) {
          return res.status(403).json({ success: false, error: 'Downloads are disabled for this view-only share link.' });
        }
        if (share.passcodeHash && !(await shareStore.verifyPasscodeAsync(share, extractPasscode(req)))) {
          return res.status(401).json({ success: false, requiresPasscode: true, error: 'Passcode required.' });
        }
        const normHash = String(hash || '').trim().toLowerCase();
        if (!share.hashes.includes(normHash)) {
          return res.status(404).json({ success: false, error: 'Photo not in this share.' });
        }

        const ctx = await resolveContextForShare(share);
        const found = await ctx.hashIndex.lookup(normHash, { allowStatFastPath: true });
        if (found.status === 'missing' || !found.record || found.record.deletedAt) {
          return res.status(404).json({ success: false, error: 'Photo not found.' });
        }

        const record = found.record;
        if (record.storageType === 's3' && isS3Configured(config.s3)) {
          const url = createPresignedUrl({
            s3Config: config.s3,
            method: 'GET',
            objectKey: record.relativePath,
            expiresIn: 300,
          });
          return res.redirect(url);
        }
        const fullPath = resolveInsideStorageDir(ctx.storageDir, record.relativePath);
        if (!fullPath || !(await fileExistsAsync(fullPath))) {
          return res.status(404).json({ success: false, error: 'File not found.' });
        }
        const rawDispName = String(record.originalName || path.basename(fullPath))
          .replace(/[\r\n"\\]/g, '_')
          .slice(0, 180);
        const safeName = encodeURIComponent(rawDispName);
        res.setHeader('Content-Disposition', `attachment; filename="${safeName}"`);
        return res.sendFile(fullPath, { dotfiles: 'allow', acceptRanges: true });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async streamPublicVideo(req, res) {
      try {
        const { token, hash } = req.params;
        const remoteNode = findRemoteNodeForToken(token, req);
        if (remoteNode) {
          return proxyPublicShareToNode(
            req,
            res,
            remoteNode,
            `/api/public/share/${encodeURIComponent(token)}/video/${encodeURIComponent(hash)}`
          );
        }

        const share = shareStore.getShare(token);
        if (!share) return res.status(404).json({ success: false, error: 'Share expired or not found.' });
        if (share.passcodeHash && !(await shareStore.verifyPasscodeAsync(share, extractPasscode(req)))) {
          return res.status(401).json({ success: false, requiresPasscode: true, error: 'Passcode required.' });
        }
        const normHash = String(hash || '').trim().toLowerCase();
        if (!share.hashes.includes(normHash)) {
          return res.status(404).json({ success: false, error: 'Video not in this share.' });
        }

        const ctx = await resolveContextForShare(share);
        const found = await ctx.hashIndex.lookup(normHash, { allowStatFastPath: true });
        if (found.status === 'missing' || !found.record || found.record.deletedAt) {
          return res.status(404).json({ success: false, error: 'Video not found.' });
        }

        const record = found.record;
        if (record.videoProxyRelativePath) {
          const vpPath = resolveInsideStorageDir(ctx.storageDir, record.videoProxyRelativePath);
          if (vpPath && (await fileExistsAsync(vpPath))) {
            res.setHeader('Content-Type', 'video/mp4');
            return res.sendFile(vpPath, { dotfiles: 'allow', acceptRanges: true });
          }
        }
        if (record.storageType === 's3' && isS3Configured(config.s3)) {
          const url = createPresignedUrl({
            s3Config: config.s3,
            method: 'GET',
            objectKey: record.relativePath,
            expiresIn: 300,
          });
          return res.redirect(url);
        }
        const fullPath = resolveInsideStorageDir(ctx.storageDir, record.relativePath);
        if (!fullPath || !(await fileExistsAsync(fullPath))) {
          return res.status(404).json({ success: false, error: 'File not found.' });
        }
        return res.sendFile(fullPath, { dotfiles: 'allow', acceptRanges: true });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async downloadPublicZip(req, res) {
      try {
        const { token } = req.params;
        const remoteNode = findRemoteNodeForToken(token, req);
        if (remoteNode) {
          return proxyPublicShareToNode(
            req,
            res,
            remoteNode,
            `/api/public/share/${encodeURIComponent(token)}/download-zip`
          );
        }

        const share = shareStore.getShare(token);
        if (!share) return res.status(404).json({ success: false, error: 'Share expired or not found.' });
        if (share.allowDownload === false) {
          return res.status(403).json({ success: false, error: 'Downloads are disabled for this view-only share link.' });
        }
        if (share.passcodeHash && !(await shareStore.verifyPasscodeAsync(share, extractPasscode(req)))) {
          return res.status(401).json({ success: false, requiresPasscode: true, error: 'Passcode required.' });
        }

        const ctx = await resolveContextForShare(share);
        const entries = [];
        for (const h of share.hashes) {
          const found = await ctx.hashIndex.lookup(h, { allowStatFastPath: true });
          if (found.status === 'missing' || !found.record || found.record.deletedAt) continue;
          const record = found.record;
          const entryDate = record.takenAt
            ? new Date(record.takenAt)
            : record.uploadedAt
              ? new Date(record.uploadedAt)
              : new Date();
          const name = record.originalName || path.basename(record.relativePath || `${found.masterHash.slice(0, 12)}.bin`);

          if (record.storageType === 's3' && isS3Configured(config.s3)) {
            entries.push({
              name,
              date: entryDate,
              openStream: () => {
                const url = createPresignedUrl({
                  s3Config: config.s3,
                  method: 'GET',
                  objectKey: record.relativePath,
                  expiresIn: 300,
                });
                return createHttpReadStream(url);
              },
            });
          } else if (record.relativePath) {
            const fullPath = resolveInsideStorageDir(ctx.storageDir, record.relativePath);
            if (fullPath && (await fileExistsAsync(fullPath))) {
              entries.push({
                name,
                date: entryDate,
                openStream: async () => createDiskReadStream(fullPath),
              });
            }
          }
        }

        if (entries.length === 0) {
          return res.status(404).json({ success: false, error: 'No downloadable files found in this share.' });
        }

        const safeSlug =
          String(share.title || 'PhotoHub-Share')
            .replace(/[^a-zA-Z0-9._-]+/g, '-')
            .replace(/^-+|-+$/g, '')
            .slice(0, 48) || 'PhotoHub-Share';
        res.setHeader('Content-Type', 'application/zip');
        res.setHeader('Content-Disposition', `attachment; filename="${safeSlug}.zip"`);
        res.setHeader('Cache-Control', 'no-store');
        return streamZipToResponse(res, entries);
      } catch (err) {
        if (!res.headersSent) {
          return res.status(500).json({ success: false, error: err.message });
        }
        return res.end();
      }
    },
  };
}

module.exports = { createShareController };
