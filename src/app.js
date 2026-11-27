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
const { getConfig } = require('./config/env');
const {
  resolveSessionSecret,
  UserDirectory,
  OneTimeExchangeStore,
} = require('./models/userModel');
const { exchangeGoogleCodeForProfile } = require('./services/googleOAuthService');
const { createContextService } = require('./services/contextService');
const { createNodeAllocationService } = require('./services/nodeAllocationService');
const { createAuthMiddleware } = require('./middleware/authMiddleware');
const { createAdminAuthMiddleware } = require('./middleware/adminAuthMiddleware');
const { createUploadMiddleware } = require('./middleware/uploadMiddleware');
const { errorMiddleware } = require('./middleware/errorMiddleware');
const { createHealthController } = require('./controllers/healthController');
const { createAuthController } = require('./controllers/authController');
const { createAccountController } = require('./controllers/accountController');
const { createCheckController } = require('./controllers/checkController');
const { createUploadController } = require('./controllers/uploadController');
const { createProxyController } = require('./controllers/proxyController');
const { createPhotoController } = require('./controllers/photoController');
const { createAdminController } = require('./controllers/adminController');
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

  const nodeAllocationService = createNodeAllocationService({
    config,
    sessionSecret,
    userDirectory,
    contextService,
  });

  // Build Express application and parse JSON/binary bodies before route handlers run
  const app = express();
  app.set('trust proxy', 1); // Respect X-Forwarded-* headers when running behind Nginx/Cloudflare/Caddy
  app.locals.config = config;
  app.locals.hashIndex = contextService.defaultHashIndex;
  app.locals.folderContexts = contextService.folderContexts;
  app.locals.flushAllIndexes = contextService.flushAllIndexes;
  app.locals.sessionSecret = sessionSecret;

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

  app.use(express.json({ limit: '50mb' })); // Parses `application/json` payloads into `req.body`
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
    uploadController: createUploadController({ config, contextService }),
    proxyController: createProxyController({ config }),
    photoController: createPhotoController({ config }),
    adminController: createAdminController({ config, contextService, userDirectory, nodeAllocationService }),
  };

  // Allow browser web gallery sessions on gateway/storage-node origins to call `/api/*` cleanly
  const allowedOrigins = new Set();
  const tryAddOrigin = (rawUrl) => {
    if (!rawUrl) return;
    try {
      allowedOrigins.add(new URL(rawUrl).origin);
    } catch {
      // ignore invalid URL
    }
  };
  tryAddOrigin(config.publicUrl);
  for (const node of config.storageNodes || []) {
    tryAddOrigin(node && node.url);
  }
  app.use('/api', (req, res, next) => {
    const origin = req.headers.origin;
    if (origin && (allowedOrigins.size === 0 || allowedOrigins.has(origin))) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type,X-API-Key,If-None-Match');
      res.setHeader('Access-Control-Expose-Headers', 'ETag,X-Photo-Variant,X-Master-Sha256,Content-Disposition');
      if (req.method === 'OPTIONS') {
        return res.status(204).end();
      }
    }
    return next();
  });

  // Mount web frontend (landing showcase + responsive authenticated photo gallery)
  const webDir = path.join(__dirname, 'views', 'web');
  const webIndexPath = path.join(webDir, 'index.html');
  app.use(
    '/web',
    express.static(webDir, {
      dotfiles: 'ignore',
      maxAge: '1h',
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
  app.get('/', sendWebApp);
  app.get('/auth/callback', sendWebApp);
  app.get('/gallery', sendWebApp);
  app.get('/about', sendWebApp);

  // Mount all `/api/*` routes, `/admin` web page, and register errorMiddleware LAST (Express error-handler rule)
  app.get('/admin', controllers.adminController.getDashboardPage);
  mountRoutes(app, { authMiddleware, adminAuthMiddleware, uploadMiddleware, controllers });
  app.use(errorMiddleware);

  return app;
}

module.exports = { createApp };
