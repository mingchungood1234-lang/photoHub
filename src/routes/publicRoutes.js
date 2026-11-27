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

function createPublicRoutes({ healthController, authController, shareController }) {
  const router = express.Router();

  router.get('/health', healthController.getHealth);
  router.get('/node/capacity', healthController.getNodeCapacity);
  router.get('/auth/config', authController.getConfig);
  router.get('/auth/google/start', authController.startGoogleAuth);
  router.get('/auth/google/callback', authController.handleGoogleCallback);
  router.post('/auth/exchange', authController.exchangeCode);

  if (shareController) {
    router.get('/public/share/:token', shareController.getPublicShare);
    router.get('/public/share/:token/preview/:hash', shareController.streamPublicPreview);
    router.get('/public/share/:token/video/:hash', shareController.streamPublicVideo);
    router.get('/public/share/:token/download/:hash', shareController.downloadPublicOriginal);
    router.get('/public/share/:token/download-zip', shareController.downloadPublicZip);
  }

  return router;
}

module.exports = { createPublicRoutes };
