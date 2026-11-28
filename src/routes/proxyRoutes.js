/**
 * COMPRESSED PROXY ROUTES (Authenticated via `authMiddleware`)
 *
 * Where this belongs: `src/routes/proxyRoutes.js`, mounted in `src/routes/index.js`.
 * Where requests go:
 *   - `POST /api/proxy/register`           -> `controllers/proxyController.js` (`registerProxy`)
 *   - `POST /api/proxy/:masterHash/video`  -> `controllers/proxyController.js` (`uploadVideoProxyStream`)
 *   - `POST /api/proxy/generate`           -> `controllers/proxyController.js` (`generateProxy`)
 */

const express = require('express');

function createProxyRoutes({ proxyController, securityGuards = {} }) {
  const router = express.Router();
  const noop = (_req, _res, next) => next();
  const heavyLimit = securityGuards.heavyOpLimiter || noop;
  const proxyGenGuard = securityGuards.proxyGenConcurrencyGuard || noop;

  router.post('/proxy/register', proxyController.registerProxy);
  router.post('/proxy/:masterHash/video', proxyController.uploadVideoProxyStream);
  router.post('/proxy/generate', heavyLimit, proxyGenGuard, proxyController.generateProxy);

  return router;
}

module.exports = { createProxyRoutes };
