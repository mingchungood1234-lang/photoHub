/**
 * STREAMING PKZIP (STORE MODE) ARCHIVE WRITER — Zero External Dependencies
 *
 * Streams multiple photos/videos into a standard `.zip` HTTP response with zero full-archive RAM buffering.
 * Uses ZIP STORE (compression method 0) with Data Descriptor (bit 3) + UTF-8 filename flag (bit 11),
 * which is ideal for already-compressed JPEG/HEIC/MP4 media and works natively on Windows, macOS, iOS, and Android.
 */

const fs = require('fs');
const { Readable } = require('stream');

// Precomputed standard IEEE 802.3 CRC-32 lookup table
const CRC32_TABLE = (() => {
  const tbl = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) !== 0 ? (0xedb88320 ^ (c >>> 1)) >>> 0 : c >>> 1;
    }
    tbl[i] = c >>> 0;
  }
  return tbl;
})();

function crc32Update(crc, buf) {
  let c = crc >>> 0;
  for (let i = 0; i < buf.length; i++) {
    c = (CRC32_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8)) >>> 0;
  }
  return c >>> 0;
}

function toDosTimeDate(date) {
  const d = date instanceof Date && !Number.isNaN(date.getTime()) ? date : new Date();
  const year = Math.min(2107, Math.max(1980, d.getFullYear()));
  const dosDate = (((year - 1980) & 0x7f) << 9) | (((d.getMonth() + 1) & 0x0f) << 5) | (d.getDate() & 0x1f);
  const dosTime = ((d.getHours() & 0x1f) << 11) | ((d.getMinutes() & 0x3f) << 5) | ((d.getSeconds() >> 1) & 0x1f);
  return { dosTime, dosDate };
}

function sanitizeZipEntryName(rawName, usedNames) {
  const base = String(rawName || 'photo.bin')
    .replace(/[\\/:*?"<>|\x00-\x1f]/g, '_')
    .replace(/^\.+/, '')
    .trim() || 'photo.bin';

  let candidate = base;
  let counter = 2;
  const dotIdx = base.lastIndexOf('.');
  const stem = dotIdx > 0 ? base.slice(0, dotIdx) : base;
  const ext = dotIdx > 0 ? base.slice(dotIdx) : '';

  while (usedNames.has(candidate.toLowerCase())) {
    candidate = `${stem} (${counter++})${ext}`;
  }
  usedNames.add(candidate.toLowerCase());
  return candidate;
}

function writeBufferAsync(res, buf) {
  if (res.destroyed || res.writableEnded) {
    return Promise.resolve(false);
  }
  if (res.write(buf)) {
    return Promise.resolve(true);
  }
  return new Promise((resolve) => {
    const onDrain = () => {
      cleanup();
      resolve(true);
    };
    const onClose = () => {
      cleanup();
      resolve(false);
    };
    const cleanup = () => {
      res.off('drain', onDrain);
      res.off('close', onClose);
      res.off('error', onClose);
    };
    res.on('drain', onDrain);
    res.on('close', onClose);
    res.on('error', onClose);
  });
}

/**
 * Streams an array of `{ name, date?, openStream: async () => Readable | null }` entries into `res`.
 */
async function streamZipToResponse(res, entries) {
  const usedNames = new Set();
  const centralDirRecords = [];
  let offset = 0;

  for (const item of entries) {
    if (res.destroyed || res.writableEnded) break;
    let stream;
    try {
      stream = await item.openStream();
    } catch {
      continue;
    }
    if (!stream) continue;

    const entryName = sanitizeZipEntryName(item.name, usedNames);
    const nameBuf = Buffer.from(entryName, 'utf8');
    const { dosTime, dosDate } = toDosTimeDate(item.date);
    const localHeaderOffset = offset;

    // Local File Header (30 bytes + filename), flags = 0x0808 (bit 3 data descriptor + bit 11 UTF-8)
    const lfh = Buffer.alloc(30 + nameBuf.length);
    lfh.writeUInt32LE(0x04034b50, 0);
    lfh.writeUInt16LE(20, 4); // version needed 2.0
    lfh.writeUInt16LE(0x0808, 6);
    lfh.writeUInt16LE(0, 8); // method 0 = STORE
    lfh.writeUInt16LE(dosTime, 10);
    lfh.writeUInt16LE(dosDate, 12);
    lfh.writeUInt32LE(0, 14); // crc32 in data descriptor
    lfh.writeUInt32LE(0, 18); // compSize in data descriptor
    lfh.writeUInt32LE(0, 22); // uncompSize in data descriptor
    lfh.writeUInt16LE(nameBuf.length, 26);
    lfh.writeUInt16LE(0, 28); // extra len
    nameBuf.copy(lfh, 30);

    if (!(await writeBufferAsync(res, lfh))) {
      stream.destroy();
      return;
    }
    offset += lfh.length;

    let crc = 0xffffffff;
    let byteCount = 0;

    try {
      for await (const rawChunk of stream) {
        if (res.destroyed || res.writableEnded) {
          stream.destroy();
          return;
        }
        const chunk = Buffer.isBuffer(rawChunk) ? rawChunk : Buffer.from(rawChunk);
        crc = crc32Update(crc, chunk);
        byteCount += chunk.length;
        if (!(await writeBufferAsync(res, chunk))) {
          stream.destroy();
          return;
        }
        offset += chunk.length;
      }
    } catch {
      stream.destroy();
      // Abort stream cleanly if mid-entry read fails
      if (!res.writableEnded) res.end();
      return;
    }

    const finalCrc = (crc ^ 0xffffffff) >>> 0;

    // Data Descriptor (16 bytes)
    const dd = Buffer.alloc(16);
    dd.writeUInt32LE(0x08074b50, 0);
    dd.writeUInt32LE(finalCrc, 4);
    dd.writeUInt32LE(byteCount >>> 0, 8);
    dd.writeUInt32LE(byteCount >>> 0, 12);

    if (!(await writeBufferAsync(res, dd))) return;
    offset += dd.length;

    // Build Central Directory File Header (46 bytes + filename)
    const cdh = Buffer.alloc(46 + nameBuf.length);
    cdh.writeUInt32LE(0x02014b50, 0);
    cdh.writeUInt16LE(20, 4); // version made by
    cdh.writeUInt16LE(20, 6); // version needed
    cdh.writeUInt16LE(0x0808, 8);
    cdh.writeUInt16LE(0, 10); // STORE
    cdh.writeUInt16LE(dosTime, 12);
    cdh.writeUInt16LE(dosDate, 14);
    cdh.writeUInt32LE(finalCrc, 16);
    cdh.writeUInt32LE(byteCount >>> 0, 20);
    cdh.writeUInt32LE(byteCount >>> 0, 24);
    cdh.writeUInt16LE(nameBuf.length, 28);
    cdh.writeUInt16LE(0, 30); // extra len
    cdh.writeUInt16LE(0, 32); // comment len
    cdh.writeUInt16LE(0, 34); // disk start
    cdh.writeUInt16LE(0, 36); // internal attrs
    cdh.writeUInt32LE(0, 38); // external attrs
    cdh.writeUInt32LE(localHeaderOffset >>> 0, 42);
    nameBuf.copy(cdh, 46);
    centralDirRecords.push(cdh);
  }

  const centralDirOffset = offset;
  let centralDirSize = 0;
  for (const cdh of centralDirRecords) {
    if (!(await writeBufferAsync(res, cdh))) return;
    centralDirSize += cdh.length;
  }

  // End of Central Directory Record (22 bytes)
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(centralDirRecords.length & 0xffff, 8);
  eocd.writeUInt16LE(centralDirRecords.length & 0xffff, 10);
  eocd.writeUInt32LE(centralDirSize >>> 0, 12);
  eocd.writeUInt32LE(centralDirOffset >>> 0, 16);
  eocd.writeUInt16LE(0, 20);

  await writeBufferAsync(res, eocd);
  if (!res.writableEnded) {
    res.end();
  }
}

function createDiskReadStream(filePath) {
  return fs.createReadStream(filePath);
}

async function createHttpReadStream(url) {
  const upstream = await fetch(url);
  if (!upstream.ok || !upstream.body) return null;
  return Readable.fromWeb(upstream.body);
}

module.exports = {
  streamZipToResponse,
  createDiskReadStream,
  createHttpReadStream,
  crc32Update,
};
