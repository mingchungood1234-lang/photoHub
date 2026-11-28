/**
 * CUSTOM ALBUMS STORE (`data/albums.json`)
 *
 * Manages per-user custom albums (Trips, Events, Family, Custom) with atomic disk persistence
 * and strict `folderName` tenant isolation.
 */

const crypto = require('crypto');
const fsp = require('fs/promises');
const path = require('path');

const VALID_CATEGORIES = new Set(['trip', 'event', 'family', 'custom']);
const MAX_CATEGORY_LENGTH = 40;
const MAX_ALBUMS_PER_USER = 300;
const MAX_PHOTOS_PER_ALBUM = 2000;

function normalizeCategory(raw) {
  const cleaned = String(raw || '')
    .replace(/[\x00-\x1F\x7F]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_CATEGORY_LENGTH);
  if (!cleaned) return 'custom';
  const lower = cleaned.toLowerCase();
  if (VALID_CATEGORIES.has(lower)) return lower;
  return cleaned;
}

function normalizeHashes(hashes = []) {
  const out = [];
  const seen = new Set();
  for (const h of hashes || []) {
    const norm = String(h || '').trim().toLowerCase();
    if (!norm || seen.has(norm)) continue;
    seen.add(norm);
    out.push(norm);
    if (out.length >= MAX_PHOTOS_PER_ALBUM) break;
  }
  return out;
}

class AlbumStore {
  constructor(dataDir) {
    this.filePath = path.join(dataDir, 'albums.json');
    this.albums = new Map(); // id -> albumRecord
    this.writePromise = Promise.resolve();
  }

  async init() {
    try {
      await fsp.mkdir(path.dirname(this.filePath), { recursive: true });
      const raw = await fsp.readFile(this.filePath, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') {
        for (const [id, rec] of Object.entries(parsed)) {
          if (!rec || !rec.id || !rec.name || !Array.isArray(rec.hashes)) continue;
          this.albums.set(id, {
            ...rec,
            category: normalizeCategory(rec.category),
            hashes: normalizeHashes(rec.hashes),
          });
        }
      }
    } catch (err) {
      if (err && err.code !== 'ENOENT') {
        console.warn('Warning: could not read albums.json:', err.message);
      }
    }
  }

  async _persist() {
    const snapshot = JSON.stringify(Object.fromEntries(this.albums.entries()));
    const tmpFile = `${this.filePath}.${process.pid}.tmp`;
    this.writePromise = this.writePromise
      .catch(() => {})
      .then(async () => {
        await fsp.mkdir(path.dirname(this.filePath), { recursive: true });
        await fsp.writeFile(tmpFile, snapshot, 'utf8');
        await fsp.rename(tmpFile, this.filePath);
      });
    return this.writePromise;
  }

  listForFolder(folderName) {
    const target = folderName || null;
    const out = [];
    for (const rec of this.albums.values()) {
      if ((rec.folderName || null) === target) {
        out.push({ ...rec, hashes: rec.hashes.slice() });
      }
    }
    out.sort((a, b) => String(b.updatedAt || b.createdAt).localeCompare(String(a.updatedAt || a.createdAt)));
    return out;
  }

  getAlbum(id, folderName) {
    const rec = this.albums.get(String(id || '').trim());
    if (!rec) return null;
    if ((rec.folderName || null) !== (folderName || null)) return null;
    return rec;
  }

  async createAlbum({ folderName = null, name, category = 'custom', description = '', hashes = [], coverHash = null }) {
    const cleanName = String(name || '').trim().slice(0, 80);
    if (!cleanName) {
      const err = new Error('Album name is required.');
      err.statusCode = 400;
      throw err;
    }

    const existingForFolder = this.listForFolder(folderName);
    if (existingForFolder.length >= MAX_ALBUMS_PER_USER) {
      const err = new Error(`Maximum of ${MAX_ALBUMS_PER_USER} albums reached.`);
      err.statusCode = 400;
      throw err;
    }

    const cleanHashes = normalizeHashes(hashes);
    const cleanCover = coverHash ? String(coverHash).trim().toLowerCase() : null;
    const nowIso = new Date().toISOString();
    const id = `alb_${crypto.randomBytes(9).toString('hex')}`;

    const record = {
      id,
      folderName: folderName || null,
      name: cleanName,
      category: normalizeCategory(category),
      description: String(description || '').trim().slice(0, 280),
      coverHash: cleanCover && cleanHashes.includes(cleanCover) ? cleanCover : cleanHashes[0] || null,
      hashes: cleanHashes,
      createdAt: nowIso,
      updatedAt: nowIso,
    };

    this.albums.set(id, record);
    await this._persist();
    return { ...record, hashes: record.hashes.slice() };
  }

  async updateAlbum(id, folderName, { name, category, description, coverHash } = {}) {
    const rec = this.getAlbum(id, folderName);
    if (!rec) return null;

    if (name !== undefined) {
      const cleanName = String(name || '').trim().slice(0, 80);
      if (!cleanName) {
        const err = new Error('Album name cannot be empty.');
        err.statusCode = 400;
        throw err;
      }
      rec.name = cleanName;
    }
    if (category !== undefined) {
      rec.category = normalizeCategory(category);
    }
    if (description !== undefined) {
      rec.description = String(description || '').trim().slice(0, 280);
    }
    if (coverHash !== undefined) {
      const cleanCover = coverHash ? String(coverHash).trim().toLowerCase() : null;
      rec.coverHash = cleanCover || rec.hashes[0] || null;
    }
    rec.updatedAt = new Date().toISOString();

    await this._persist();
    return { ...rec, hashes: rec.hashes.slice() };
  }

  async addPhotos(id, folderName, hashes = []) {
    const rec = this.getAlbum(id, folderName);
    if (!rec) return null;

    const existing = new Set(rec.hashes);
    let addedCount = 0;
    for (const h of normalizeHashes(hashes)) {
      if (!existing.has(h) && rec.hashes.length < MAX_PHOTOS_PER_ALBUM) {
        existing.add(h);
        rec.hashes.push(h);
        addedCount += 1;
      }
    }
    if (!rec.coverHash && rec.hashes.length > 0) {
      rec.coverHash = rec.hashes[0];
    }
    if (addedCount > 0) {
      rec.updatedAt = new Date().toISOString();
      await this._persist();
    }
    return { album: { ...rec, hashes: rec.hashes.slice() }, addedCount };
  }

  async removePhotos(id, folderName, hashes = []) {
    const rec = this.getAlbum(id, folderName);
    if (!rec) return null;

    const toRemove = new Set(normalizeHashes(hashes));
    const before = rec.hashes.length;
    rec.hashes = rec.hashes.filter((h) => !toRemove.has(h));
    const removedCount = before - rec.hashes.length;
    if (rec.coverHash && toRemove.has(rec.coverHash)) {
      rec.coverHash = rec.hashes[0] || null;
    }
    if (removedCount > 0) {
      rec.updatedAt = new Date().toISOString();
      await this._persist();
    }
    return { album: { ...rec, hashes: rec.hashes.slice() }, removedCount };
  }

  async deleteAlbum(id, folderName) {
    const rec = this.getAlbum(id, folderName);
    if (!rec) return false;
    this.albums.delete(rec.id);
    await this._persist();
    return true;
  }

  getStatsByFolder() {
    const counts = new Map();
    let totalAlbums = 0;
    for (const rec of this.albums.values()) {
      totalAlbums += 1;
      const key = rec.folderName || '__ROOT__';
      counts.set(key, (counts.get(key) || 0) + 1);
    }
    return { totalAlbums, countsByFolder: counts };
  }
}

module.exports = { AlbumStore, VALID_CATEGORIES };
