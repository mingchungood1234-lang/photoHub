/**
 * RESUMABLE CHUNKED UPLOAD SERVICE (Large 4K Videos & Unstable Networks)
 *
 * Stores incoming chunks under `<storageDir>/.chunked-uploads/<uploadId>/parts/<idx>.part`
 * so interrupted uploads resume seamlessly without re-uploading completed chunks.
 * On completion, streams chunks sequentially into a single staging file while computing
 * full-file SHA-256 on the fly (zero full-file RAM buffering), enforces quota/disk/proxy guards,
 * verifies on disk, indexes into `HashIndex`, and cleans up all temporary chunk files.
 */

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const {
  assertWithinQuota,
  sanitizeFilename,
  parseDateFolder,
  finalizeStagedUpload,
} = require('./storageService');

const DEFAULT_CHUNK_SIZE = 5 * 1024 * 1024; // 5 MB
const MIN_CHUNK_SIZE = 256 * 1024; // 256 KB
const MAX_CHUNK_SIZE = 32 * 1024 * 1024; // 32 MB
const MAX_CHUNKS_PER_SESSION = 5000;
const SESSION_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours

class ChunkedUploadService {
  constructor() {
    this.sessions = new Map(); // uploadId -> sessionRecord
  }

  _sessionDir(storageDir, uploadId) {
    return path.join(storageDir, '.chunked-uploads', uploadId);
  }

  _partsDir(storageDir, uploadId) {
    return path.join(this._sessionDir(storageDir, uploadId), 'parts');
  }

  _metaPath(storageDir, uploadId) {
    return path.join(this._sessionDir(storageDir, uploadId), 'session.json');
  }

  _partPath(storageDir, uploadId, chunkIndex) {
    const padded = String(chunkIndex).padStart(6, '0');
    return path.join(this._partsDir(storageDir, uploadId), `${padded}.part`);
  }

  async _saveSessionMeta(session) {
    const dir = this._sessionDir(session.storageDir, session.uploadId);
    await fsp.mkdir(this._partsDir(session.storageDir, session.uploadId), { recursive: true });
    const tmp = `${this._metaPath(session.storageDir, session.uploadId)}.tmp`;
    const serializable = {
      uploadId: session.uploadId,
      folderName: session.folderName,
      fileName: session.fileName,
      mimeType: session.mimeType,
      fileSize: session.fileSize,
      chunkSize: session.chunkSize,
      totalChunks: session.totalChunks,
      expectedHash: session.expectedHash,
      strictChecksum: session.strictChecksum,
      createdAt: session.createdAt,
      gpsLat: session.gpsLat,
      gpsLng: session.gpsLng,
      locationLabel: session.locationLabel,
      uploadedChunks: Array.from(session.chunkSizes.entries()),
      startedAt: session.startedAt,
      updatedAt: session.updatedAt,
    };
    await fsp.writeFile(tmp, JSON.stringify(serializable), 'utf8');
    await fsp.rename(tmp, this._metaPath(session.storageDir, session.uploadId));
  }

  async _tryLoadSessionFromDisk(storageDir, uploadId, folderName) {
    if (!/^[a-zA-Z0-9_-]{8,64}$/.test(String(uploadId || ''))) return null;
    try {
      const raw = await fsp.readFile(this._metaPath(storageDir, uploadId), 'utf8');
      const parsed = JSON.parse(raw);
      if (!parsed || (parsed.folderName || null) !== (folderName || null)) return null;
      const chunkSizes = new Map();
      for (const [idx, sz] of parsed.uploadedChunks || []) {
        const pPath = this._partPath(storageDir, uploadId, idx);
        if (fs.existsSync(pPath)) {
          chunkSizes.set(Number(idx), Number(sz) || 0);
        }
      }
      const session = {
        ...parsed,
        storageDir,
        chunkSizes,
      };
      this.sessions.set(uploadId, session);
      return session;
    } catch {
      return null;
    }
  }

  async _getSession(uploadId, storageDir, folderName) {
    const cleanId = String(uploadId || '').trim();
    let session = this.sessions.get(cleanId);
    if (!session) {
      session = await this._tryLoadSessionFromDisk(storageDir, cleanId, folderName);
    }
    if (!session || (session.folderName || null) !== (folderName || null)) {
      return null;
    }
    return session;
  }

  formatSessionStatus(session) {
    const uploadedChunks = Array.from(session.chunkSizes.keys()).sort((a, b) => a - b);
    let receivedBytes = 0;
    for (const sz of session.chunkSizes.values()) receivedBytes += sz;
    const progressPct =
      session.fileSize > 0 ? Math.min(100, Math.round((receivedBytes / session.fileSize) * 100)) : 0;
    return {
      uploadId: session.uploadId,
      folderName: session.folderName || '/',
      fileName: session.fileName,
      mimeType: session.mimeType,
      fileSize: session.fileSize,
      chunkSize: session.chunkSize,
      totalChunks: session.totalChunks,
      uploadedChunks,
      uploadedCount: uploadedChunks.length,
      receivedBytes,
      progressPct,
      startedAt: session.startedAt,
      updatedAt: session.updatedAt,
    };
  }

  async initSession({
    storageDir,
    hashIndex,
    folderName = null,
    quotaBytes = 0,
    minFreeDiskBytes = 0,
    maxFileSizeBytes = 0,
    fileName,
    mimeType = 'application/octet-stream',
    fileSize,
    chunkSize = DEFAULT_CHUNK_SIZE,
    expectedHash = '',
    strictChecksum = false,
    createdAt = '',
    gpsLat = null,
    gpsLng = null,
    locationLabel = null,
    resumeUploadId = null,
  }) {
    await this.cleanupStaleSessions();

    const sizeNum = Number(fileSize);
    if (!Number.isFinite(sizeNum) || sizeNum <= 0) {
      const err = new Error('Valid positive "fileSize" is required.');
      err.statusCode = 400;
      throw err;
    }
    if (maxFileSizeBytes > 0 && sizeNum > maxFileSizeBytes) {
      const err = new Error('Uploaded file exceeds maximum upload size.');
      err.statusCode = 413;
      throw err;
    }

    const cleanHash = String(expectedHash || '').trim().toLowerCase();
    // Fast duplicate / proxy dedupe check before transferring a single chunk
    if (cleanHash && cleanHash.length === 64) {
      const lookup = await hashIndex.lookup(cleanHash, { allowStatFastPath: true });
      if (lookup.status !== 'missing' && lookup.record) {
        const isProxy = lookup.status === 'proxy';
        const isProtected = Boolean(lookup.record.keepOriginalOnDevice);
        return {
          alreadyExists: true,
          isDuplicate: true,
          isProxy,
          status: isProxy ? 'existing_proxy' : 'duplicate_verified',
          canDelete: !isProxy && !isProtected,
          canReplaceWithProxy: !isProxy && !isProtected,
          checksumVerified: !isProxy,
          hash: cleanHash,
          masterHash: lookup.masterHash,
          serverSha256: lookup.masterHash,
          savedPath: lookup.record.relativePath,
          originalName: lookup.record.originalName,
          size: lookup.record.size,
        };
      }
    }

    assertWithinQuota(hashIndex, quotaBytes, sizeNum);

    // Resume explicitly requested uploadId OR match an existing in-progress session for the same file
    if (resumeUploadId) {
      const existing = await this._getSession(resumeUploadId, storageDir, folderName);
      if (existing && existing.fileSize === sizeNum) {
        return {
          alreadyExists: false,
          resumed: true,
          ...this.formatSessionStatus(existing),
        };
      }
    }

    const safeName = sanitizeFilename(fileName, mimeType, cleanHash || crypto.randomBytes(8).toString('hex'));
    for (const existing of this.sessions.values()) {
      if (
        (existing.folderName || null) === (folderName || null) &&
        existing.fileSize === sizeNum &&
        existing.fileName === safeName &&
        ((cleanHash && existing.expectedHash === cleanHash) || (!cleanHash && !existing.expectedHash))
      ) {
        return {
          alreadyExists: false,
          resumed: true,
          ...this.formatSessionStatus(existing),
        };
      }
    }

    const safeChunkSize = Math.min(
      MAX_CHUNK_SIZE,
      Math.max(MIN_CHUNK_SIZE, Math.round(Number(chunkSize) || DEFAULT_CHUNK_SIZE))
    );
    const totalChunks = Math.ceil(sizeNum / safeChunkSize);
    if (totalChunks < 1 || totalChunks > MAX_CHUNKS_PER_SESSION) {
      const err = new Error(`Chunk count (${totalChunks}) exceeds allowed limit (${MAX_CHUNKS_PER_SESSION}).`);
      err.statusCode = 400;
      throw err;
    }

    const uploadId = `chk_${Date.now().toString(36)}_${crypto.randomBytes(8).toString('hex')}`;
    const nowIso = new Date().toISOString();
    const session = {
      uploadId,
      storageDir,
      folderName: folderName || null,
      fileName: safeName,
      mimeType: String(mimeType || 'application/octet-stream'),
      fileSize: sizeNum,
      chunkSize: safeChunkSize,
      totalChunks,
      expectedHash: cleanHash,
      strictChecksum: Boolean(strictChecksum),
      createdAt: String(createdAt || ''),
      gpsLat: gpsLat !== undefined && gpsLat !== null ? Number(gpsLat) : null,
      gpsLng: gpsLng !== undefined && gpsLng !== null ? Number(gpsLng) : null,
      locationLabel: locationLabel ? String(locationLabel).trim().slice(0, 120) : null,
      minFreeDiskBytes: Number(minFreeDiskBytes) || 0,
      chunkSizes: new Map(),
      startedAt: nowIso,
      updatedAt: nowIso,
    };

    this.sessions.set(uploadId, session);
    await this._saveSessionMeta(session);

    return {
      alreadyExists: false,
      resumed: false,
      ...this.formatSessionStatus(session),
    };
  }

  async getSessionStatus({ uploadId, storageDir, folderName = null }) {
    const session = await this._getSession(uploadId, storageDir, folderName);
    if (!session) return null;
    return this.formatSessionStatus(session);
  }

  async writeChunkStream({
    uploadId,
    chunkIndex,
    req,
    storageDir,
    folderName = null,
    expectedChunkSha256 = '',
  }) {
    const session = await this._getSession(uploadId, storageDir, folderName);
    if (!session) {
      const err = new Error('Chunked upload session not found or expired.');
      err.statusCode = 404;
      throw err;
    }

    const idx = Number(chunkIndex);
    if (!Number.isInteger(idx) || idx < 0 || idx >= session.totalChunks) {
      const err = new Error(`Invalid chunk index ${chunkIndex} (expected 0..${session.totalChunks - 1}).`);
      err.statusCode = 400;
      throw err;
    }

    await fsp.mkdir(this._partsDir(storageDir, session.uploadId), { recursive: true });
    const partPath = this._partPath(storageDir, session.uploadId, idx);
    const tmpPath = `${partPath}.${crypto.randomBytes(4).toString('hex')}.tmp`;

    const maxAllowedPartBytes = session.chunkSize + 64 * 1024;
    const hasher = expectedChunkSha256 ? crypto.createHash('sha256') : null;
    let received = 0;

    try {
      await new Promise((resolve, reject) => {
        const ws = fs.createWriteStream(tmpPath, { highWaterMark: 256 * 1024 });
        let settled = false;
        const fail = (err) => {
          if (settled) return;
          settled = true;
          req.unpipe(ws);
          ws.destroy();
          reject(err);
        };
        ws.on('error', fail);
        req.on('error', fail);
        req.on('aborted', () => {
          const e = new Error('Chunk upload aborted');
          e.statusCode = 400;
          fail(e);
        });
        req.on('data', (chunk) => {
          received += chunk.length;
          if (received > maxAllowedPartBytes) {
            const e = new Error('Chunk exceeds negotiated chunkSize');
            e.statusCode = 413;
            fail(e);
            return;
          }
          if (hasher) hasher.update(chunk);
        });
        ws.on('finish', () => {
          if (settled) return;
          settled = true;
          resolve();
        });
        req.pipe(ws);
      });

      if (received <= 0) {
        const err = new Error('Empty chunk body.');
        err.statusCode = 400;
        throw err;
      }

      const cleanExpected = String(expectedChunkSha256 || '').trim().toLowerCase();
      if (cleanExpected && hasher) {
        const actualChunkSha = hasher.digest('hex');
        if (actualChunkSha !== cleanExpected) {
          const err = new Error(`Chunk ${idx} SHA-256 mismatch.`);
          err.statusCode = 422;
          throw err;
        }
      }

      await fsp.rename(tmpPath, partPath);
      session.chunkSizes.set(idx, received);
      session.updatedAt = new Date().toISOString();
      await this._saveSessionMeta(session);

      return {
        chunkIndex: idx,
        chunkBytes: received,
        ...this.formatSessionStatus(session),
      };
    } catch (err) {
      await fsp.unlink(tmpPath).catch(() => {});
      throw err;
    }
  }

  async completeSession({
    uploadId,
    storageDir,
    hashIndex,
    folderName = null,
    quotaBytes = 0,
    minFreeDiskBytes = 0,
    expectedHash = '',
    strictChecksum = false,
  }) {
    const session = await this._getSession(uploadId, storageDir, folderName);
    if (!session) {
      const err = new Error('Chunked upload session not found or expired.');
      err.statusCode = 404;
      throw err;
    }

    const missingChunks = [];
    for (let i = 0; i < session.totalChunks; i++) {
      const pPath = this._partPath(storageDir, session.uploadId, i);
      if (!fs.existsSync(pPath)) {
        missingChunks.push(i);
      }
    }
    if (missingChunks.length > 0) {
      const err = new Error(`Cannot complete upload: missing ${missingChunks.length} chunk(s).`);
      err.statusCode = 400;
      err.missingChunks = missingChunks.slice(0, 50);
      throw err;
    }

    const stagingPath = path.join(
      storageDir,
      `.chunked_assemble_${process.pid}_${Date.now()}_${crypto.randomBytes(4).toString('hex')}.tmp`
    );

    const hasher = crypto.createHash('sha256');
    let assembledBytes = 0;

    try {
      const ws = fs.createWriteStream(stagingPath, { highWaterMark: 512 * 1024 });
      for (let i = 0; i < session.totalChunks; i++) {
        const pPath = this._partPath(storageDir, session.uploadId, i);
        await new Promise((resolve, reject) => {
          const rs = fs.createReadStream(pPath, { highWaterMark: 512 * 1024 });
          rs.on('error', reject);
          rs.on('data', (chunk) => {
            assembledBytes += chunk.length;
            hasher.update(chunk);
            if (!ws.write(chunk)) {
              rs.pause();
              ws.once('drain', () => rs.resume());
            }
          });
          rs.on('end', resolve);
        });
      }
      await new Promise((resolve, reject) => {
        ws.on('error', reject);
        ws.end(resolve);
      });

      const actualHash = hasher.digest('hex');
      const finalExpected = String(expectedHash || session.expectedHash || '').trim().toLowerCase();
      const isStrict = Boolean(strictChecksum || session.strictChecksum);

      const result = await finalizeStagedUpload({
        stagingPath,
        totalBytes: assembledBytes,
        actualHash,
        originalName: session.fileName,
        mimeType: session.mimeType,
        createdAt: session.createdAt,
        expectedHash: finalExpected,
        strictChecksum: isStrict,
        storageDir,
        hashIndex,
        quotaBytes,
        minFreeDiskBytes: minFreeDiskBytes || session.minFreeDiskBytes || 0,
        gpsLat: session.gpsLat,
        gpsLng: session.gpsLng,
        locationLabel: session.locationLabel,
      });

      await this.abortSession({ uploadId: session.uploadId, storageDir, folderName, silent: true });
      return result;
    } catch (err) {
      await fsp.unlink(stagingPath).catch(() => {});
      throw err;
    }
  }

  async abortSession({ uploadId, storageDir, folderName = null, silent = false }) {
    const cleanId = String(uploadId || '').trim();
    const session = this.sessions.get(cleanId) || (storageDir ? await this._tryLoadSessionFromDisk(storageDir, cleanId, folderName) : null);
    if (!session) {
      if (silent) return false;
      return false;
    }
    if (folderName !== undefined && (session.folderName || null) !== (folderName || null)) {
      return false;
    }
    this.sessions.delete(cleanId);
    const dir = this._sessionDir(session.storageDir, cleanId);
    await fsp.rm(dir, { recursive: true, force: true }).catch(() => {});
    return true;
  }

  async adminAbortSession(uploadId) {
    const cleanId = String(uploadId || '').trim();
    const session = this.sessions.get(cleanId);
    if (!session) return false;
    this.sessions.delete(cleanId);
    const dir = this._sessionDir(session.storageDir, cleanId);
    await fsp.rm(dir, { recursive: true, force: true }).catch(() => {});
    return true;
  }

  listActiveSessions() {
    const out = [];
    for (const session of this.sessions.values()) {
      out.push(this.formatSessionStatus(session));
    }
    out.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
    return out;
  }

  async cleanupStaleSessions(maxAgeMs = SESSION_TTL_MS) {
    const cutoff = Date.now() - maxAgeMs;
    for (const [id, session] of this.sessions.entries()) {
      const updatedMs = Date.parse(session.updatedAt || session.startedAt || '') || 0;
      if (updatedMs > 0 && updatedMs < cutoff) {
        this.sessions.delete(id);
        await fsp.rm(this._sessionDir(session.storageDir, id), { recursive: true, force: true }).catch(() => {});
      }
    }
  }
}

module.exports = { ChunkedUploadService, DEFAULT_CHUNK_SIZE };
