const express = require('express');

function createAccountRoutes({ authController, accountController }) {
  const router = express.Router();

  router.post('/auth/resolve', authController.resolveNode);
  router.get('/storage', accountController.getStorage);
  router.get('/whoami', accountController.getWhoAmI);

  return router;
}

module.exports = { createAccountRoutes };
