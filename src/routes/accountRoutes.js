/**
 * ACCOUNT & SESSION ROUTES (Authenticated via `authMiddleware`)
 *
 * Where this belongs: `src/routes/accountRoutes.js`, mounted in `src/routes/index.js`.
 * Where requests go:
 *   - `POST /api/auth/resolve` -> `controllers/authController.js` (`resolveNode`)
 *   - `GET /api/storage`       -> `controllers/accountController.js` (`getStorage`)
 *   - `GET /api/whoami`        -> `controllers/accountController.js` (`getWhoAmI`)
 */

const express = require('express');

function createAccountRoutes({ authController, accountController }) {
  const router = express.Router();

  router.post('/auth/resolve', authController.resolveNode);
  router.get('/storage', accountController.getStorage);
  router.get('/whoami', accountController.getWhoAmI);

  return router;
}

module.exports = { createAccountRoutes };
