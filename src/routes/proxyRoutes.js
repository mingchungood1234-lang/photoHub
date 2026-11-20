const express = require('express');

function createProxyRoutes({ proxyController }) {
  const router = express.Router();

  router.post('/proxy/register', proxyController.registerProxy);
  router.post('/proxy/:masterHash/video', proxyController.uploadVideoProxyStream);
  router.post('/proxy/generate', proxyController.generateProxy);

  return router;
}

module.exports = { createProxyRoutes };
