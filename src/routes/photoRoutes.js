/**
 * SERVER PHOTO GALLERY & DOWNLOAD ROUTES (Authenticated via `authMiddleware`)
 *
 * Where this belongs: `src/routes/photoRoutes.js`, mounted in `src/routes/index.js`.
 * Where requests go (`controllers/photoController.js`):
 *   - `GET /api/photos`                        -> `listPhotos` (supports pagination, year, mediaType, prefix, gzip)
 *   - `GET /api/photo/:hash/preview`           -> `streamPreview` (lightweight compressed thumbnail/preview)
 *   - `GET /api/photo/:hash/video-proxy`       -> `streamVideoProxy` (lightweight H.264 MP4 proxy)
 *   - `POST /api/photo/:hash/protect-original` -> `setProtectOriginal` (prevents auto re-compression)
 *   - `DELETE /api/photo/:hash`                -> `deletePhoto` (deletes master + server proxies + index entry)
 *   - `POST /api/photos/delete` / `DELETE /api/photos` -> `deletePhotosBatch` (batch server delete)
 *   - `GET /api/photo/:hash`                   -> `downloadMaster` (full-res original w/ HTTP Range support)
 *     (Note: `/preview` and `/video-proxy` are defined BEFORE `/photo/:hash` so Express matches specific suffixes first.)
 */

const express = require('express');

function createPhotoRoutes({ photoController, shareController, albumController }) {
  const router = express.Router();

  router.get('/photos', photoController.listPhotos);
  router.get('/photos/memories', photoController.getMemories);
  router.get('/photos/map', photoController.getPhotoMap);
  router.get('/photos/cleanup-suggestions', photoController.getCleanupSuggestions);
  router.get('/photos/trash', photoController.listTrash);
  router.post('/photos/trash', photoController.moveToTrash);
  router.post('/photos/trash/restore', photoController.restoreFromTrash);
  router.post('/photos/trash/empty', photoController.emptyTrash);
  router.post('/photos/download-zip', photoController.downloadZip);
  router.post('/photos/protect-original', photoController.setProtectOriginalsBatch);
  router.post('/photos/delete', photoController.deletePhotosBatch);
  router.delete('/photos', photoController.deletePhotosBatch);

  router.get('/photo/:hash/preview', photoController.streamPreview);
  router.get('/photo/:hash/video-proxy', photoController.streamVideoProxy);
  router.post('/photo/:hash/protect-original', photoController.setProtectOriginal);
  router.post('/photo/:hash/favorite', photoController.setFavorite);
  router.delete('/photo/:hash', photoController.deletePhoto);
  router.get('/photo/:hash', photoController.downloadMaster);

  if (albumController) {
    router.get('/albums', albumController.listAlbums);
    router.post('/albums', albumController.createAlbum);
    router.get('/albums/:id', albumController.getAlbum);
    router.put('/albums/:id', albumController.updateAlbum);
    router.patch('/albums/:id', albumController.updateAlbum);
    router.delete('/albums/:id', albumController.deleteAlbum);
    router.post('/albums/:id/photos', albumController.addPhotosToAlbum);
    router.delete('/albums/:id/photos', albumController.removePhotosFromAlbum);
    router.post('/albums/:id/photos/remove', albumController.removePhotosFromAlbum);
  }

  if (shareController) {
    router.post('/shares', shareController.createShare);
    router.get('/shares', shareController.listShares);
    router.put('/shares/:token', shareController.updateShare);
    router.patch('/shares/:token', shareController.updateShare);
    router.delete('/shares/:token', shareController.revokeShare);
  }

  return router;
}

module.exports = { createPhotoRoutes };
