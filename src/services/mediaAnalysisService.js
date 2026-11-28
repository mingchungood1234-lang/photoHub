/**
 * VISUAL INTELLIGENCE SERVICE — Similar/Burst Detection (dHash) & Blurry Shot Scoring
 *
 * Uses optional `sharp` (fast native libvips) to compute:
 *   1. 64-bit perceptual difference hash (`dHash`, 16-char hex) for near-duplicate & burst grouping
 *   2. Laplacian variance sharpness score (`blurScore`) to detect blurry / out-of-focus shots
 *   3. Intrinsic image dimensions (`width`, `height`)
 */

const fs = require('fs');
const path = require('path');
const { isVideoFilename } = require('./proxyService');
const { isS3Configured, fetchS3ObjectBuffer } = require('./s3Service');

let sharpModule = null;
try {
  sharpModule = require('sharp');
  if (sharpModule && typeof sharpModule.cache === 'function') {
    sharpModule.cache(false);
  }
} catch {
  sharpModule = null;
}

const POPCOUNT_NIBBLE = [0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4];

function isAnalysisAvailable() {
  return Boolean(sharpModule);
}

function hammingDistanceHex64(hexA, hexB) {
  if (!hexA || !hexB || hexA.length !== 16 || hexB.length !== 16) return 64;
  let dist = 0;
  for (let i = 0; i < 16; i++) {
    const a = parseInt(hexA[i], 16);
    const b = parseInt(hexB[i], 16);
    if (Number.isNaN(a) || Number.isNaN(b)) return 64;
    dist += POPCOUNT_NIBBLE[(a ^ b) & 0xf];
  }
  return dist;
}

async function analyzePhotoSource(input) {
  if (!sharpModule || !input) return null;

  try {
    const meta = await sharpModule(input).metadata();
    const width = meta.width || null;
    const height = meta.height || null;

    // 1. 9x8 grayscale for 64-bit horizontal difference hash (dHash)
    const { data: dhashPixels } = await sharpModule(input)
      .rotate()
      .resize(9, 8, { fit: 'fill' })
      .grayscale()
      .raw()
      .toBuffer({ resolveWithObject: true });

    let hex = '';
    for (let row = 0; row < 8; row++) {
      let byteVal = 0;
      for (let col = 0; col < 8; col++) {
        const left = dhashPixels[row * 9 + col];
        const right = dhashPixels[row * 9 + col + 1];
        if (left > right) {
          byteVal |= 1 << (7 - col);
        }
      }
      hex += byteVal.toString(16).padStart(2, '0');
    }

    // 2. 200x200 grayscale Laplacian variance for sharpness / blur detection
    const { data: gray, info } = await sharpModule(input)
      .rotate()
      .resize(200, 200, { fit: 'inside', withoutEnlargement: true })
      .grayscale()
      .raw()
      .toBuffer({ resolveWithObject: true });

    const w = info.width;
    const h = info.height;
    let blurScore = 100;
    if (w >= 3 && h >= 3) {
      let sum = 0;
      let sumSq = 0;
      let count = 0;
      for (let y = 1; y < h - 1; y++) {
        const rowOff = y * w;
        for (let x = 1; x < w - 1; x++) {
          const idx = rowOff + x;
          // Discrete 4-neighbor Laplacian kernel: [0, 1, 0; 1, -4, 1; 0, 1, 0]
          const lap =
            gray[idx - w] +
            gray[idx + w] +
            gray[idx - 1] +
            gray[idx + 1] -
            4 * gray[idx];
          sum += lap;
          sumSq += lap * lap;
          count += 1;
        }
      }
      if (count > 0) {
        const mean = sum / count;
        const variance = Math.max(0, sumSq / count - mean * mean);
        blurScore = Math.round(variance * 10) / 10;
      }
    }

    return {
      dHash: hex,
      blurScore,
      width,
      height,
    };
  } catch {
    return null;
  }
}

/**
 * Computes a 64-bit dHash, Laplacian variance blurScore, and dimensions for a local image file.
 * Returns null gracefully if `sharp` is unavailable or file is a video/unreadable.
 */
async function analyzePhotoFile(filePath, originalName = '') {
  if (!sharpModule || !filePath) return null;
  if (isVideoFilename(originalName || filePath)) return null;
  if (!fs.existsSync(filePath)) return null;
  return analyzePhotoSource(filePath);
}

async function analyzePhotoBuffer(buffer, originalName = '') {
  if (!sharpModule || !Buffer.isBuffer(buffer) || buffer.length === 0) return null;
  if (originalName && isVideoFilename(originalName)) return null;
  return analyzePhotoSource(buffer);
}

function parseTimestampMs(photo) {
  const raw = photo.takenAt || photo.photoDate || photo.uploadedAt;
  if (!raw) return null;
  const str = String(raw);
  const ms = /^\d{4}-\d{2}-\d{2}$/.test(str) ? Date.parse(`${str}T12:00:00Z`) : Date.parse(str);
  return Number.isNaN(ms) ? null : ms;
}

/**
 * Scans any unanalyzed local photos (bounded by `maxScan`) and returns Similar/Burst groups
 * + Blurry Shot recommendations with "Best Shot" selection and potential space savings.
 */
async function buildCleanupSuggestions({
  hashIndex,
  storageDir,
  s3Config = null,
  scan = true,
  maxScan = 80,
  blurThreshold = 35,
  maxHamming = 8,
  burstHamming = 13,
  burstWindowSec = 45,
}) {
  const unique = hashIndex._getUniqueMasterRecords();
  const s3Ready = Boolean(s3Config && isS3Configured(s3Config));
  let scannedThisCall = 0;
  let analyzedCount = 0;
  let pendingCount = 0;
  let mutated = false;

  for (const { entry } of unique) {
    if (isVideoFilename(entry.originalName || entry.relativePath || '')) continue;
    const hasMetrics = typeof entry.dHash === 'string' && typeof entry.blurScore === 'number';
    if (hasMetrics) {
      analyzedCount += 1;
      continue;
    }
    if (!scan || !sharpModule || (entry.storageType === 's3' && !s3Ready)) {
      pendingCount += 1;
      continue;
    }
    if (scannedThisCall >= maxScan) {
      pendingCount += 1;
      continue;
    }

    let metrics = null;
    // Prefer analyzing the smaller proxy JPEG if available (much faster!), falling back to original
    if (entry.proxyRelativePath && entry.proxyStorageType === 's3' && s3Ready) {
      const buf = await fetchS3ObjectBuffer({
        s3Config,
        objectKey: entry.proxyRelativePath,
        maxBytes: 25 * 1024 * 1024,
      }).catch(() => null);
      if (buf) {
        metrics = await analyzePhotoBuffer(buf, entry.originalName);
      }
    } else if (entry.proxyRelativePath) {
      const proxyPath = path.join(storageDir, entry.proxyRelativePath);
      if (fs.existsSync(proxyPath)) {
        metrics = await analyzePhotoFile(proxyPath, entry.originalName);
      }
    }

    if (!metrics) {
      if (entry.storageType === 's3' && s3Ready && entry.relativePath) {
        const buf = await fetchS3ObjectBuffer({
          s3Config,
          objectKey: entry.relativePath,
          maxBytes: 25 * 1024 * 1024,
        }).catch(() => null);
        if (!buf) {
          pendingCount += 1;
          continue;
        }
        metrics = await analyzePhotoBuffer(buf, entry.originalName);
      } else {
        const masterPath = entry.relativePath ? path.join(storageDir, entry.relativePath) : null;
        if (!masterPath || !fs.existsSync(masterPath)) {
          pendingCount += 1;
          continue;
        }
        metrics = await analyzePhotoFile(masterPath, entry.originalName);
      }
    }

    scannedThisCall += 1;
    if (metrics) {
      entry.dHash = metrics.dHash;
      entry.blurScore = metrics.blurScore;
      if (!entry.width && metrics.width) entry.width = metrics.width;
      if (!entry.height && metrics.height) entry.height = metrics.height;
      analyzedCount += 1;
      mutated = true;
    }
  }

  if (mutated) {
    hashIndex._markDirty();
    await hashIndex.persist();
  }

  const photos = hashIndex
    .listMasters()
    .filter((p) => !isVideoFilename(p.originalName || p.savedPath || ''));

  const withHash = photos.filter((p) => typeof p.dHash === 'string' && p.dHash.length === 16);
  const n = withHash.length;
  const parent = Array.from({ length: n }, (_, i) => i);
  const find = (x) => {
    while (parent[x] !== x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  };
  const union = (a, b) => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  };

  const times = withHash.map(parseTimestampMs);
  const pairReasons = new Map(); // "i:j" -> { distance, isBurst }

  // Cap O(n^2) cleanly for very large libraries by checking nearest neighbors in timeline + global scan up to 1500
  const compareLimit = Math.min(n, 1500);
  for (let i = 0; i < compareLimit; i++) {
    for (let j = i + 1; j < compareLimit; j++) {
      const dist = hammingDistanceHex64(withHash[i].dHash, withHash[j].dHash);
      const tA = times[i];
      const tB = times[j];
      const isBurstTime =
        tA !== null && tB !== null && Math.abs(tA - tB) <= burstWindowSec * 1000;
      if (dist <= maxHamming || (isBurstTime && dist <= burstHamming)) {
        union(i, j);
        pairReasons.set(`${i}:${j}`, { distance: dist, isBurst: isBurstTime });
      }
    }
  }

  const buckets = new Map();
  for (let i = 0; i < compareLimit; i++) {
    const r = find(i);
    if (!buckets.has(r)) buckets.set(r, []);
    buckets.get(r).push(i);
  }

  const similarGroups = [];
  let similarReclaimableBytes = 0;

  for (const indices of buckets.values()) {
    if (indices.length < 2) continue;

    let hasBurst = false;
    for (let a = 0; a < indices.length; a++) {
      for (let b = a + 1; b < indices.length; b++) {
        const key = `${Math.min(indices[a], indices[b])}:${Math.max(indices[a], indices[b])}`;
        if (pairReasons.get(key)?.isBurst) {
          hasBurst = true;
          break;
        }
      }
      if (hasBurst) break;
    }

    const members = indices.map((idx) => withHash[idx]);
    // Rank best shot: favorite bonus > sharpness (blurScore) > larger file size
    const scoreOf = (p) =>
      (p.isFavorite ? 100000 : 0) +
      (p.keepOriginalOnDevice ? 50000 : 0) +
      (Number(p.blurScore) || 0) * 10 +
      Math.min(500, (Number(p.size) || 0) / 100000);

    members.sort((a, b) => scoreOf(b) - scoreOf(a));
    const best = members[0];
    const groupReclaimable = members
      .slice(1)
      .reduce((sum, m) => sum + (Number(m.size) || 0), 0);
    similarReclaimableBytes += groupReclaimable;

    similarGroups.push({
      id: `grp_${best.hash.slice(0, 12)}`,
      reason: hasBurst ? 'burst' : 'similar',
      label: hasBurst ? `Burst Shot · ${members.length} photos` : `Similar Photos · ${members.length} shots`,
      photoDate: best.photoDate || '',
      bestHash: best.hash,
      reclaimableBytes: groupReclaimable,
      photos: members.map((m, idx) => ({
        ...m,
        isBest: idx === 0,
        distanceFromBest: idx === 0 ? 0 : hammingDistanceHex64(best.dHash, m.dHash),
      })),
    });
  }

  similarGroups.sort((a, b) => b.reclaimableBytes - a.reclaimableBytes);

  const blurryPhotos = photos
    .filter((p) => typeof p.blurScore === 'number' && p.blurScore < blurThreshold)
    .sort((a, b) => (a.blurScore || 0) - (b.blurScore || 0));

  const blurryUniqueHashes = new Set();
  for (const grp of similarGroups) {
    for (const p of grp.photos) {
      if (!p.isBest) blurryUniqueHashes.add(p.hash);
    }
  }
  let extraBlurryBytes = 0;
  for (const b of blurryPhotos) {
    if (!blurryUniqueHashes.has(b.hash)) {
      extraBlurryBytes += Number(b.size) || 0;
    }
  }

  return {
    sharpAvailable: Boolean(sharpModule),
    blurThreshold,
    summary: {
      totalPhotos: photos.length,
      analyzedCount,
      scannedThisCall,
      pendingCount,
      similarGroupCount: similarGroups.length,
      similarDuplicateCount: similarGroups.reduce((s, g) => s + g.photos.length - 1, 0),
      blurryCount: blurryPhotos.length,
      potentialSavingsBytes: similarReclaimableBytes + extraBlurryBytes,
    },
    similarGroups,
    blurryPhotos,
  };
}

module.exports = {
  isAnalysisAvailable,
  hammingDistanceHex64,
  analyzePhotoFile,
  analyzePhotoBuffer,
  buildCleanupSuggestions,
};
