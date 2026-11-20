const express = require('express');

function createPhotoRoutes({ photoController }) {
  const router = express.Router();

  router.get('/photos', photoController.listPhotos);
  router.get('/photo/:hash/preview', photoController.streamPreview);
  router.get('/photo/:hash/video-proxy', photoController.streamVideoProxy);
  router.post('/photo/:hash/protect-original', photoController.setProtectOriginal);
  router.get('/photo/:hash', photoController.downloadMaster);

  return router;
}

module.exports = { createPhotoRoutes };
