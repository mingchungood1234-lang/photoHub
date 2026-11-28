/**
 * ASYNCHRONOUS BACKGROUND PROXY & VISUAL-INDEX QUEUE
 *
 * Automatically generates lightweight server-side preview proxies (JPEG / MP4 poster+proxy)
 * and visual fingerprints (`dHash`, `blurScore`) in the background right after Web or Chunked
 * uploads complete — without delaying the HTTP upload response.
 */

const fs = require('fs');
const fsp = require('fs/promises');
const os = require('os');
const path = require('path');
const {
  isVideoFilename,
  getCapabilities,
  generateServerSideProxy,
} = require('./proxyService');
const { analyzePhotoFile } = require('./mediaAnalysisService');
const {
  isS3Configured,
  isPrimaryS3Backend,
  buildS3ProxyKey,
  uploadFileToS3,
  downloadS3ObjectToFile,
} = require('./s3Service');

const MAX_RECENT_JOBS = 25;

class ProxyQueueService {
  constructor({ concurrency = 2, config = null } = {}) {
    this.concurrency = Math.max(1, Number(concurrency) || 2);
    this.config = config;
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
      rawFolderName: folderName || null,
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
    const s3Ready = Boolean(this.config && isS3Configured(this.config.s3));
    let count = 0;
    const unique = hashIndex._getUniqueMasterRecords();
    for (const { canonicalHash, entry } of unique) {
      if (count >= limit) break;
      if (entry.storageType === 's3' && !s3Ready) continue;
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
    let tmpWorkDir = null;
    try {
      const lookup = await job.hashIndex.lookup(job.masterHash, { allowStatFastPath: true });
      if (lookup.status === 'missing' || !lookup.record || lookup.record.deletedAt) {
        this.stats.skipped += 1;
        return;
      }

      const record = lookup.record;
      if (!record.relativePath) {
        this.stats.skipped += 1;
        return;
      }

      const isMasterS3 = record.storageType === 's3';
      const s3Config = this.config && isS3Configured(this.config.s3) ? this.config.s3 : null;
      if (isMasterS3 && !s3Config) {
        this.stats.skipped += 1;
        return;
      }

      const storeInS3 = Boolean(s3Config && (isPrimaryS3Backend(this.config) || isMasterS3));
      const isVid = isVideoFilename(record.originalName || record.relativePath || '');
      const needsProxy = isVid
        ? !record.proxyRelativePath || !record.videoProxyRelativePath
        : !record.proxyRelativePath;
      const needsMetrics =
        !isVid && (typeof record.dHash !== 'string' || typeof record.blurScore !== 'number');

      if (!needsProxy && !needsMetrics) {
        this.stats.skipped += 1;
        return;
      }

      let fullPath = null;
      if (isMasterS3 || storeInS3 || record.proxyStorageType === 's3') {
        tmpWorkDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'photohub-queue-'));
      }

      const ensureSourceFile = async () => {
        if (fullPath) return fullPath;
        if (isMasterS3) {
          const safeSrcName = path
            .basename(record.originalName || record.relativePath || 'source.bin')
            .replace(/[<>:"/\\|?*\x00-\x1F]/g, '_');
          const dest = path.join(tmpWorkDir, safeSrcName);
          await downloadS3ObjectToFile({
            s3Config,
            objectKey: record.relativePath,
            destPath: dest,
          });
          fullPath = dest;
          return fullPath;
        }
        const diskPath = path.join(job.storageDir, record.relativePath);
        if (!fs.existsSync(diskPath)) return null;
        fullPath = diskPath;
        return fullPath;
      };

      let didWork = false;
      let localProxyPathForAnalysis = null;

      if (needsProxy) {
        const sourcePath = await ensureSourceFile();
        if (!sourcePath) {
          this.stats.skipped += 1;
          return;
        }
        const proxiesDir = storeInS3
          ? path.join(tmpWorkDir, '.proxies')
          : path.join(job.storageDir, '.proxies');
        try {
          const generated = await generateServerSideProxy({
            sourcePath,
            proxiesDir,
            masterHash: lookup.masterHash,
            originalName: record.originalName || sourcePath,
            quality: 0.76,
          });

          const proxyMeta = { ...generated };
          if (storeInS3) {
            if (generated.proxyRelativePath) {
              const localImgProxy = path.join(proxiesDir, path.basename(generated.proxyRelativePath));
              localProxyPathForAnalysis = localImgProxy;
              const ext = path.extname(localImgProxy) || '.jpg';
              const s3ImgKey = buildS3ProxyKey({
                folderName: job.rawFolderName,
                masterHash: lookup.masterHash,
                ext,
                prefix: s3Config.prefix,
              });
              await uploadFileToS3({
                s3Config,
                objectKey: s3ImgKey,
                filePath: localImgProxy,
                contentType: ext === '.heic' ? 'image/heic' : 'image/jpeg',
              });
              proxyMeta.proxyRelativePath = s3ImgKey;
              proxyMeta.proxyStorageType = 's3';
            }
            if (generated.videoProxyRelativePath) {
              const localVidProxy = path.join(proxiesDir, path.basename(generated.videoProxyRelativePath));
              const s3VidKey = buildS3ProxyKey({
                folderName: job.rawFolderName,
                masterHash: lookup.masterHash,
                ext: '.mp4',
                prefix: s3Config.prefix,
              });
              await uploadFileToS3({
                s3Config,
                objectKey: s3VidKey,
                filePath: localVidProxy,
                contentType: 'video/mp4',
              });
              proxyMeta.videoProxyRelativePath = s3VidKey;
              proxyMeta.videoProxyStorageType = 's3';
            }
          } else {
            if (proxyMeta.proxyRelativePath) {
              proxyMeta.proxyStorageType = 'disk';
              localProxyPathForAnalysis = path.join(job.storageDir, proxyMeta.proxyRelativePath);
            }
            if (proxyMeta.videoProxyRelativePath) {
              proxyMeta.videoProxyStorageType = 'disk';
            }
          }

          await job.hashIndex.registerProxy(
            lookup.masterHash,
            proxyMeta.proxyHash,
            record.assetId || '',
            proxyMeta
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
      if (needsMetrics) {
        let analysisPath = localProxyPathForAnalysis;
        if (!analysisPath && record.proxyRelativePath) {
          if (record.proxyStorageType === 's3' && s3Config) {
            const proxyExt = path.extname(record.proxyRelativePath) || '.jpg';
            const tmpProxy = path.join(tmpWorkDir, `proxy_analyze${proxyExt}`);
            await downloadS3ObjectToFile({
              s3Config,
              objectKey: record.proxyRelativePath,
              destPath: tmpProxy,
            }).catch(() => {});
            if (fs.existsSync(tmpProxy)) analysisPath = tmpProxy;
          } else {
            const candidate = path.join(job.storageDir, record.proxyRelativePath);
            if (fs.existsSync(candidate)) analysisPath = candidate;
          }
        }
        if (!analysisPath) {
          analysisPath = await ensureSourceFile();
        }
        if (analysisPath) {
          const metrics = await analyzePhotoFile(analysisPath, record.originalName);
          if (metrics) {
            await job.hashIndex.updateVisualMetrics(lookup.masterHash, metrics);
            didWork = true;
          }
        }
      }

      if (didWork) {
        this.stats.completed += 1;
        this._recordJob({
          status: 'completed',
          masterHash: lookup.masterHash.slice(0, 12),
          fileName: record.originalName || path.basename(record.relativePath),
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
    } finally {
      if (tmpWorkDir) {
        await fsp.rm(tmpWorkDir, { recursive: true, force: true }).catch(() => {});
      }
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
