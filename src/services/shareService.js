/**
 * PUBLIC EXPIRING SHARE LINK STORE (`data/shares.json`)
 *
 * Manages expiring, passcode-optional share links for single photos or multi-photo selections.
 * Uses Node built-in `crypto.scryptSync` + timing-safe comparison for optional passcodes.
 */

const crypto = require('crypto');
const fsp = require('fs/promises');
const path = require('path');

const DEFAULT_EXPIRY_HOURS = 168; // 7 days
const MAX_EXPIRY_HOURS = 720; // 30 days
const MAX_SHARES_PER_LINK = 200;

function hashPasscode(passcode, salt) {
  return crypto.scryptSync(String(passcode), salt, 32).toString('hex');
}

function verifyPasscodeHash(passcode, salt, expectedHex) {
  if (!expectedHex || !salt) return true;
  if (typeof passcode !== 'string' || !passcode) return false;
  try {
    const actual = Buffer.from(hashPasscode(passcode, salt), 'hex');
    const expected = Buffer.from(expectedHex, 'hex');
    if (actual.length !== expected.length) return false;
    return crypto.timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}

class ShareStore {
  constructor(dataDir) {
    this.filePath = path.join(dataDir, 'shares.json');
    this.shares = new Map(); // token -> shareRecord
    this.writePromise = Promise.resolve();
  }

  async init() {
    try {
      await fsp.mkdir(path.dirname(this.filePath), { recursive: true });
      const raw = await fsp.readFile(this.filePath, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') {
        const now = Date.now();
        for (const [token, rec] of Object.entries(parsed)) {
          if (!rec || !rec.token || !Array.isArray(rec.hashes)) continue;
          const exp = Date.parse(rec.expiresAt || '');
          if (!Number.isNaN(exp) && exp <= now) continue;
          this.shares.set(token, rec);
        }
      }
    } catch (err) {
      if (err && err.code !== 'ENOENT') {
        console.warn('Warning: could not read shares.json:', err.message);
      }
    }
  }

  async _persist() {
    const snapshot = JSON.stringify(Object.fromEntries(this.shares.entries()));
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

  _pruneExpired() {
    const now = Date.now();
    let pruned = false;
    for (const [token, rec] of this.shares.entries()) {
      const exp = Date.parse(rec.expiresAt || '');
      if (!Number.isNaN(exp) && exp <= now) {
        this.shares.delete(token);
        pruned = true;
      }
    }
    if (pruned) {
      this._persist().catch(() => {});
    }
  }

  async createShare({
    folderName = null,
    ownerSub = null,
    ownerEmail = null,
    ownerName = null,
    title = '',
    hashes = [],
    expiresInHours = DEFAULT_EXPIRY_HOURS,
    passcode = '',
    nodeId = null,
  }) {
    this._pruneExpired();
    const cleanHashes = [];
    const seen = new Set();
    for (const h of hashes) {
      const norm = String(h || '').trim().toLowerCase();
      if (!norm || seen.has(norm)) continue;
      seen.add(norm);
      cleanHashes.push(norm);
      if (cleanHashes.length >= MAX_SHARES_PER_LINK) break;
    }
    if (cleanHashes.length === 0) {
      const err = new Error('At least one photo hash is required.');
      err.statusCode = 400;
      throw err;
    }

    const hoursRaw = Number(expiresInHours);
    const safeHours =
      Number.isFinite(hoursRaw) && hoursRaw > 0
        ? Math.min(MAX_EXPIRY_HOURS, Math.max(1, Math.round(hoursRaw)))
        : DEFAULT_EXPIRY_HOURS;

    const rawToken = crypto.randomBytes(18).toString('base64url');
    const cleanNodeId =
      nodeId && nodeId !== 'primary' && /^[a-zA-Z0-9_-]{1,32}$/.test(String(nodeId))
        ? String(nodeId)
        : null;
    const token = cleanNodeId ? `${cleanNodeId}~${rawToken}` : rawToken;

    const now = Date.now();
    const cleanPass = String(passcode || '').trim();
    const passcodeSalt = cleanPass ? crypto.randomBytes(12).toString('hex') : null;
    const passcodeHash = cleanPass ? hashPasscode(cleanPass, passcodeSalt) : null;

    const record = {
      token,
      folderName: folderName || null,
      ownerSub: ownerSub || null,
      ownerEmail: ownerEmail || null,
      ownerName: ownerName || null,
      title: String(title || '').trim().slice(0, 120) || (cleanHashes.length === 1 ? 'Shared Photo' : `${cleanHashes.length} Shared Photos`),
      hashes: cleanHashes,
      createdAt: new Date(now).toISOString(),
      expiresAt: new Date(now + safeHours * 3600 * 1000).toISOString(),
      expiresInHours: safeHours,
      passcodeSalt,
      passcodeHash,
    };

    this.shares.set(token, record);
    await this._persist();
    return this.formatPublicMeta(record);
  }

  getShare(token) {
    this._pruneExpired();
    const rec = this.shares.get(String(token || '').trim());
    if (!rec) return null;
    const exp = Date.parse(rec.expiresAt || '');
    if (!Number.isNaN(exp) && exp <= Date.now()) {
      this.shares.delete(rec.token);
      this._persist().catch(() => {});
      return null;
    }
    return rec;
  }

  verifyPasscode(shareRecord, providedPasscode) {
    if (!shareRecord || !shareRecord.passcodeHash) return true;
    return verifyPasscodeHash(
      String(providedPasscode || '').trim(),
      shareRecord.passcodeSalt,
      shareRecord.passcodeHash
    );
  }

  listForFolder(folderName) {
    this._pruneExpired();
    const target = folderName || null;
    const out = [];
    for (const rec of this.shares.values()) {
      if ((rec.folderName || null) === target) {
        out.push(this.formatPublicMeta(rec));
      }
    }
    out.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    return out;
  }

  async revokeShare(token, folderName) {
    const rec = this.shares.get(String(token || '').trim());
    if (!rec) return false;
    if ((rec.folderName || null) !== (folderName || null)) {
      return false;
    }
    this.shares.delete(rec.token);
    await this._persist();
    return true;
  }

  formatPublicMeta(rec) {
    return {
      token: rec.token,
      title: rec.title,
      itemCount: rec.hashes.length,
      hashes: rec.hashes,
      hasPasscode: Boolean(rec.passcodeHash),
      createdAt: rec.createdAt,
      expiresAt: rec.expiresAt,
      expiresInHours: rec.expiresInHours,
      ownerName: rec.ownerName || null,
    };
  }
}

module.exports = { ShareStore, DEFAULT_EXPIRY_HOURS, MAX_EXPIRY_HOURS };
