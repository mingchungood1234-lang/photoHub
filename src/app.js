/**
 * EXPRESS APPLICATION FACTORY — Connects Every Layer Together
 *
 * Where this belongs: Application wiring module (imported by `src/server.js`).
 *
 * How a request travels through PhotoHub (top to bottom):
 *   Client HTTP request
 *     -> src/server.js (HTTP/HTTPS listener)
 *     -> src/app.js (Express body parsers)
 *     -> src/routes/index.js (`/api/*` routing table)
 *        ├── Public endpoints (`publicRoutes.js`: `/api/health`, `/api/auth/*`)
 *        ├── src/middleware/authMiddleware.js (verifies JWT/API key & sets `req.userContext`)
 *        └── Protected endpoints (`accountRoutes`, `uploadRoutes`, `proxyRoutes`, `photoRoutes`)
 *     -> src/controllers/* (handles HTTP input/output for each feature)
 *     -> src/services/* & src/models/* (business logic, disk/S3 storage, JSON indexes)
 *     -> src/middleware/errorMiddleware.js (catches thrown/next(err) errors last)
 */

const express = require('express');
const fs = require('fs');
const path = require('path');
const { Readable } = require('stream');
const { getConfig } = require('./config/env');
const {
  resolveSessionSecret,
  verifyToken,
  UserDirectory,
  OneTimeExchangeStore,
} = require('./models/userModel');
const { exchangeGoogleCodeForProfile } = require('./services/googleOAuthService');
const { createContextService } = require('./services/contextService');
const { createNodeAllocationService } = require('./services/nodeAllocationService');
const { createAuthMiddleware } = require('./middleware/authMiddleware');
const { createAdminAuthMiddleware } = require('./middleware/adminAuthMiddleware');
const { createUploadMiddleware } = require('./middleware/uploadMiddleware');
const {
  getClientIp,
  securityHeadersMiddleware,
  requestSanityMiddleware,
  sanitizeJsonBodyMiddleware,
  createRateLimiter,
  createConcurrencyGuard,
} = require('./middleware/securityMiddleware');
const { errorMiddleware } = require('./middleware/errorMiddleware');
const { createHealthController } = require('./controllers/healthController');
const { createAuthController } = require('./controllers/authController');
const { createAccountController } = require('./controllers/accountController');
const { createCheckController } = require('./controllers/checkController');
const { createUploadController } = require('./controllers/uploadController');
const { createProxyController } = require('./controllers/proxyController');
const { createPhotoController } = require('./controllers/photoController');
const { createShareController } = require('./controllers/shareController');
const { createAlbumController } = require('./controllers/albumController');
const { createAdminController } = require('./controllers/adminController');
const { ShareStore } = require('./services/shareService');
const { AlbumStore } = require('./services/albumService');
const { ProxyQueueService } = require('./services/proxyQueueService');
const { ChunkedUploadService } = require('./services/chunkedUploadService');
const { mountRoutes } = require('./routes');

async function createApp(configOverrides = {}) {
  const config = getConfig(configOverrides);
  const sessionSecret = await resolveSessionSecret(
    config.authSessionSecret,
    config.dataDir
  );

  // Initialize models and domain services
  const userDirectory = new UserDirectory(config.dataDir);
  await userDirectory.init();
  const exchangeStore = new OneTimeExchangeStore();
  const googleExchangeFn =
    configOverrides.exchangeGoogleCodeForProfile || exchangeGoogleCodeForProfile;

  const contextService = createContextService(config, { userDirectory });
  await contextService.init();

  const shareStore = new ShareStore(config.dataDir);
  await shareStore.init();

  const albumStore = new AlbumStore(config.dataDir);
  await albumStore.init();

  const proxyQueue = new ProxyQueueService({ concurrency: 2 });
  const chunkedUploadService = new ChunkedUploadService();

  const nodeAllocationService = createNodeAllocationService({
    config,
    sessionSecret,
    userDirectory,
    contextService,
  });

  // Build Express application and parse JSON/binary bodies before route handlers run
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1); // Respect X-Forwarded-* headers when running behind Nginx/Cloudflare/Caddy
  app.locals.config = config;
  app.locals.hashIndex = contextService.defaultHashIndex;
  app.locals.folderContexts = contextService.folderContexts;
  app.locals.flushAllIndexes = contextService.flushAllIndexes;
  app.locals.proxyQueue = proxyQueue;
  app.locals.sessionSecret = sessionSecret;

  // Global security headers & malformed URL/null-byte protection
  app.use(securityHeadersMiddleware);
  app.use(requestSanityMiddleware);

  // Middleware: parsers transform incoming bytes into `req.body` or `req.files`
  const uploadMiddleware = createUploadMiddleware(config);
  const authMiddleware = createAuthMiddleware({
    config,
    sessionSecret,
    contextService,
  });
  const adminAuthMiddleware = createAdminAuthMiddleware({
    config,
    sessionSecret,
  });

  // Security rate limiters & per-user heavy-operation concurrency guards
  const rlCfg = config.rateLimit || {};
  const rlEnabled = rlCfg.enabled !== false;
  const securityGuards = {
    generalApiLimiter: createRateLimiter({
      windowMs: 60_000,
      max: rlCfg.apiMaxPerMin || 1500,
      enabled: rlEnabled,
      skip: (req) => req.path === '/health' || req.path === '/api/health',
      message: 'Rate limit exceeded. Please slow down and try again shortly.',
    }),
    authBruteForceLimiter: createRateLimiter({
      windowMs: 15 * 60_000,
      max: rlCfg.authFailMaxPer15Min || 25,
      enabled: rlEnabled,
      countFailuresOnly: true,
      message: 'Too many failed authentication attempts. Please try again later.',
    }),
    sharePasscodeLimiter: createRateLimiter({
      windowMs: 15 * 60_000,
      max: rlCfg.shareFailMaxPer15Min || 15,
      enabled: rlEnabled,
      countFailuresOnly: true,
      keyGenerator: (req) => `${getClientIp(req)}:${String((req.params && req.params.token) || req.path).slice(0, 64)}`,
      message: 'Too many incorrect passcode attempts. Please try again later.',
    }),
    heavyOpLimiter: createRateLimiter({
      windowMs: 60_000,
      max: rlCfg.heavyMaxPerMin || 30,
      enabled: rlEnabled,
      message: 'Too many heavy requests. Please wait a moment and try again.',
    }),
    mapRescanLimiter: createRateLimiter({
      windowMs: 60_000,
      max: rlCfg.heavyMaxPerMin || 30,
      enabled: rlEnabled,
      skip: (req) => req.query.rescan !== '1' && req.query.rescan !== 'true',
      message: 'Too many GPS rescan requests. Please wait a moment.',
    }),
    zipConcurrencyGuard: createConcurrencyGuard({
      maxConcurrent: 2,
      message: 'Too many simultaneous ZIP downloads. Please wait for one to finish.',
    }),
    cleanupConcurrencyGuard: createConcurrencyGuard({
      maxConcurrent: 1,
      message: 'A Smart Cleanup scan is already running for your account.',
    }),
    mapRescanConcurrencyGuard: createConcurrencyGuard({
      maxConcurrent: 1,
      skip: (req) => req.query.rescan !== '1' && req.query.rescan !== 'true',
      message: 'A GPS scan is already running for your account.',
    }),
    proxyGenConcurrencyGuard: createConcurrencyGuard({
      maxConcurrent: 2,
      message: 'Too many simultaneous proxy generation requests.',
    }),
  };

  // Allow larger JSON payload ONLY on base64 proxy registration; tighten all other JSON endpoints to 2 MB to prevent OOM floods
  app.use(['/api/proxy/register', '/api/web-node/proxy/register'], express.json({ limit: '25mb' }));
  app.use(express.json({ limit: '2mb' }));
  app.use(sanitizeJsonBodyMiddleware);
  // General API flood guard across `/api/*` and brute-force guard on gateway `/api/web-node/*`
  app.use('/api', securityGuards.generalApiLimiter);
  app.use('/api/web-node', securityGuards.authBruteForceLimiter);
  // Raw binary `/api/upload` bodies stream directly to storage inside `uploadController.uploadDirect`
  // after `authMiddleware` resolves `req.userContext.storageDir` (avoids 100MB+ RAM buffering).

  // Controllers: thin HTTP handlers injected with config/services (Dependency Injection)
  const controllers = {
    healthController: createHealthController({ config, contextService, nodeAllocationService }),
    authController: createAuthController({
      config,
      sessionSecret,
      userDirectory,
      exchangeStore,
      googleExchangeFn,
      contextService,
      nodeAllocationService,
    }),
    accountController: createAccountController({ config, contextService }),
    checkController: createCheckController(),
    uploadController: createUploadController({ config, contextService, proxyQueue, chunkedUploadService }),
    proxyController: createProxyController({ config }),
    photoController: createPhotoController({ config }),
    albumController: createAlbumController({ albumStore }),
    shareController: createShareController({ config, shareStore, contextService, albumStore }),
    adminController: createAdminController({
      config,
      contextService,
      userDirectory,
      nodeAllocationService,
      shareStore,
      albumStore,
      proxyQueue,
      chunkedUploadService,
    }),
  };

  // Allow browser web gallery sessions on gateway/web-port/storage-node origins to call `/api/*` cleanly
  const allowedOrigins = new Set();
  const tryAddOrigin = (rawUrl) => {
    if (!rawUrl) return;
    try {
      const parsed = new URL(rawUrl);
      allowedOrigins.add(parsed.origin);
      if (config.webPort > 0) {
        allowedOrigins.add(`${parsed.protocol}//${parsed.hostname}:${config.webPort}`);
        if (parsed.protocol === 'https:') {
          allowedOrigins.add(`http://${parsed.hostname}:${config.webPort}`);
        }
      }
    } catch {
      // ignore invalid URL
    }
  };
  tryAddOrigin(config.publicUrl);
  tryAddOrigin(config.publicWebUrl);
  for (const node of config.storageNodes || []) {
    tryAddOrigin(node && node.url);
  }
  const isAllowedCorsOrigin = (origin, req) => {
    if (!origin) return false;
    if (allowedOrigins.size === 0 || allowedOrigins.has(origin)) return true;
    try {
      const parsed = new URL(origin);
      const host = parsed.hostname.toLowerCase();
      if (host === 'localhost' || host === '127.0.0.1' || host === '[::1]') {
        return true;
      }
      if (req && req.headers && req.headers.host) {
        const reqHost = String(req.headers.host).split(':')[0].toLowerCase();
        if (reqHost && host === reqHost) return true;
      }
    } catch {
      // ignore invalid origin
    }
    return false;
  };
  app.use('/api', (req, res, next) => {
    const origin = req.headers.origin;
    if (origin && isAllowedCorsOrigin(origin, req)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
      res.setHeader(
        'Access-Control-Allow-Headers',
        'Authorization,Content-Type,X-API-Key,If-None-Match,X-File-Name,X-File-Sha256,X-File-Hash,X-Created-At,X-Photo-Date,X-Verify-Checksum,X-Share-Passcode,X-Upload-Source,X-Skip-Auto-Proxy,X-Chunk-Sha256,X-Gps-Lat,X-Gps-Lng,X-Location-Label'
      );
      res.setHeader('Access-Control-Expose-Headers', 'ETag,X-Photo-Variant,X-Master-Sha256,Content-Disposition');
      if (req.method === 'OPTIONS') {
        return res.status(204).end();
      }
    }
    return next();
  });

  // Same-origin Gateway proxy for web gallery users assigned to a remote STORAGE_NODE
  // (eliminates CORS, HTTPS->HTTP mixed-content blocks, and private LAN/Tailscale node reachability issues).
  const WEB_PROXY_ALLOWED_PATH_RE =
    /^\/(whoami|storage|photos(?:\/(?:delete|protect-original|trash|trash\/restore|trash\/empty|download-zip|memories|map|cleanup-suggestions))?|photo\/[^/]+(?:\/(?:preview|video-proxy|protect-original|favorite))?|albums(?:\/[^/]+(?:\/photos(?:\/remove)?)?)?|shares(?:\/[^/]+)?|upload(?:\/chunked\/(?:init|[^/]+(?:\/(?:complete|part\/\d+))?))?|check(?:\/[^/]+)?)$/;
  app.use(async (req, res, next) => {
    if (!req.path.startsWith('/api/web-node/')) return next();
    const subPath = req.path.slice('/api/web-node'.length);
    if (!WEB_PROXY_ALLOWED_PATH_RE.test(subPath) || subPath.includes('..')) {
      return res.status(404).json({ success: false, error: 'Unsupported web proxy endpoint.' });
    }

    const authHeader = String(req.headers.authorization || '').trim();
    const bearer = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
    const token = String(bearer || req.query.apiKey || '').trim();
    const payload = token ? verifyToken(token, sessionSecret) : null;
    if (!payload || payload.typ !== 'session') {
      return res.status(401).json({
        success: false,
        error: 'Unauthorized: Sign in with Google or provide a valid session token.',
      });
    }

    const nodes = Array.isArray(config.storageNodes) ? config.storageNodes : [];
    const targetNode = nodes.find((n) => n && n.id === payload.nodeId) || null;
    const localNodeId = contextService.resolveEffectiveLocalNodeId(
      null,
      contextService.resolveRequestBaseUrl(req)
    );
    const isLocalTarget =
      !targetNode ||
      !payload.nodeId ||
      payload.nodeId === 'primary' ||
      (Boolean(localNodeId) && targetNode.id === localNodeId);

    if (isLocalTarget) {
      // Rewrite cleanly to local `/api/*` so local routes serve it directly with zero extra hop
      req.url = `/api${req.url.slice('/api/web-node'.length)}`;
      return next();
    }

    const queryIdx = req.url.indexOf('?');
    const qsParams = new URLSearchParams(queryIdx >= 0 ? req.url.slice(queryIdx + 1) : '');
    qsParams.delete('apiKey');
    const cleanQs = qsParams.toString();
    const upstreamUrl = `${targetNode.url.replace(/\/+$/, '')}/api${subPath}${cleanQs ? `?${cleanQs}` : ''}`;

    const upstreamHeaders = {
      Authorization: `Bearer ${token}`,
    };
    const forwardReqHeaders = [
      'accept',
      'if-none-match',
      'range',
      'x-file-name',
      'x-file-sha256',
      'x-file-hash',
      'x-created-at',
      'x-photo-date',
      'x-verify-checksum',
      'x-upload-source',
      'x-skip-auto-proxy',
      'x-chunk-sha256',
      'x-gps-lat',
      'x-gps-lng',
      'x-location-label',
    ];
    for (const h of forwardReqHeaders) {
      if (req.headers[h] !== undefined) upstreamHeaders[h] = String(req.headers[h]);
    }

    const fetchOpts = {
      method: req.method,
      headers: upstreamHeaders,
    };
    if (req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH') {
      const contentType = String(req.headers['content-type'] || '').toLowerCase();
      if (contentType.includes('application/json')) {
        upstreamHeaders['Content-Type'] = 'application/json';
        fetchOpts.body = JSON.stringify(req.body || {});
      } else {
        // Stream raw binary upload straight through to the remote storage node with zero RAM buffering
        upstreamHeaders['Content-Type'] = req.headers['content-type'] || 'application/octet-stream';
        if (req.headers['content-length']) {
          upstreamHeaders['Content-Length'] = String(req.headers['content-length']);
        }
        fetchOpts.body = Readable.toWeb(req);
        fetchOpts.duplex = 'half';
      }
    }

    const abortController = new AbortController();
    fetchOpts.signal = abortController.signal;
    const onClientClose = () => {
      if (!res.writableEnded) abortController.abort();
    };
    res.on('close', onClientClose);

    try {
      const upstreamRes = await fetch(upstreamUrl, fetchOpts);
      res.status(upstreamRes.status);
      const passthroughHeaders = [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'content-disposition',
        'etag',
        'last-modified',
        'cache-control',
        'vary',
        'x-photo-variant',
        'x-master-sha256',
        'x-thumb-cache',
      ];
      for (const h of passthroughHeaders) {
        const val = upstreamRes.headers.get(h);
        if (val !== null) res.setHeader(h, val);
      }

      if (upstreamRes.status === 204 || upstreamRes.status === 304 || !upstreamRes.body) {
        res.off('close', onClientClose);
        return res.end();
      }

      const nodeStream = Readable.fromWeb(upstreamRes.body);
      nodeStream.on('error', () => {
        if (!res.headersSent) {
          res.status(502).end();
        } else if (!res.writableEnded) {
          res.end();
        }
      });
      res.on('finish', () => res.off('close', onClientClose));
      return nodeStream.pipe(res);
    } catch (err) {
      res.off('close', onClientClose);
      if (abortController.signal.aborted) return;
      console.warn(`[WebProxy] Failed to reach storage node ${targetNode.id} (${targetNode.url}):`, err.message);
      if (!res.headersSent) {
        return res.status(502).json({
          success: false,
          error: `Assigned storage node (${targetNode.id}) is currently unreachable.`,
        });
      }
      return res.end();
    }
  });

  // Mount web frontend (landing showcase + responsive authenticated photo gallery)
  const webDir = path.join(__dirname, 'views', 'web');
  const webIndexPath = path.join(webDir, 'index.html');
  app.use(
    '/web',
    express.static(webDir, {
      dotfiles: 'ignore',
      maxAge: 0,
      index: false,
    })
  );
  const googleVerifyFile = path.join(__dirname, '..', 'google9fbaf3843fb871e7.html');
  app.get('/google9fbaf3843fb871e7.html', (req, res, next) => {
    if (fs.existsSync(googleVerifyFile)) {
      return res.sendFile(googleVerifyFile);
    }
    return next();
  });
  const sendWebApp = (req, res) => res.sendFile(webIndexPath, { dotfiles: 'allow' });
  app.get('/manifest.webmanifest', (req, res) => {
    res.setHeader('Content-Type', 'application/manifest+json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache');
    return res.sendFile(path.join(webDir, 'manifest.webmanifest'), { dotfiles: 'allow' });
  });
  app.get('/sw.js', (req, res) => {
    res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
    res.setHeader('Service-Worker-Allowed', '/');
    res.setHeader('Cache-Control', 'no-cache');
    return res.sendFile(path.join(webDir, 'sw.js'), { dotfiles: 'allow' });
  });
  app.get('/s/:token', controllers.shareController.getSharePage);
  app.get('/', sendWebApp);
  app.get('/auth/callback', sendWebApp);
  app.get('/gallery', sendWebApp);
  app.get('/about', sendWebApp);

  // Mount all `/api/*` routes, `/admin` web page, and register errorMiddleware LAST (Express error-handler rule)
  app.get('/admin', controllers.adminController.getDashboardPage);
  mountRoutes(app, { authMiddleware, adminAuthMiddleware, uploadMiddleware, controllers, securityGuards });
  app.use(errorMiddleware);

  return app;
}

module.exports = { createApp };
