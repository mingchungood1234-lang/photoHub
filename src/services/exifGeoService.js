/**
 * EXIF DATE, CAMERA & GPS GEO-TAGGING SERVICE (Zero External Dependencies)
 *
 * Extracts DateTimeOriginal, Camera Make/Model, and EXIF GPS latitude/longitude/altitude
 * from JPEG APP1 headers (first 64 KB) and maps coordinates to offline city/country labels
 * so Photo Map & Location Search work instantaneously without external API keys.
 */

const fsp = require('fs/promises');
const path = require('path');

const JPEG_EXTS = new Set(['.jpg', '.jpeg']);

// Curated global offline reverse-geocoding gazetteer: [name, lat, lng]
const WORLD_CITIES = [
  ['Tokyo, Japan', 35.6762, 139.6503],
  ['Osaka, Japan', 34.6937, 135.5023],
  ['Kyoto, Japan', 35.0116, 135.7681],
  ['Sapporo, Japan', 43.0618, 141.3545],
  ['Fukuoka, Japan', 33.5902, 130.4017],
  ['Nagoya, Japan', 35.1815, 136.9066],
  ['Okinawa, Japan', 26.2124, 127.6809],
  ['Seoul, South Korea', 37.5665, 126.978],
  ['Busan, South Korea', 35.1796, 129.0756],
  ['Jeju, South Korea', 33.4996, 126.5312],
  ['Taipei, Taiwan', 25.033, 121.5654],
  ['Kaohsiung, Taiwan', 22.6273, 120.3014],
  ['Taichung, Taiwan', 24.1477, 120.6736],
  ['Hong Kong', 22.3193, 114.1694],
  ['Macau', 22.1987, 113.5439],
  ['Beijing, China', 39.9042, 116.4074],
  ['Shanghai, China', 31.2304, 121.4737],
  ['Shenzhen, China', 22.5431, 114.0579],
  ['Guangzhou, China', 23.1291, 113.2644],
  ['Chengdu, China', 30.5728, 104.0668],
  ['Hangzhou, China', 30.2741, 120.1551],
  ['Xi\'an, China', 34.3416, 108.9398],
  ['Singapore', 1.3521, 103.8198],
  ['Kuala Lumpur, Malaysia', 3.139, 101.6869],
  ['Penang, Malaysia', 5.4141, 100.3288],
  ['Johor Bahru, Malaysia', 1.4927, 103.7414],
  ['Kota Kinabalu, Malaysia', 5.9804, 116.0735],
  ['Kuching, Malaysia', 1.5533, 110.3592],
  ['Malacca, Malaysia', 2.1896, 102.2501],
  ['Ipoh, Malaysia', 4.5975, 101.0901],
  ['Bangkok, Thailand', 13.7563, 100.5018],
  ['Chiang Mai, Thailand', 18.7883, 98.9853],
  ['Phuket, Thailand', 7.8804, 98.3923],
  ['Ho Chi Minh City, Vietnam', 10.8231, 106.6297],
  ['Hanoi, Vietnam', 21.0278, 105.8342],
  ['Da Nang, Vietnam', 16.0544, 108.2022],
  ['Jakarta, Indonesia', -6.2088, 106.8456],
  ['Bali, Indonesia', -8.4095, 115.1889],
  ['Manila, Philippines', 14.5995, 120.9842],
  ['Cebu, Philippines', 10.3157, 123.8854],
  ['Sydney, Australia', -33.8688, 151.2093],
  ['Melbourne, Australia', -37.8136, 144.9631],
  ['Brisbane, Australia', -27.4698, 153.0251],
  ['Perth, Australia', -31.9505, 115.8605],
  ['Auckland, New Zealand', -36.8485, 174.7633],
  ['Queenstown, New Zealand', -45.0312, 168.6626],
  ['Mumbai, India', 19.076, 72.8777],
  ['New Delhi, India', 28.6139, 77.209],
  ['Bengaluru, India', 12.9716, 77.5946],
  ['Dubai, UAE', 25.2048, 55.2708],
  ['Abu Dhabi, UAE', 24.4539, 54.3773],
  ['Doha, Qatar', 25.2854, 51.531],
  ['Istanbul, Turkey', 41.0082, 28.9784],
  ['Cairo, Egypt', 30.0444, 31.2357],
  ['Cape Town, South Africa', -33.9249, 18.4241],
  ['Nairobi, Kenya', -1.2921, 36.8219],
  ['London, UK', 51.5072, -0.1276],
  ['Edinburgh, UK', 55.9533, -3.1883],
  ['Manchester, UK', 53.4808, -2.2426],
  ['Dublin, Ireland', 53.3498, -6.2603],
  ['Paris, France', 48.8566, 2.3522],
  ['Nice, France', 43.7102, 7.262],
  ['Lyon, France', 45.764, 4.8357],
  ['Amsterdam, Netherlands', 52.3676, 4.9041],
  ['Brussels, Belgium', 50.8503, 4.3517],
  ['Berlin, Germany', 52.52, 13.405],
  ['Munich, Germany', 48.1351, 11.582],
  ['Frankfurt, Germany', 50.1109, 8.6821],
  ['Zurich, Switzerland', 47.3769, 8.5417],
  ['Geneva, Switzerland', 46.2044, 6.1432],
  ['Interlaken, Switzerland', 46.6863, 7.8632],
  ['Vienna, Austria', 48.2082, 16.3738],
  ['Prague, Czechia', 50.0755, 14.4378],
  ['Rome, Italy', 41.9028, 12.4964],
  ['Milan, Italy', 45.4642, 9.19],
  ['Venice, Italy', 45.4408, 12.3155],
  ['Florence, Italy', 43.7696, 11.2558],
  ['Barcelona, Spain', 41.3874, 2.1686],
  ['Madrid, Spain', 40.4168, -3.7038],
  ['Lisbon, Portugal', 38.7223, -9.1393],
  ['Athens, Greece', 37.9838, 23.7275],
  ['Santorini, Greece', 36.3932, 25.4615],
  ['Stockholm, Sweden', 59.3293, 18.0686],
  ['Oslo, Norway', 59.9139, 10.7522],
  ['Copenhagen, Denmark', 55.6761, 12.5683],
  ['Helsinki, Finland', 60.1699, 24.9384],
  ['Reykjavik, Iceland', 64.1466, -21.9426],
  ['Warsaw, Poland', 52.2297, 21.0122],
  ['Budapest, Hungary', 47.4979, 19.0402],
  ['New York, USA', 40.7128, -74.006],
  ['Los Angeles, USA', 34.0522, -118.2437],
  ['San Francisco, USA', 37.7749, -122.4194],
  ['San Jose, USA', 37.3382, -121.8863],
  ['Seattle, USA', 47.6062, -122.3321],
  ['Chicago, USA', 41.8781, -87.6298],
  ['Miami, USA', 25.7617, -80.1918],
  ['Orlando, USA', 28.5383, -81.3792],
  ['Las Vegas, USA', 36.1699, -115.1398],
  ['Boston, USA', 42.3601, -71.0589],
  ['Washington, USA', 38.9072, -77.0369],
  ['Austin, USA', 30.2672, -97.7431],
  ['Denver, USA', 39.7392, -104.9903],
  ['Honolulu, USA', 21.3069, -157.8583],
  ['Anchorage, USA', 61.2181, -149.9003],
  ['Toronto, Canada', 43.6532, -79.3832],
  ['Vancouver, Canada', 49.2827, -123.1207],
  ['Montreal, Canada', 45.5017, -73.5673],
  ['Banff, Canada', 51.1784, -115.5708],
  ['Mexico City, Mexico', 19.4326, -99.1332],
  ['Cancun, Mexico', 21.1619, -86.8515],
  ['Rio de Janeiro, Brazil', -22.9068, -43.1729],
  ['Sao Paulo, Brazil', -23.5505, -46.6333],
  ['Buenos Aires, Argentina', -34.6037, -58.3816],
  ['Lima, Peru', -12.0464, -77.0428],
  ['Santiago, Chile', -33.4489, -70.6693],
  ['Bogota, Colombia', 4.711, -74.0721],
];

function isValidYmd(y, m, d) {
  if (y < 1990 || y > 2099 || m < 1 || m > 12 || d < 1 || d > 31) return false;
  const check = new Date(Date.UTC(y, m - 1, d));
  return (
    check.getUTCFullYear() === y &&
    check.getUTCMonth() === m - 1 &&
    check.getUTCDate() === d
  );
}

function formatYmd(y, m, d) {
  return `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

function parseExifDateString(str) {
  const m = String(str || '').match(
    /^(\d{4}):(\d{2}):(\d{2})[T\s](\d{2}):(\d{2}):(\d{2})/
  );
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const hh = Number(m[4]);
  const mm = Number(m[5]);
  const ss = Number(m[6]);
  if (!isValidYmd(y, mo, d) || hh > 23 || mm > 59 || ss > 59) return null;
  const dt = new Date(y, mo - 1, d, hh, mm, ss);
  if (Number.isNaN(dt.getTime())) return null;
  return {
    day: formatYmd(y, mo, d),
    takenAt: dt.toISOString(),
  };
}

function normalizeGpsCoords(rawLat, rawLng) {
  const lat = Number(rawLat);
  const lng = Number(rawLng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  if (Math.abs(lat) < 1e-6 && Math.abs(lng) < 1e-6) return null; // null-island sentinel
  return {
    gpsLat: Math.round(lat * 1e6) / 1e6,
    gpsLng: Math.round(lng * 1e6) / 1e6,
  };
}

function haversineKm(lat1, lng1, lat2, lng2) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function formatCoordLabel(lat, lng) {
  const latDir = lat >= 0 ? 'N' : 'S';
  const lngDir = lng >= 0 ? 'E' : 'W';
  return `${Math.abs(lat).toFixed(2)}°${latDir}, ${Math.abs(lng).toFixed(2)}°${lngDir}`;
}

function reverseGeocodeOffline(rawLat, rawLng) {
  const coords = normalizeGpsCoords(rawLat, rawLng);
  if (!coords) return null;
  let bestCity = null;
  let bestDist = Infinity;
  for (const [name, cLat, cLng] of WORLD_CITIES) {
    const dist = haversineKm(coords.gpsLat, coords.gpsLng, cLat, cLng);
    if (dist < bestDist) {
      bestDist = dist;
      bestCity = name;
    }
  }
  if (bestCity && bestDist <= 95) {
    return bestCity;
  }
  if (bestCity && bestDist <= 260) {
    return `Near ${bestCity}`;
  }
  return formatCoordLabel(coords.gpsLat, coords.gpsLng);
}

/**
 * Parses JPEG APP1 EXIF DateTimeOriginal, Camera Make/Model, and GPS IFD coordinates from a Buffer.
 */
function parseJpegExifFromBuffer(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 16) return null;
  if (buf[0] !== 0xff || buf[1] !== 0xd8) return null;

  let pos = 2;
  while (pos + 4 <= buf.length) {
    while (pos < buf.length && buf[pos] === 0xff && buf[pos + 1] === 0xff) {
      pos += 1;
    }
    if (pos + 4 > buf.length || buf[pos] !== 0xff) break;
    const marker = buf[pos + 1];
    if (marker === 0xda || marker === 0xd9) break; // SOS / EOI
    const segLen = buf.readUInt16BE(pos + 2);
    if (segLen < 2 || pos + 2 + segLen > buf.length) break;

    if (
      marker === 0xe1 &&
      segLen >= 16 &&
      buf.toString('ascii', pos + 4, pos + 10) === 'Exif\0\0'
    ) {
      const tiffStart = pos + 10;
      const endian = buf.toString('ascii', tiffStart, tiffStart + 2);
      if (endian !== 'II' && endian !== 'MM') return null;
      const le = endian === 'II';
      const readU16 = (off) =>
        off + 2 <= buf.length
          ? le
            ? buf.readUInt16LE(off)
            : buf.readUInt16BE(off)
          : 0;
      const readU32 = (off) =>
        off + 4 <= buf.length
          ? le
            ? buf.readUInt32LE(off)
            : buf.readUInt32BE(off)
          : 0;

      if (readU16(tiffStart + 2) !== 0x002a) return null;
      const ifd0Rel = readU32(tiffStart + 4);

      const scanIfd = (ifdRel) => {
        const ifdOff = tiffStart + ifdRel;
        if (ifdOff + 2 > buf.length) return new Map();
        const count = Math.min(readU16(ifdOff), 256);
        const tags = new Map();
        for (let i = 0; i < count; i++) {
          const entryOff = ifdOff + 2 + i * 12;
          if (entryOff + 12 > buf.length) break;
          const tag = readU16(entryOff);
          const type = readU16(entryOff + 2);
          const valCount = readU32(entryOff + 4);
          tags.set(tag, { type, valCount, valueOff: entryOff + 8 });
        }
        return tags;
      };

      const readAsciiTag = (tagEntry, minLen = 1) => {
        if (!tagEntry || tagEntry.type !== 2 || tagEntry.valCount < minLen) return null;
        const byteCount = Math.min(tagEntry.valCount, 64);
        const dataOff =
          tagEntry.valCount <= 4
            ? tagEntry.valueOff
            : tiffStart + readU32(tagEntry.valueOff);
        if (dataOff < tiffStart || dataOff + byteCount > buf.length) return null;
        return buf.toString('ascii', dataOff, dataOff + byteCount).replace(/\0.*$/, '').trim() || null;
      };

      const readRationals = (tagEntry, expectedCount) => {
        if (!tagEntry || (tagEntry.type !== 5 && tagEntry.type !== 10) || tagEntry.valCount < expectedCount) {
          return null;
        }
        const dataOff = tiffStart + readU32(tagEntry.valueOff);
        if (dataOff < tiffStart || dataOff + expectedCount * 8 > buf.length) return null;
        const out = [];
        for (let i = 0; i < expectedCount; i++) {
          const num = readU32(dataOff + i * 8);
          const den = readU32(dataOff + i * 8 + 4);
          if (!den) return null;
          out.push(num / den);
        }
        return out;
      };

      const ifd0 = scanIfd(ifd0Rel);
      const make = readAsciiTag(ifd0.get(0x010f), 2);
      const model = readAsciiTag(ifd0.get(0x0110), 2);
      const cameraModel = model
        ? make && !model.toLowerCase().startsWith(make.toLowerCase())
          ? `${make} ${model}`
          : model
        : make || null;

      let parsedDate = null;
      if (ifd0.has(0x8769)) {
        const exifPtr = readU32(ifd0.get(0x8769).valueOff);
        const exifIfd = scanIfd(exifPtr);
        const rawOrig =
          readAsciiTag(exifIfd.get(0x9003), 19) ||
          readAsciiTag(exifIfd.get(0x9004), 19);
        parsedDate = parseExifDateString(rawOrig);
      }
      if (!parsedDate) {
        parsedDate = parseExifDateString(readAsciiTag(ifd0.get(0x0132), 19));
      }

      let gpsLat = null;
      let gpsLng = null;
      let locationLabel = null;
      if (ifd0.has(0x8825)) {
        const gpsPtr = readU32(ifd0.get(0x8825).valueOff);
        const gpsIfd = scanIfd(gpsPtr);
        const latRef = (readAsciiTag(gpsIfd.get(0x0001), 1) || 'N').toUpperCase();
        const latDms = readRationals(gpsIfd.get(0x0002), 3);
        const lngRef = (readAsciiTag(gpsIfd.get(0x0003), 1) || 'E').toUpperCase();
        const lngDms = readRationals(gpsIfd.get(0x0004), 3);
        if (latDms && lngDms) {
          let lat = latDms[0] + latDms[1] / 60 + latDms[2] / 3600;
          let lng = lngDms[0] + lngDms[1] / 60 + lngDms[2] / 3600;
          if (latRef === 'S') lat = -lat;
          if (lngRef === 'W') lng = -lng;
          const norm = normalizeGpsCoords(lat, lng);
          if (norm) {
            gpsLat = norm.gpsLat;
            gpsLng = norm.gpsLng;
            locationLabel = reverseGeocodeOffline(gpsLat, gpsLng);
          }
        }
      }

      if (parsedDate || cameraModel || gpsLat !== null) {
        return {
          day: parsedDate ? parsedDate.day : null,
          takenAt: parsedDate ? parsedDate.takenAt : null,
          cameraModel,
          gpsLat,
          gpsLng,
          locationLabel,
        };
      }
      return null;
    }

    pos += 2 + segLen;
  }
  return null;
}

async function readJpegExifMetadata(fullPath) {
  const ext = path.extname(String(fullPath || '')).toLowerCase();
  if (!JPEG_EXTS.has(ext)) return null;

  let fh = null;
  try {
    fh = await fsp.open(fullPath, 'r');
    const maxBytes = 65536;
    const rawBuf = Buffer.allocUnsafe(maxBytes);
    const { bytesRead } = await fh.read(rawBuf, 0, maxBytes, 0);
    if (bytesRead < 16) return null;
    return parseJpegExifFromBuffer(rawBuf.subarray(0, bytesRead));
  } catch {
    return null;
  } finally {
    if (fh) {
      await fh.close().catch(() => {});
    }
  }
}

module.exports = {
  parseJpegExifFromBuffer,
  readJpegExifMetadata,
  normalizeGpsCoords,
  reverseGeocodeOffline,
  haversineKm,
};
