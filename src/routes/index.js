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
const { createAdminRoutes } = require('./adminRoutes');
const { createAccountRoutes } = require('./accountRoutes');
const { createUploadRoutes } = require('./uploadRoutes');
const { createProxyRoutes } = require('./proxyRoutes');
const { createPhotoRoutes } = require('./photoRoutes');

function mountRoutes(app, { authMiddleware, adminAuthMiddleware, uploadMiddleware, controllers, securityGuards = {} }) {
  // Public endpoints (Docker healthcheck & OAuth discovery/PKCE handshake)
  app.use('/api', createPublicRoutes({ ...controllers, securityGuards }));

  // Admin dashboard APIs (protected by brute-force limiter + ADMIN_KEY or ADMIN_EMAILS)
  if (securityGuards.authBruteForceLimiter) {
    app.use('/api/admin', securityGuards.authBruteForceLimiter, adminAuthMiddleware, createAdminRoutes(controllers));
  } else {
    app.use('/api/admin', adminAuthMiddleware, createAdminRoutes(controllers));
  }

  // Protect all remaining `/api/*` endpoints (with failed-auth brute-force protection)
  if (securityGuards.authBruteForceLimiter) {
    app.use('/api', securityGuards.authBruteForceLimiter);
  }
  app.use('/api', authMiddleware);

  app.use('/api', createAccountRoutes(controllers));
  app.use('/api', createUploadRoutes({ ...controllers, uploadMiddleware, securityGuards }));
  app.use('/api', createProxyRoutes({ ...controllers, securityGuards }));
  app.use('/api', createPhotoRoutes({ ...controllers, securityGuards }));
}

module.exports = { mountRoutes };
