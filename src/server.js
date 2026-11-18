const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const multer = require('multer');
const { getConfig } = require('./config');
const { HashIndex } = require('./hashIndex');
const {
  storeAndVerifyPhoto,
  sanitizeFilename,
  parseDateFolder,
} = require('./storage');
const {
  isS3Configured,
  createPresignedUrl,
  verifyS3ObjectChecksum,
} = require('./s3');
const {
  getCapabilities: getProxyCapabilities,
  generateServerSideProxy,
} = require('./proxyWorker');

async function createApp(configOverrides = {}) {
  const config = getConfig(configOverrides);

  // Default (root) HashIndex used when single API_KEY or no auth is configured
  const defaultHashIndex = new HashIndex({
    storageDir: config.storageDir,
    hashIndexFile: config.hashIndexFile,
    scanStorageOnStartup:
      config.userKeyMap.size === 0 ? config.scanStorageOnStartup : false,
  });
  if (config.userKeyMap.size === 0 || config.apiKey) {
    await defaultHashIndex.init();
  }

  // Per-user HashIndex instances for each folder in USER_KEYS
  const folderContexts = new Map(); // folderName -> { folderName, storageDir, hashIndex }
  for (const folderName of new Set(config.userKeyMap.values())) {
    const userStorageDir = path.join(config.storageDir, folderName);
    const fileSlug = folderName.replace(/[^a-zA-Z0-9_-]/g, '_');
    const userHashIndexFile = path.join(
      config.dataDir,
      `hash-index-${fileSlug}.json`
    );
    const userHashIndex = new HashIndex({
      storageDir: userStorageDir,
      hashIndexFile: userHashIndexFile,
      scanStorageOnStartup: config.scanStorageOnStartup,
    });
    await userHashIndex.init();
    folderContexts.set(folderName, {
      folderName,
      storageDir: userStorageDir,
      hashIndex: userHashIndex,
    });
  }

  const app = express();
  app.locals.config = config;
  app.locals.hashIndex = defaultHashIndex;
  app.locals.folderContexts = folderContexts;

  // Parse JSON bodies for /api/check
  app.use(express.json({ limit: '50mb' }));

  // Parse raw binary uploads when Apple Shortcut uses "Request Body: File"
  app.use(
    '/api/upload',
    express.raw({
      type: (req) => {
        const contentType = String(req.headers['content-type'] || '').toLowerCase();
        return (
          !contentType.startsWith('multipart/form-data') &&
          !contentType.startsWith('application/json')
        );
      },
      limit: config.maxFileSizeBytes,
    })
  );

  // Health check endpoint (public so Docker HEALTHCHECK always succeeds)
  app.get('/api/health', (req, res) => {
    let totalIndexed = defaultHashIndex.size();
    for (const ctx of folderContexts.values()) {
      totalIndexed += ctx.hashIndex.size();
    }
    res.json({
      success: true,
      status: 'ok',
      indexedPhotos: totalIndexed,
      configuredUsers: folderContexts.size,
      storageDir: config.storageDir,
      s3Enabled: isS3Configured(config.s3),
    });
  });

  // API Key & Multi-User routing middleware
  app.use('/api', (req, res, next) => {
    const providedKey = String(
      req.headers['x-api-key'] ||
        req.query.apiKey ||
        (req.headers.authorization &&
        req.headers.authorization.startsWith('Bearer ')
          ? req.headers.authorization.slice(7)
          : '') ||
        ''
    ).trim();

    // 1. Check if providedKey matches a user in USER_KEYS
    if (config.userKeyMap.size > 0 && config.userKeyMap.has(providedKey)) {
      const folderName = config.userKeyMap.get(providedKey);
      req.userContext = folderContexts.get(folderName);
      return next();
    }

    // 2. Fallback to single API_KEY if configured
    if (config.apiKey && providedKey === config.apiKey) {
      req.userContext = {
        folderName: null,
        storageDir: config.storageDir,
        hashIndex: defaultHashIndex,
      };
      return next();
    }

    // 3. If neither USER_KEYS nor API_KEY is configured, allow open access to root storageDir
    if (config.userKeyMap.size === 0 && !config.apiKey) {
      req.userContext = {
        folderName: null,
        storageDir: config.storageDir,
        hashIndex: defaultHashIndex,
      };
      return next();
    }

    return res.status(401).json({
      success: false,
      canDelete: false,
      error: 'Unauthorized: Invalid or missing API key',
    });
  });

  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: config.maxFileSizeBytes },
  });

  // Verify API/User key and report which folder this key routes to
  app.get('/api/whoami', (req, res) => {
    const { folderName, hashIndex } = req.userContext;
    return res.json({
      success: true,
      userFolder: folderName || null,
      indexedPhotos: hashIndex.size(),
      s3Enabled: isS3Configured(config.s3),
    });
  });

  // Pre-upload duplicate check by SHA-256 hash (GET or POST)
  app.get('/api/check/:hash', async (req, res) => {
    try {
      const { hashIndex, folderName } = req.userContext;
      const lookupResult = await hashIndex.lookup(req.params.hash);
      const record = lookupResult.record;
      const exists = lookupResult.status !== 'missing';
      return res.json({
        success: true,
        exists,
        isMaster: lookupResult.status === 'master',
        isProxy: lookupResult.status === 'proxy',
        canDelete: exists,
        canReplaceWithProxy: lookupResult.status === 'master',
        masterHash: lookupResult.masterHash,
        userFolder: folderName,
        hash: String(req.params.hash || '').trim().toLowerCase(),
        savedPath: record ? record.relativePath : null,
      });
    } catch (err) {
      return res.status(500).json({
        success: false,
        exists: false,
        canDelete: false,
        canReplaceWithProxy: false,
        error: err.message,
      });
    }
  });

  app.post('/api/check', async (req, res) => {
    try {
      const hash = req.body && (req.body.hash || req.body.sha256);
      if (!hash || typeof hash !== 'string') {
        return res.status(400).json({
          success: false,
          exists: false,
          canDelete: false,
          canReplaceWithProxy: false,
          error: 'Missing "hash" field in JSON body',
        });
      }
      const { hashIndex, folderName } = req.userContext;
      const lookupResult = await hashIndex.lookup(hash);
      const record = lookupResult.record;
      const exists = lookupResult.status !== 'missing';
      return res.json({
        success: true,
        exists,
        isMaster: lookupResult.status === 'master',
        isProxy: lookupResult.status === 'proxy',
        canDelete: exists,
        canReplaceWithProxy: lookupResult.status === 'master',
        masterHash: lookupResult.masterHash,
        userFolder: folderName,
        hash: hash.trim().toLowerCase(),
        savedPath: record ? record.relativePath : null,
      });
    } catch (err) {
      return res.status(500).json({
        success: false,
        exists: false,
        canDelete: false,
        canReplaceWithProxy: false,
        error: err.message,
      });
    }
  });

  // Batch check up to 500 hashes in a single request (used by the iOS app during library scan)
  app.post('/api/check/batch', async (req, res) => {
    try {
      const hashes = req.body && req.body.hashes;
      if (!Array.isArray(hashes)) {
        return res.status(400).json({
          success: false,
          error: 'Missing "hashes" array in JSON body',
        });
      }
      if (hashes.length > 500) {
        return res.status(400).json({
          success: false,
          error: 'Maximum 500 hashes per batch request',
        });
      }

      const { hashIndex } = req.userContext;
      const results = {};
      for (const rawHash of hashes) {
        if (typeof rawHash !== 'string' || !rawHash.trim()) continue;
        const normalized = rawHash.trim().toLowerCase();
        const lookupResult = await hashIndex.lookup(normalized);
        const exists = lookupResult.status !== 'missing';
        results[normalized] = {
          exists,
          isMaster: lookupResult.status === 'master',
          isProxy: lookupResult.status === 'proxy',
          canDelete: exists,
          canReplaceWithProxy: lookupResult.status === 'master',
          masterHash: lookupResult.masterHash,
          savedPath: lookupResult.record ? lookupResult.record.relativePath : null,
        };
      }

      return res.json({
        success: true,
        results,
      });
    } catch (err) {
      return res.status(500).json({
        success: false,
        error: err.message,
      });
    }
  });

  // Main upload endpoint for Apple Shortcuts (supports Form multipart OR Raw File body)
  app.post(
    '/api/upload',
    (req, res, next) => {
      const contentType = String(req.headers['content-type'] || '').toLowerCase();
      if (contentType.startsWith('multipart/form-data')) {
        return upload.any()(req, res, next);
      }
      return next();
    },
    async (req, res) => {
      try {
        let buffer = null;
        let originalName = '';
        let mimeType = '';

        if (Array.isArray(req.files) && req.files.length > 0) {
          const file = req.files[0];
          buffer = file.buffer;
          originalName = file.originalname;
          mimeType = file.mimetype;
        } else if (Buffer.isBuffer(req.body) && req.body.length > 0) {
          buffer = req.body;
          originalName = decodeURIComponent(
            String(req.headers['x-file-name'] || '')
          );
          mimeType = String(
            req.headers['content-type'] || 'application/octet-stream'
          );
        }

        if (!buffer || buffer.length === 0) {
          return res.status(400).json({
            success: false,
            canDelete: false,
            error:
              'No photo file received. In Apple Shortcuts, use "Form" with a File field named "photo" or "File" request body.',
          });
        }

        const bodyFields =
          req.body && !Buffer.isBuffer(req.body) ? req.body : {};
        const createdAt =
          bodyFields.createdAt ||
          bodyFields.photoDate ||
          req.headers['x-photo-date'] ||
          req.headers['x-created-at'] ||
          '';
        const expectedHash =
          bodyFields.hash ||
          bodyFields.expectedHash ||
          bodyFields.sha256 ||
          req.headers['x-file-sha256'] ||
          req.headers['x-file-hash'] ||
          '';
        const customName =
          bodyFields.fileName ||
          bodyFields.filename ||
          (req.headers['x-file-name']
            ? decodeURIComponent(String(req.headers['x-file-name']))
            : '') ||
          originalName;
        const strictChecksum =
          String(
            bodyFields.strictChecksum ??
              req.headers['x-verify-checksum'] ??
              req.query.strictChecksum ??
              ''
          )
            .trim()
            .toLowerCase() === 'strict' ||
          String(
            bodyFields.strictChecksum ?? req.query.strictChecksum ?? ''
          )
            .trim()
            .toLowerCase() === 'true';

        const { storageDir, hashIndex, folderName } = req.userContext;

        // If the Shortcut uploaded multiple files in a single request (e.g., passing Photos directly without a Repeat loop)
        if (Array.isArray(req.files) && req.files.length > 1) {
          const results = [];
          for (const file of req.files) {
            const itemResult = await storeAndVerifyPhoto({
              buffer: file.buffer,
              originalName: file.originalname,
              mimeType: file.mimetype,
              createdAt,
              expectedHash: '',
              storageDir,
              hashIndex,
            });
            itemResult.userFolder = folderName;
            results.push(itemResult);
            const displayPath = folderName
              ? `${folderName}/${itemResult.savedPath}`
              : itemResult.savedPath;
            console.log(
              `[${new Date().toISOString()}] ${itemResult.status.toUpperCase()}${folderName ? ` [${folderName}]` : ''}: ${displayPath} (${itemResult.hash.slice(0, 12)}..., ${itemResult.size} bytes)`
            );
          }
          return res.status(200).json({
            success: true,
            backedUp: true,
            canDelete: true,
            count: results.length,
            userFolder: folderName,
            files: results,
          });
        }

        const result = await storeAndVerifyPhoto({
          buffer,
          originalName: customName,
          mimeType,
          createdAt,
          expectedHash,
          strictChecksum,
          storageDir,
          hashIndex,
        });

        result.userFolder = folderName;
        const displayPath = folderName
          ? `${folderName}/${result.savedPath}`
          : result.savedPath;

        console.log(
          `[${new Date().toISOString()}] ${result.status.toUpperCase()}${folderName ? ` [${folderName}]` : ''}: ${displayPath} (${result.hash.slice(0, 12)}..., ${result.size} bytes) -> canDelete=${result.canDelete}`
        );

        return res.status(200).json(result);
      } catch (err) {
        const status = err.statusCode || 500;
        console.error(`[${new Date().toISOString()}] UPLOAD ERROR:`, err.message);
        return res.status(status).json({
          success: false,
          canDelete: false,
          canReplaceWithProxy: false,
          checksumVerified: false,
          error: err.message,
        });
      }
    }
  );

  // Optional S3/MinIO pre-signed URL upload flow:
  // 1. POST /api/upload/presign -> returns a pre-signed PUT URL for direct upload to S3/MinIO
  app.post('/api/upload/presign', async (req, res) => {
    try {
      if (!isS3Configured(config.s3)) {
        return res.status(501).json({
          success: false,
          error:
            'S3/MinIO is not configured on this server. Use direct VPS upload via POST /api/upload.',
        });
      }

      const { fileName, mimeType, createdAt, expectedHash } = req.body || {};
      const cleanHash = String(expectedHash || '').trim().toLowerCase();
      if (!cleanHash || cleanHash.length !== 64) {
        return res.status(400).json({
          success: false,
          error: 'Valid 64-character SHA-256 "expectedHash" is required.',
        });
      }

      const { hashIndex, folderName } = req.userContext;
      const existing = await hashIndex.verifyExisting(cleanHash);
      if (existing) {
        return res.json({
          success: true,
          alreadyExists: true,
          checksumVerified: true,
          canReplaceWithProxy: true,
          serverSha256: existing.diskHash || existing.hash,
          savedPath: existing.relativePath,
        });
      }

      const { year, dateFolder } = parseDateFolder(createdAt);
      const safeName = sanitizeFilename(fileName, mimeType, cleanHash);
      const prefix = folderName ? `${folderName}/` : '';
      const objectKey = `${prefix}${year}/${dateFolder}/${cleanHash.slice(0, 8)}_${safeName}`;

      const uploadUrl = createPresignedUrl({
        s3Config: config.s3,
        method: 'PUT',
        objectKey,
        expiresIn: 900,
      });

      return res.json({
        success: true,
        alreadyExists: false,
        uploadUrl,
        objectKey,
        expiresIn: 900,
      });
    } catch (err) {
      return res.status(500).json({
        success: false,
        error: err.message,
      });
    }
  });

  // 2. POST /api/upload/confirm -> backend reads the S3 object, verifies its SHA-256, and indexes it
  app.post('/api/upload/confirm', async (req, res) => {
    try {
      if (!isS3Configured(config.s3)) {
        return res.status(501).json({
          success: false,
          checksumVerified: false,
          canReplaceWithProxy: false,
          error: 'S3/MinIO is not configured on this server.',
        });
      }

      const { objectKey, expectedHash, fileName, createdAt } = req.body || {};
      if (!objectKey || !expectedHash) {
        return res.status(400).json({
          success: false,
          checksumVerified: false,
          canReplaceWithProxy: false,
          error: 'Both "objectKey" and "expectedHash" are required.',
        });
      }

      const { actualSha256, size } = await verifyS3ObjectChecksum({
        s3Config: config.s3,
        objectKey,
        expectedSha256: expectedHash,
      });

      const { dateFolder, takenAt } = parseDateFolder(createdAt);
      const { hashIndex, folderName } = req.userContext;
      const record = await hashIndex.set(actualSha256, {
        hash: actualSha256,
        diskHash: actualSha256,
        storageType: 's3',
        relativePath: objectKey,
        originalName: fileName || path.basename(objectKey),
        size,
        photoDate: dateFolder,
        takenAt: takenAt || null,
        uploadedAt: new Date().toISOString(),
      });

      return res.json({
        success: true,
        backedUp: true,
        canDelete: true,
        canReplaceWithProxy: true,
        checksumVerified: true,
        serverSha256: actualSha256,
        hash: actualSha256,
        savedPath: record.relativePath,
        size: record.size,
        photoDate: record.photoDate,
        userFolder: folderName,
      });
    } catch (err) {
      const status = err.statusCode || 500;
      return res.status(status).json({
        success: false,
        checksumVerified: false,
        canReplaceWithProxy: false,
        error: err.message,
      });
    }
  });

  // Register a lightweight local proxy hash (and optional compressed preview/video proxy) against a verified master photo
  app.post('/api/proxy/register', async (req, res) => {
    try {
      const {
        masterHash,
        proxyHash,
        assetId,
        proxyBase64,
        proxyFormat,
        videoProxyBase64,
      } = req.body || {};
      if (!masterHash || !proxyHash) {
        return res.status(400).json({
          success: false,
          error: 'Both "masterHash" and "proxyHash" are required',
        });
      }

      const { hashIndex, storageDir } = req.userContext;
      const normMaster = String(masterHash).trim().toLowerCase();
      let proxyMeta = {};
      const proxiesDir = path.join(storageDir, '.proxies');

      if (proxyBase64 && typeof proxyBase64 === 'string') {
        const proxyBuf = Buffer.from(proxyBase64, 'base64');
        if (proxyBuf.length > 0) {
          const ext =
            String(proxyFormat || '').toLowerCase() === 'heic'
              ? '.heic'
              : '.jpg';
          await fs.promises.mkdir(proxiesDir, { recursive: true });
          const proxyFileName = `${normMaster}${ext}`;
          const proxyFullPath = path.join(proxiesDir, proxyFileName);
          await fs.promises.writeFile(proxyFullPath, proxyBuf);
          proxyMeta.proxyRelativePath = `.proxies/${proxyFileName}`;
          proxyMeta.proxySize = proxyBuf.length;
        }
      }

      if (videoProxyBase64 && typeof videoProxyBase64 === 'string') {
        const videoBuf = Buffer.from(videoProxyBase64, 'base64');
        if (videoBuf.length > 0) {
          await fs.promises.mkdir(proxiesDir, { recursive: true });
          const videoFileName = `${normMaster}.mp4`;
          const videoFullPath = path.join(proxiesDir, videoFileName);
          await fs.promises.writeFile(videoFullPath, videoBuf);
          proxyMeta.videoProxyRelativePath = `.proxies/${videoFileName}`;
          proxyMeta.videoProxySize = videoBuf.length;
        }
      }

      const updated = await hashIndex.registerProxy(
        masterHash,
        proxyHash,
        assetId,
        proxyMeta
      );
      if (!updated) {
        return res.status(404).json({
          success: false,
          error: 'Master photo not found or failed disk verification',
        });
      }

      return res.json({
        success: true,
        masterHash: updated.diskHash || updated.hash,
        proxyHash: updated.proxyHash,
        proxySize: updated.proxySize || null,
        videoProxySize: updated.videoProxySize || null,
        savedPath: updated.relativePath,
      });
    } catch (err) {
      return res.status(500).json({
        success: false,
        error: err.message,
      });
    }
  });

  // Stream raw binary compressed MP4 video proxy straight to .proxies/<hash>.mp4 (avoids JSON/base64 bloat)
  app.post('/api/proxy/:masterHash/video', async (req, res) => {
    req.pause();
    let tmpPath = null;
    try {
      const { hashIndex, storageDir } = req.userContext;
      const lookupResult = await hashIndex.lookup(req.params.masterHash, { allowStatFastPath: true });
      if (lookupResult.status === 'missing' || !lookupResult.record) {
        return res.status(404).json({
          success: false,
          error: 'Master photo not found',
        });
      }

      const normMaster = lookupResult.masterHash.replace(/[^a-f0-9_-]/gi, '');
      const proxiesDir = path.join(storageDir, '.proxies');
      await fs.promises.mkdir(proxiesDir, { recursive: true });
      const videoFileName = `${normMaster}.mp4`;
      const videoFullPath = path.join(proxiesDir, videoFileName);
      tmpPath = `${videoFullPath}.${process.pid}.${Date.now()}.tmp`;

      const providedProxyHash = String(req.headers['x-proxy-hash'] || '').trim().toLowerCase();
      const assetId = String(req.headers['x-asset-id'] || '').trim();
      const shaHasher = providedProxyHash ? null : crypto.createHash('sha256');

      let totalBytes = 0;
      await new Promise((resolve, reject) => {
        const ws = fs.createWriteStream(tmpPath);
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
        req.on('data', (chunk) => {
          totalBytes += chunk.length;
          if (totalBytes > config.maxFileSizeBytes) {
            const err = new Error('Video proxy exceeds maximum upload size');
            err.statusCode = 413;
            fail(err);
            return;
          }
          if (shaHasher) shaHasher.update(chunk);
        });
        ws.on('finish', () => {
          if (settled) return;
          settled = true;
          resolve();
        });
        req.resume();
        req.pipe(ws);
      });

      if (totalBytes === 0) {
        await fs.promises.unlink(tmpPath).catch(() => {});
        return res.status(400).json({
          success: false,
          error: 'Empty video proxy stream',
        });
      }

      await fs.promises.rename(tmpPath, videoFullPath);
      tmpPath = null;

      const resolvedProxyHash =
        providedProxyHash ||
        lookupResult.record.proxyHash ||
        (shaHasher ? shaHasher.digest('hex') : normMaster);

      const updated = await hashIndex.registerProxy(
        lookupResult.masterHash,
        resolvedProxyHash,
        assetId,
        {
          videoProxyRelativePath: `.proxies/${videoFileName}`,
          videoProxySize: totalBytes,
        }
      );

      return res.json({
        success: true,
        masterHash: lookupResult.masterHash,
        proxyHash: updated?.proxyHash || resolvedProxyHash,
        videoProxySize: totalBytes,
      });
    } catch (err) {
      if (tmpPath) {
        await fs.promises.unlink(tmpPath).catch(() => {});
      }
      return res.status(err.statusCode || 500).json({
        success: false,
        error: err.message,
      });
    }
  });

  // Server-side proxy generation using sharp / ffmpeg directly from disk (no full-master transfer back to iPhone)
  app.post('/api/proxy/generate', async (req, res) => {
    try {
      const { masterHash, maxPixelSize, quality } = req.body || {};
      if (!masterHash) {
        return res.status(400).json({
          success: false,
          error: 'masterHash is required',
        });
      }

      const { hashIndex, storageDir } = req.userContext;
      const lookupResult = await hashIndex.lookup(masterHash, { allowStatFastPath: true });
      if (lookupResult.status === 'missing' || !lookupResult.record) {
        return res.status(404).json({
          success: false,
          error: 'Master photo not found',
        });
      }

      const record = lookupResult.record;
      if (record.storageType === 's3') {
        return res.status(501).json({
          success: false,
          fallbackToClient: true,
          error: 'Server-side proxy generation requires local disk storage',
        });
      }

      const fullPath = path.join(storageDir, record.relativePath);
      if (!fs.existsSync(fullPath)) {
        return res.status(404).json({
          success: false,
          error: 'Master photo file not found on disk',
        });
      }

      const proxiesDir = path.join(storageDir, '.proxies');
      const generated = await generateServerSideProxy({
        sourcePath: fullPath,
        proxiesDir,
        masterHash: lookupResult.masterHash,
        originalName: record.originalName || fullPath,
        maxPixelSize,
        quality,
      });

      const updated = await hashIndex.registerProxy(
        lookupResult.masterHash,
        generated.proxyHash,
        record.assetId || '',
        generated
      );
      if (!updated) {
        return res.status(404).json({
          success: false,
          error: 'Master photo not found',
        });
      }

      return res.json({
        success: true,
        capabilities: await getProxyCapabilities(),
        photo: hashIndex.formatMasterSummary(updated, lookupResult.masterHash),
      });
    } catch (err) {
      return res.status(err.statusCode || 500).json({
        success: false,
        fallbackToClient: Boolean(err.fallbackToClient),
        error: err.message,
      });
    }
  });

  // List all backed-up master photos for the authenticated user
  app.get('/api/photos', async (req, res) => {
    try {
      const { hashIndex, folderName } = req.userContext;
      if (req.query.sync === '1' || req.query.sync === 'true') {
        await hashIndex.syncStorageDir();
      }
      const limit = Math.min(1000, Math.max(1, Number(req.query.limit) || 200));
      const offset = Math.max(0, Number(req.query.offset) || 0);
      let all = hashIndex.listMasters();

      const yearCountsMap = new Map();
      for (const item of all) {
        if (item.year) {
          yearCountsMap.set(item.year, (yearCountsMap.get(item.year) || 0) + 1);
        }
      }
      const years = Array.from(yearCountsMap.entries())
        .sort((a, b) => b[0] - a[0])
        .map(([year, count]) => ({ year, count }));

      if (req.query.year && /^\d{4}$/.test(String(req.query.year).trim())) {
        const targetYear = Number(String(req.query.year).trim());
        all = all.filter((item) => item.year === targetYear);
      }
      if (req.query.mediaType === 'video' || req.query.mediaType === 'photo') {
        const wantVideo = req.query.mediaType === 'video';
        all = all.filter((item) => {
          const ext = path.extname(item.originalName || item.savedPath || '').toLowerCase();
          const isVid = ['.mov', '.mp4', '.m4v', '.3gp', '.avi'].includes(ext);
          return wantVideo ? isVid : !isVid;
        });
      }
      if (req.query.order === 'asc') {
        all = all.slice().reverse();
      }

      const photos = all.slice(offset, offset + limit);
      return res.json({
        success: true,
        userFolder: folderName,
        total: all.length,
        hasMore: offset + photos.length < all.length,
        years,
        photos,
      });
    } catch (err) {
      return res.status(500).json({
        success: false,
        error: err.message,
      });
    }
  });

  // Stream small compressed preview (proxy) when available, falling back to master for images
  app.get('/api/photo/:hash/preview', async (req, res) => {
    try {
      const { hashIndex, storageDir } = req.userContext;
      const lookupResult = await hashIndex.lookup(req.params.hash, { allowStatFastPath: true });
      if (lookupResult.status === 'missing' || !lookupResult.record) {
        return res.status(404).json({
          success: false,
          error: 'Photo not found',
        });
      }

      const record = lookupResult.record;
      if (record.proxyRelativePath) {
        const proxyPath = path.join(storageDir, record.proxyRelativePath);
        if (fs.existsSync(proxyPath)) {
          res.setHeader('X-Photo-Variant', 'proxy');
          res.setHeader('X-Master-Sha256', lookupResult.masterHash);
          return fs.createReadStream(proxyPath).pipe(res);
        }
      }

      const ext = path.extname(record.originalName || record.relativePath || '').toLowerCase();
      if (['.mov', '.mp4', '.m4v', '.3gp', '.avi'].includes(ext)) {
        return res.status(404).json({
          success: false,
          needsProxy: true,
          error: 'Compressed video preview not created yet',
        });
      }

      if (record.storageType === 's3' && isS3Configured(config.s3)) {
        const downloadUrl = createPresignedUrl({
          s3Config: config.s3,
          method: 'GET',
          objectKey: record.relativePath,
          expiresIn: 300,
        });
        return res.redirect(downloadUrl);
      }

      const fullPath = path.join(storageDir, record.relativePath);
      if (!fs.existsSync(fullPath)) {
        return res.status(404).json({
          success: false,
          error: 'Photo file not found on disk',
        });
      }
      res.setHeader('X-Photo-Variant', 'master');
      res.setHeader('X-Master-Sha256', lookupResult.masterHash);
      return fs.createReadStream(fullPath).pipe(res);
    } catch (err) {
      return res.status(500).json({
        success: false,
        error: err.message,
      });
    }
  });

  // Stream small compressed video proxy (.mp4) when available
  app.get('/api/photo/:hash/video-proxy', async (req, res) => {
    try {
      const { hashIndex, storageDir } = req.userContext;
      const lookupResult = await hashIndex.lookup(req.params.hash, { allowStatFastPath: true });
      if (lookupResult.status === 'missing' || !lookupResult.record) {
        return res.status(404).json({
          success: false,
          error: 'Photo not found',
        });
      }

      const record = lookupResult.record;
      if (record.videoProxyRelativePath) {
        const videoProxyPath = path.join(storageDir, record.videoProxyRelativePath);
        if (fs.existsSync(videoProxyPath)) {
          res.setHeader('X-Photo-Variant', 'video-proxy');
          res.setHeader('X-Master-Sha256', lookupResult.masterHash);
          res.setHeader('Content-Type', 'video/mp4');
          return res.sendFile(path.resolve(videoProxyPath));
        }
      }

      return res.status(404).json({
        success: false,
        error: 'Compressed video proxy not available for this item',
      });
    } catch (err) {
      return res.status(500).json({
        success: false,
        error: err.message,
      });
    }
  });

  // Download / restore full-resolution master photo by either masterHash or proxyHash
  app.get('/api/photo/:hash', async (req, res) => {
    try {
      const { hashIndex, storageDir } = req.userContext;
      const lookupResult = await hashIndex.lookup(req.params.hash, { allowStatFastPath: true });
      if (lookupResult.status === 'missing' || !lookupResult.record) {
        return res.status(404).json({
          success: false,
          error: 'Photo not found',
        });
      }

      const record = lookupResult.record;
      if (record.storageType === 's3' && isS3Configured(config.s3)) {
        const downloadUrl = createPresignedUrl({
          s3Config: config.s3,
          method: 'GET',
          objectKey: record.relativePath,
          expiresIn: 300,
        });
        return res.redirect(downloadUrl);
      }

      const fullPath = path.join(storageDir, record.relativePath);
      res.setHeader(
        'Content-Disposition',
        `inline; filename="${encodeURIComponent(record.originalName || path.basename(fullPath))}"`
      );
      res.setHeader('X-Master-Sha256', lookupResult.masterHash);
      return fs.createReadStream(fullPath).pipe(res);
    } catch (err) {
      return res.status(500).json({
        success: false,
        error: err.message,
      });
    }
  });

  // Multer & general error handler — always guarantees canDelete: false on error
  app.use((err, req, res, _next) => {
    console.error(`[${new Date().toISOString()}] SERVER ERROR:`, err.message);
    res.status(err.status || 400).json({
      success: false,
      canDelete: false,
      error: err.message || 'Unexpected upload error',
    });
  });

  return app;
}

if (require.main === module) {
  createApp()
    .then((app) => {
      const { port, protocol, sslCertPath, sslKeyPath, storageDir, userKeyMap } =
        app.locals.config;

      const onListening = () => {
        const scheme = protocol === 'https' ? 'https' : 'http';
        console.log(`PhotoHub backend listening on ${scheme}://0.0.0.0:${port}`);
        console.log(`Base storage directory: ${storageDir}`);
        if (userKeyMap.size > 0) {
          console.log(
            `Multi-user folders active: ${Array.from(new Set(userKeyMap.values())).join(', ')}`
          );
        }
      };

      if (protocol === 'https') {
        if (!sslCertPath || !sslKeyPath) {
          throw new Error(
            'PROTOCOL=https requires SSL_CERT_PATH and SSL_KEY_PATH in .env'
          );
        }
        const server = https.createServer(
          {
            cert: fs.readFileSync(sslCertPath),
            key: fs.readFileSync(sslKeyPath),
          },
          app
        );
        server.listen(port, '0.0.0.0', onListening);
      } else {
        http.createServer(app).listen(port, '0.0.0.0', onListening);
      }
    })
    .catch((err) => {
      console.error('Failed to start server:', err);
      process.exit(1);
    });
}

module.exports = { createApp };
