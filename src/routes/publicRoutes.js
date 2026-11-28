/**
 * PUBLIC ROUTES (Unauthenticated)
 *
 * Where this belongs: `src/routes/publicRoutes.js`, mounted BEFORE `authMiddleware` in `src/routes/index.js`.
 * Where requests go:
 *   - `GET /api/health`               -> `controllers/healthController.js` (`getHealth`)
 *   - `GET /api/auth/config`          -> `controllers/authController.js` (`getConfig`)
 *   - `GET /api/auth/google/start`    -> `controllers/authController.js` (`startGoogleAuth`)
 *   - `GET /api/auth/google/callback` -> `controllers/authController.js` (`handleGoogleCallback`)
 *   - `POST /api/auth/exchange`       -> `controllers/authController.js` (`exchangeCode`)
 */

const express = require('express');

function createPublicRoutes({ healthController, authController, shareController, securityGuards = {} }) {
  const router = express.Router();
  const noop = (_req, _res, next) => next();
  const authLimit = securityGuards.authBruteForceLimiter || noop;
  const sharePassLimit = securityGuards.sharePasscodeLimiter || noop;
  const heavyLimit = securityGuards.heavyOpLimiter || noop;
  const zipGuard = securityGuards.zipConcurrencyGuard || noop;

  router.get('/health', healthController.getHealth);
  router.get('/node/capacity', healthController.getNodeCapacity);
  router.get('/auth/config', authController.getConfig);
  router.get('/auth/google/start', authLimit, authController.startGoogleAuth);
  router.get('/auth/google/callback', authLimit, authController.handleGoogleCallback);
  router.post('/auth/exchange', authLimit, authController.exchangeCode);

  if (shareController) {
    router.get('/public/share/:token', sharePassLimit, shareController.getPublicShare);
    router.get('/public/share/:token/preview/:hash', sharePassLimit, shareController.streamPublicPreview);
    router.get('/public/share/:token/video/:hash', sharePassLimit, shareController.streamPublicVideo);
    router.get('/public/share/:token/download/:hash', sharePassLimit, shareController.downloadPublicOriginal);
    router.get('/public/share/:token/download-zip', sharePassLimit, heavyLimit, zipGuard, shareController.downloadPublicZip);
  }

  return router;
}

module.exports = { createPublicRoutes };
