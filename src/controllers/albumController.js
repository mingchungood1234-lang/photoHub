/**
 * CUSTOM ALBUMS CONTROLLER (Trips, Events, Family)
 *
 * All routes run behind `authMiddleware` and isolate albums per `req.userContext.folderName`.
 */

function createAlbumController({ albumStore }) {
  async function resolveActivePhotos(hashIndex, rawHashes) {
    const photos = [];
    const seen = new Set();
    for (const h of rawHashes || []) {
      const found = await hashIndex.lookup(h, { allowStatFastPath: true });
      if (found.status !== 'missing' && found.record && !found.record.deletedAt) {
        if (seen.has(found.masterHash)) continue;
        seen.add(found.masterHash);
        photos.push(hashIndex.formatMasterSummary(found.record, found.masterHash));
      }
    }
    photos.sort((a, b) => {
      const da = String(a.photoDate || (a.takenAt || '').slice(0, 10) || '');
      const db = String(b.photoDate || (b.takenAt || '').slice(0, 10) || '');
      const cmp = db.localeCompare(da);
      if (cmp !== 0) return cmp;
      return String(b.takenAt || b.uploadedAt || '').localeCompare(String(a.takenAt || a.uploadedAt || ''));
    });
    return photos;
  }

  function hydrateAlbumSummary(album, hashIndex) {
    const activeHashes = [];
    let minDate = null;
    let maxDate = null;
    for (const h of album.hashes || []) {
      const rec = hashIndex.records.get(h);
      if (!rec || rec.deletedAt) continue;
      const canonical = String(rec.diskHash || rec.hash || h).toLowerCase();
      activeHashes.push(canonical);
      const d = rec.photoDate || (rec.takenAt || '').slice(0, 10) || '';
      if (d) {
        if (!minDate || d < minDate) minDate = d;
        if (!maxDate || d > maxDate) maxDate = d;
      }
    }
    const coverHash =
      album.coverHash && activeHashes.includes(album.coverHash)
        ? album.coverHash
        : activeHashes[0] || null;
    return {
      ...album,
      hashes: activeHashes,
      coverHash,
      itemCount: activeHashes.length,
      dateRange: minDate && maxDate ? (minDate === maxDate ? minDate : `${minDate} – ${maxDate}`) : null,
    };
  }

  return {
    async listAlbums(req, res) {
      try {
        const { folderName, hashIndex } = req.userContext;
        const albums = albumStore.listForFolder(folderName).map((a) => hydrateAlbumSummary(a, hashIndex));
        return res.json({ success: true, albums });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async createAlbum(req, res) {
      try {
        const { folderName, hashIndex } = req.userContext;
        const body = req.body || {};
        const verified = [];
        for (const h of Array.isArray(body.hashes) ? body.hashes : []) {
          const found = await hashIndex.lookup(h, { allowStatFastPath: true });
          if (found.status !== 'missing' && found.record && !found.record.deletedAt) {
            verified.push(found.masterHash);
          }
        }
        const created = await albumStore.createAlbum({
          folderName,
          name: body.name,
          category: body.category,
          description: body.description,
          hashes: verified,
          coverHash: body.coverHash || verified[0] || null,
        });
        return res.status(201).json({
          success: true,
          album: hydrateAlbumSummary(created, hashIndex),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({ success: false, error: err.message });
      }
    },

    async getAlbum(req, res) {
      try {
        const { folderName, hashIndex } = req.userContext;
        const album = albumStore.getAlbum(req.params.id, folderName);
        if (!album) {
          return res.status(404).json({ success: false, error: 'Album not found.' });
        }
        const photos = await resolveActivePhotos(hashIndex, album.hashes);
        return res.json({
          success: true,
          album: hydrateAlbumSummary(album, hashIndex),
          photos,
        });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async updateAlbum(req, res) {
      try {
        const { folderName, hashIndex } = req.userContext;
        const body = req.body || {};
        const updated = await albumStore.updateAlbum(req.params.id, folderName, {
          name: body.name,
          category: body.category,
          description: body.description,
          coverHash: body.coverHash,
        });
        if (!updated) {
          return res.status(404).json({ success: false, error: 'Album not found.' });
        }
        return res.json({
          success: true,
          album: hydrateAlbumSummary(updated, hashIndex),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({ success: false, error: err.message });
      }
    },

    async deleteAlbum(req, res) {
      try {
        const { folderName } = req.userContext;
        const ok = await albumStore.deleteAlbum(req.params.id, folderName);
        if (!ok) {
          return res.status(404).json({ success: false, error: 'Album not found.' });
        }
        return res.json({ success: true, deleted: true });
      } catch (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
    },

    async addPhotosToAlbum(req, res) {
      try {
        const { folderName, hashIndex } = req.userContext;
        const rawHashes = req.body && Array.isArray(req.body.hashes) ? req.body.hashes : [];
        if (rawHashes.length === 0) {
          return res.status(400).json({ success: false, error: 'Non-empty "hashes" array is required.' });
        }
        const verified = [];
        for (const h of rawHashes) {
          const found = await hashIndex.lookup(h, { allowStatFastPath: true });
          if (found.status !== 'missing' && found.record && !found.record.deletedAt) {
            verified.push(found.masterHash);
          }
        }
        const out = await albumStore.addPhotos(req.params.id, folderName, verified);
        if (!out) {
          return res.status(404).json({ success: false, error: 'Album not found.' });
        }
        return res.json({
          success: true,
          addedCount: out.addedCount,
          album: hydrateAlbumSummary(out.album, hashIndex),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({ success: false, error: err.message });
      }
    },

    async removePhotosFromAlbum(req, res) {
      try {
        const { folderName, hashIndex } = req.userContext;
        const rawHashes = req.body && Array.isArray(req.body.hashes) ? req.body.hashes : [];
        if (rawHashes.length === 0) {
          return res.status(400).json({ success: false, error: 'Non-empty "hashes" array is required.' });
        }
        const out = await albumStore.removePhotos(req.params.id, folderName, rawHashes);
        if (!out) {
          return res.status(404).json({ success: false, error: 'Album not found.' });
        }
        return res.json({
          success: true,
          removedCount: out.removedCount,
          album: hydrateAlbumSummary(out.album, hashIndex),
        });
      } catch (err) {
        return res.status(err.statusCode || 500).json({ success: false, error: err.message });
      }
    },
  };
}

module.exports = { createAlbumController };
