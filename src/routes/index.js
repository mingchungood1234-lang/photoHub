/**
 * MASTER ROUTER — Connects Express `/api` URLs to Route Modules
 *
 * Where this belongs: `src/routes/index.js`.
 * Where it comes from: Called once during startup by `src/app.js`.
 * Where requests go next:
 *   1. `/api/health`, `/api/auth/config`, `/api/auth/google/*`, `/api/auth/exchange` -> `publicRoutes` (NO login needed)
 *   2. Everything below runs `authMiddleware` first -> rejects invalid callers with 401
 *   3. Valid requests continue into `accountRoutes`, `uploadRoutes`, `proxyRoutes`, or `photoRoutes`
 */

const { createPublicRoutes } = require('./publicRoutes');
const { createAccountRoutes } = require('./accountRoutes');
const { createUploadRoutes } = require('./uploadRoutes');
const { createProxyRoutes } = require('./proxyRoutes');
const { createPhotoRoutes } = require('./photoRoutes');

function mountRoutes(app, { authMiddleware, uploadMiddleware, controllers }) {
  // Public endpoints (Docker healthcheck & OAuth discovery/PKCE handshake)
  app.use('/api', createPublicRoutes(controllers));

  // Protect all remaining `/api/*` endpoints
  app.use('/api', authMiddleware);

  app.use('/api', createAccountRoutes(controllers));
  app.use('/api', createUploadRoutes({ ...controllers, uploadMiddleware }));
  app.use('/api', createProxyRoutes(controllers));
  app.use('/api', createPhotoRoutes(controllers));
}

module.exports = { mountRoutes };
