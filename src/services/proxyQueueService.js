/**
 * ASYNCHRONOUS BACKGROUND PROXY & VISUAL-INDEX QUEUE
 *
 * Automatically generates lightweight server-side preview proxies (JPEG / MP4 poster+proxy)
 * and visual fingerprints (`dHash`, `blurScore`) in the background right after Web or Chunked
 * uploads complete — without delaying the HTTP upload response.
 */

const fs = require('fs');
const path = require('path');
const {
  isVideoFilename,
  getCapabilities,
  generateServerSideProxy,
} = require('./proxyService');
const { analyzePhotoFile } = require('./mediaAnalysisService');

const MAX_RECENT_JOBS = 25;

class ProxyQueueService {
  constructor({ concurrency = 2 } = {}) {
    this.concurrency = Math.max(1, Number(concurrency) || 2);
    this.queue = [];
    this.pendingKeys = new Set();
    this.activeCount = 0;
    this.stats = {
      enqueued: 0,
      completed: 0,
      skipped: 0,
      failed: 0,
    };
    this.recentJobs = [];
    this._idleWaiters = [];
  }

  _recordJob(entry) {
    this.recentJobs.unshift({
      ...entry,
      finishedAt: new Date().toISOString(),
    });
    if (this.recentJobs.length > MAX_RECENT_JOBS) {
      this.recentJobs.length = MAX_RECENT_JOBS;
    }
  }

  _notifyIdleIfNeeded() {
    if (this.activeCount === 0 && this.queue.length === 0 && this._idleWaiters.length > 0) {
      const waiters = this._idleWaiters.splice(0);
      for (const resolve of waiters) resolve();
    }
  }

  enqueue({ hashIndex, storageDir, folderName = null, masterHash, originalName = '', source = 'web' }) {
    const normHash = String(masterHash || '').trim().toLowerCase();
    if (!hashIndex || !storageDir || !normHash) return false;

    const jobKey = `${storageDir}|${normHash}`;
    if (this.pendingKeys.has(jobKey)) return false;
    this.pendingKeys.add(jobKey);
    this.stats.enqueued += 1;

    this.queue.push({
      jobKey,
      hashIndex,
      storageDir,
      folderName: folderName || '/',
      masterHash: normHash,
      originalName,
      source,
      enqueuedAt: new Date().toISOString(),
    });

    this._drain();
    return true;
  }

  enqueueMissingForContext({ hashIndex, storageDir, folderName = null }, { limit = 500 } = {}) {
    if (!hashIndex || !storageDir) return 0;
    let count = 0;
    const unique = hashIndex._getUniqueMasterRecords();
    for (const { canonicalHash, entry } of unique) {
      if (count >= limit) break;
      if (entry.storageType === 's3') continue;
      const isVid = isVideoFilename(entry.originalName || entry.relativePath || '');
      const needsProxy = isVid
        ? !entry.proxyRelativePath || !entry.videoProxyRelativePath
        : !entry.proxyRelativePath || typeof entry.dHash !== 'string';
      if (!needsProxy) continue;
      if (
        this.enqueue({
          hashIndex,
          storageDir,
          folderName,
          masterHash: canonicalHash,
          originalName: entry.originalName || '',
          source: 'backfill',
        })
      ) {
        count += 1;
      }
    }
    return count;
  }

  _drain() {
    while (this.activeCount < this.concurrency && this.queue.length > 0) {
      const job = this.queue.shift();
      this.activeCount += 1;
      this._processJob(job)
        .catch(() => {})
        .finally(() => {
          this.pendingKeys.delete(job.jobKey);
          this.activeCount -= 1;
          this._drain();
          this._notifyIdleIfNeeded();
        });
    }
  }

  async _processJob(job) {
    const startedAt = Date.now();
    try {
      const lookup = await job.hashIndex.lookup(job.masterHash, { allowStatFastPath: true });
      if (lookup.status === 'missing' || !lookup.record || lookup.record.deletedAt) {
        this.stats.skipped += 1;
        return;
      }

      const record = lookup.record;
      if (record.storageType === 's3' || !record.relativePath) {
        this.stats.skipped += 1;
        return;
      }

      const fullPath = path.join(job.storageDir, record.relativePath);
      if (!fs.existsSync(fullPath)) {
        this.stats.skipped += 1;
        return;
      }

      const isVid = isVideoFilename(record.originalName || record.relativePath || '');
      let didWork = false;

      const needsProxy = isVid
        ? !record.proxyRelativePath || !record.videoProxyRelativePath
        : !record.proxyRelativePath;

      if (needsProxy) {
        const proxiesDir = path.join(job.storageDir, '.proxies');
        try {
          const generated = await generateServerSideProxy({
            sourcePath: fullPath,
            proxiesDir,
            masterHash: lookup.masterHash,
            originalName: record.originalName || fullPath,
            quality: 0.76,
          });
          await job.hashIndex.registerProxy(
            lookup.masterHash,
            generated.proxyHash,
            record.assetId || '',
            generated
          );
          didWork = true;
        } catch (proxyErr) {
          // Graceful skip if ffmpeg/sharp isn't installed for this format
          if (!proxyErr || !proxyErr.fallbackToClient) {
            throw proxyErr;
          }
        }
      }

      // Compute perceptual dHash + sharpness blurScore for photos so Smart Cleanup is instant
      if (!isVid && (typeof record.dHash !== 'string' || typeof record.blurScore !== 'number')) {
        const analysisPath =
          record.proxyRelativePath && fs.existsSync(path.join(job.storageDir, record.proxyRelativePath))
            ? path.join(job.storageDir, record.proxyRelativePath)
            : fullPath;
        const metrics = await analyzePhotoFile(analysisPath, record.originalName);
        if (metrics) {
          await job.hashIndex.updateVisualMetrics(lookup.masterHash, metrics);
          didWork = true;
        }
      }

      if (didWork) {
        this.stats.completed += 1;
        this._recordJob({
          status: 'completed',
          masterHash: lookup.masterHash.slice(0, 12),
          fileName: record.originalName || path.basename(fullPath),
          folderName: job.folderName,
          source: job.source,
          durationMs: Date.now() - startedAt,
        });
      } else {
        this.stats.skipped += 1;
      }
    } catch (err) {
      this.stats.failed += 1;
      this._recordJob({
        status: 'failed',
        masterHash: job.masterHash.slice(0, 12),
        fileName: job.originalName || job.masterHash.slice(0, 12),
        folderName: job.folderName,
        source: job.source,
        error: err && err.message ? err.message.slice(0, 180) : 'Unknown error',
        durationMs: Date.now() - startedAt,
      });
    }
  }

  async getStatus() {
    const capabilities = await getCapabilities();
    return {
      queued: this.queue.length,
      active: this.activeCount,
      ...this.stats,
      capabilities,
      recentJobs: this.recentJobs.slice(0, 15),
    };
  }

  waitForIdle(timeoutMs = 10000) {
    if (this.activeCount === 0 && this.queue.length === 0) {
      return Promise.resolve();
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        const idx = this._idleWaiters.indexOf(onDone);
        if (idx >= 0) this._idleWaiters.splice(idx, 1);
        resolve();
      }, timeoutMs);
      const onDone = () => {
        clearTimeout(timer);
        resolve();
      };
      this._idleWaiters.push(onDone);
    });
  }
}

module.exports = { ProxyQueueService };
