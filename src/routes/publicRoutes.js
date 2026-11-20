const express = require('express');

function createPublicRoutes({ healthController, authController }) {
  const router = express.Router();

  router.get('/health', healthController.getHealth);
  router.get('/auth/config', authController.getConfig);
  router.get('/auth/google/start', authController.startGoogleAuth);
  router.get('/auth/google/callback', authController.handleGoogleCallback);
  router.post('/auth/exchange', authController.exchangeCode);

  return router;
}

module.exports = { createPublicRoutes };
