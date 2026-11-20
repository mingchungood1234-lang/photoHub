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
