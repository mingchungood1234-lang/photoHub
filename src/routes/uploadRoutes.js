const express = require('express');

function createUploadRoutes({ checkController, uploadController, uploadMiddleware }) {
  const router = express.Router();

  router.get('/check/:hash', checkController.checkByParam);
  router.post('/check', checkController.checkByBody);
  router.post('/check/batch', checkController.checkBatch);

  router.post('/upload', uploadMiddleware.conditionalMultipart, uploadController.uploadDirect);
  router.post('/upload/presign', uploadController.presignUpload);
  router.post('/upload/confirm', uploadController.confirmUpload);

  return router;
}

module.exports = { createUploadRoutes };
