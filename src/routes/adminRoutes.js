/**
 * ADMIN DASHBOARD ROUTES (Authenticated via `adminAuthMiddleware`)
 *
 * Where this belongs: `src/routes/adminRoutes.js`, mounted in `src/routes/index.js` at `/api/admin`.
 * Note: The browser HTML page itself (`GET /admin`) is mounted directly in `src/app.js`
 * so browsers can load the login form before sending `X-Admin-Key` to `/api/admin/*`.
 */

const express = require('express');

function createAdminRoutes({ adminController }) {
  const router = express.Router();

  router.get('/overview', adminController.getOverview);
  router.post('/rescan', adminController.rescanStorage);
  router.post('/user-quota', adminController.updateUserQuota);

  return router;
}

module.exports = { createAdminRoutes };
