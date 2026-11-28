/**
 * EXIF DATE, CAMERA & GPS GEO-TAGGING SERVICE (Zero External Dependencies)
 *
 * Extracts DateTimeOriginal, Camera Make/Model, and GPS latitude/longitude across:
 *   - JPEG / JPG (APP1 Exif, up to 512 KB header scan)
 *   - HEIC / HEIF / AVIF (ISO BMFF meta -> iinf/infe('Exif') -> iloc + fallback Exif scan)
 *   - MOV / MP4 / M4V / 3GP (QuickTime/MP4 moov -> meta keys/ilst ISO6709 & udta ©xyz)
 *   - WebP (RIFF EXIF chunk), PNG (eXIf chunk), TIFF / DNG (raw TIFF header)
 *
 * Detects format by file magic bytes so `.tmp` staging files work cleanly too, and maps
 * coordinates to offline city/country labels without requiring external API keys.
 */

const fsp = require('fs/promises');

const EXIF_SCHEMA_VERSION = 2;

// Curated global offline reverse-geocoding gazetteer: [name, lat, lng]
const WORLD_CITIES = [
  ['Tokyo, Japan', 35.6762, 139.6503],
  ['Yokohama, Japan', 35.4437, 139.638],
  ['Osaka, Japan', 34.6937, 135.5023],
  ['Kyoto, Japan', 35.0116, 135.7681],
  ['Kobe, Japan', 34.6901, 135.1955],
  ['Nara, Japan', 34.6851, 135.8048],
  ['Hiroshima, Japan', 34.3853, 132.4553],
  ['Sapporo, Japan', 43.0618, 141.3545],
  ['Fukuoka, Japan', 33.5902, 130.4017],
  ['Nagoya, Japan', 35.1815, 136.9066],
  ['Sendai, Japan', 38.2682, 140.8694],
  ['Okinawa, Japan', 26.2124, 127.6809],
  ['Seoul, South Korea', 37.5665, 126.978],
  ['Incheon, South Korea', 37.4563, 126.7052],
  ['Busan, South Korea', 35.1796, 129.0756],
  ['Jeju, South Korea', 33.4996, 126.5312],
  ['Taipei, Taiwan', 25.033, 121.5654],
  ['Taichung, Taiwan', 24.1477, 120.6736],
  ['Tainan, Taiwan', 22.9999, 120.2269],
  ['Kaohsiung, Taiwan', 22.6273, 120.3014],
  ['Hualien, Taiwan', 23.9872, 121.6015],
  ['Hong Kong', 22.3193, 114.1694],
  ['Macau', 22.1987, 113.5439],
  ['Beijing, China', 39.9042, 116.4074],
  ['Shanghai, China', 31.2304, 121.4737],
  ['Shenzhen, China', 22.5431, 114.0579],
  ['Guangzhou, China', 23.1291, 113.2644],
  ['Chengdu, China', 30.5728, 104.0668],
  ['Chongqing, China', 29.563, 106.5516],
  ['Hangzhou, China', 30.2741, 120.1551],
  ['Suzhou, China', 31.2989, 120.5853],
  ['Nanjing, China', 32.0603, 118.7969],
  ['Wuhan, China', 30.5928, 114.3055],
  ['Xiamen, China', 24.4798, 118.0894],
  ['Kunming, China', 24.8801, 102.8329],
  ["Xi'an, China", 34.3416, 108.9398],
  ['Singapore', 1.3521, 103.8198],
  ['Kuala Lumpur, Malaysia', 3.139, 101.6869],
  ['Petaling Jaya, Malaysia', 3.1073, 101.6067],
  ['Shah Alam, Malaysia', 3.0733, 101.5185],
  ['Putrajaya, Malaysia', 2.9264, 101.6964],
  ['Seremban, Malaysia', 2.7297, 101.9381],
  ['Penang, Malaysia', 5.4141, 100.3288],
  ['Langkawi, Malaysia', 6.35, 99.8],
  ['Alor Setar, Malaysia', 6.1248, 100.3678],
  ['Ipoh, Malaysia', 4.5975, 101.0901],
  ['Cameron Highlands, Malaysia', 4.4721, 101.3801],
  ['Malacca, Malaysia', 2.1896, 102.2501],
  ['Johor Bahru, Malaysia', 1.4927, 103.7414],
  ['Kuantan, Malaysia', 3.8077, 103.326],
  ['Kota Bharu, Malaysia', 6.1254, 102.2381],
  ['Kuala Terengganu, Malaysia', 5.3117, 103.1324],
  ['Kota Kinabalu, Malaysia', 5.9804, 116.0735],
  ['Sandakan, Malaysia', 5.8402, 118.1179],
  ['Kuching, Malaysia', 1.5533, 110.3592],
  ['Miri, Malaysia', 4.3995, 113.9914],
  ['Sibu, Malaysia', 2.2873, 111.8305],
  ['Bandar Seri Begawan, Brunei', 4.9031, 114.9398],
  ['Bangkok, Thailand', 13.7563, 100.5018],
  ['Chiang Mai, Thailand', 18.7883, 98.9853],
  ['Phuket, Thailand', 7.8804, 98.3923],
  ['Krabi, Thailand', 8.0863, 98.9063],
  ['Pattaya, Thailand', 12.9236, 100.8825],
  ['Hat Yai, Thailand', 7.0086, 100.4747],
  ['Ho Chi Minh City, Vietnam', 10.8231, 106.6297],
  ['Hanoi, Vietnam', 21.0278, 105.8342],
  ['Da Nang, Vietnam', 16.0544, 108.2022],
  ['Phu Quoc, Vietnam', 10.2899, 103.984],
  ['Phnom Penh, Cambodia', 11.5564, 104.9282],
  ['Siem Reap, Cambodia', 13.3633, 103.8564],
  ['Vientiane, Laos', 17.9757, 102.6331],
  ['Yangon, Myanmar', 16.8409, 96.1735],
  ['Jakarta, Indonesia', -6.2088, 106.8456],
  ['Bandung, Indonesia', -6.9175, 107.6191],
  ['Surabaya, Indonesia', -7.2575, 112.7521],
  ['Yogyakarta, Indonesia', -7.7956, 110.3695],
  ['Bali, Indonesia', -8.4095, 115.1889],
  ['Medan, Indonesia', 3.5952, 98.6722],
  ['Batam, Indonesia', 1.0456, 104.0305],
  ['Manila, Philippines', 14.5995, 120.9842],
  ['Cebu, Philippines', 10.3157, 123.8854],
  ['Boracay, Philippines', 11.9674, 121.9248],
  ['Sydney, Australia', -33.8688, 151.2093],
  ['Melbourne, Australia', -37.8136, 144.9631],
  ['Brisbane, Australia', -27.4698, 153.0251],
  ['Gold Coast, Australia', -28.0167, 153.4],
  ['Perth, Australia', -31.9505, 115.8605],
  ['Adelaide, Australia', -34.9285, 138.6007],
  ['Auckland, New Zealand', -36.8485, 174.7633],
  ['Wellington, New Zealand', -41.2865, 174.7762],
  ['Christchurch, New Zealand', -43.5321, 172.6362],
  ['Queenstown, New Zealand', -45.0312, 168.6626],
  ['Mumbai, India', 19.076, 72.8777],
  ['New Delhi, India', 28.6139, 77.209],
  ['Bengaluru, India', 12.9716, 77.5946],
  ['Chennai, India', 13.0827, 80.2707],
  ['Hyderabad, India', 17.385, 78.4867],
  ['Colombo, Sri Lanka', 6.9271, 79.8612],
  ['Kathmandu, Nepal', 27.7172, 85.324],
  ['Dubai, UAE', 25.2048, 55.2708],
  ['Abu Dhabi, UAE', 24.4539, 54.3773],
  ['Doha, Qatar', 25.2854, 51.531],
  ['Riyadh, Saudi Arabia', 24.7136, 46.6753],
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

const ISO_META_CHILD_FOURCCS = new Set([
  'hdlr',
  'pitm',
  'iloc',
  'iinf',
  'idat',
  'iprp',
  'iref',
  'dinf',
  'keys',
  'ilst',
  'free',
  'skip',
]);

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
    /^(\d{4})[:-](\d{2})[:-](\d{2})[T\s](\d{2}):(\d{2}):(\d{2})/
  );
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const hh = Number(m[4]);
  const mm = Number(m[5]);
  const ss = Number(m[6]);
  if (!isValidYmd(y, mo, d) || hh > 23 || mm > 59 || ss > 59) return null;
  const isoStr = String(str || '').trim();
  const parsedIso = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(isoStr) ? new Date(isoStr) : null;
  const dt = parsedIso && !Number.isNaN(parsedIso.getTime()) ? parsedIso : new Date(y, mo - 1, d, hh, mm, ss);
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

function parseIso6709String(raw) {
  if (!raw || typeof raw !== 'string') return null;
  const clean = raw.trim().replace(/\0+$/, '').trim();
  const m = clean.match(/^([+-]\d{1,2}(?:\.\d+)?)([+-]\d{1,3}(?:\.\d+)?)(?:[+-]\d+(?:\.\d+)?)?\/?$/);
  if (!m) return null;
  return normalizeGpsCoords(Number(m[1]), Number(m[2]));
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

function combineCameraMakeModel(make, model) {
  const cleanMake = make ? String(make).trim() : '';
  const cleanModel = model ? String(model).trim() : '';
  if (cleanModel) {
    if (cleanMake && !cleanModel.toLowerCase().startsWith(cleanMake.toLowerCase())) {
      return `${cleanMake} ${cleanModel}`;
    }
    return cleanModel;
  }
  return cleanMake || null;
}

/**
 * Parses a raw TIFF/EXIF header starting at `tiffStart` inside `buf`.
 * Used by JPEG APP1, HEIC/HEIF Exif items, WebP EXIF chunks, PNG eXIf chunks, and TIFF/DNG files.
 */
function parseTiffExifFromBuffer(buf, tiffStart = 0, limitEnd = buf.length) {
  if (!Buffer.isBuffer(buf) || tiffStart < 0 || tiffStart + 8 > limitEnd || limitEnd > buf.length) {
    return null;
  }
  const endian = buf.toString('ascii', tiffStart, tiffStart + 2);
  if (endian !== 'II' && endian !== 'MM') return null;
  const le = endian === 'II';

  const readU16 = (off) =>
    off >= tiffStart && off + 2 <= limitEnd
      ? le
        ? buf.readUInt16LE(off)
        : buf.readUInt16BE(off)
      : 0;
  const readU32 = (off) =>
    off >= tiffStart && off + 4 <= limitEnd
      ? le
        ? buf.readUInt32LE(off)
        : buf.readUInt32BE(off)
      : 0;
  const readI32 = (off) =>
    off >= tiffStart && off + 4 <= limitEnd
      ? le
        ? buf.readInt32LE(off)
        : buf.readInt32BE(off)
      : 0;

  if (readU16(tiffStart + 2) !== 0x002a) return null;
  const ifd0Rel = readU32(tiffStart + 4);

  const scanIfd = (ifdRel) => {
    const ifdOff = tiffStart + ifdRel;
    if (ifdOff < tiffStart || ifdOff + 2 > limitEnd) return new Map();
    const count = Math.min(readU16(ifdOff), 256);
    const tags = new Map();
    for (let i = 0; i < count; i++) {
      const entryOff = ifdOff + 2 + i * 12;
      if (entryOff + 12 > limitEnd) break;
      const tag = readU16(entryOff);
      const type = readU16(entryOff + 2);
      const valCount = readU32(entryOff + 4);
      tags.set(tag, { type, valCount, valueOff: entryOff + 8 });
    }
    return tags;
  };

  const readAsciiTag = (tagEntry, minLen = 1) => {
    if (!tagEntry || tagEntry.type !== 2 || tagEntry.valCount < minLen) return null;
    const byteCount = Math.min(tagEntry.valCount, 96);
    const dataOff =
      tagEntry.valCount <= 4
        ? tagEntry.valueOff
        : tiffStart + readU32(tagEntry.valueOff);
    if (dataOff < tiffStart || dataOff + byteCount > limitEnd) return null;
    return buf.toString('ascii', dataOff, dataOff + byteCount).replace(/\0.*$/, '').trim() || null;
  };

  const readRationals = (tagEntry, expectedCount) => {
    if (!tagEntry || (tagEntry.type !== 5 && tagEntry.type !== 10) || tagEntry.valCount < expectedCount) {
      return null;
    }
    const dataOff = tiffStart + readU32(tagEntry.valueOff);
    if (dataOff < tiffStart || dataOff + expectedCount * 8 > limitEnd) return null;
    const signed = tagEntry.type === 10;
    const out = [];
    for (let i = 0; i < expectedCount; i++) {
      const num = signed ? readI32(dataOff + i * 8) : readU32(dataOff + i * 8);
      const den = signed ? readI32(dataOff + i * 8 + 4) : readU32(dataOff + i * 8 + 4);
      if (!den) return null;
      out.push(num / den);
    }
    return out;
  };

  const ifd0 = scanIfd(ifd0Rel);
  const make = readAsciiTag(ifd0.get(0x010f), 2);
  const model = readAsciiTag(ifd0.get(0x0110), 2);
  const cameraModel = combineCameraMakeModel(make, model);

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
    const latRefRaw = (readAsciiTag(gpsIfd.get(0x0001), 1) || 'N').trim().toUpperCase();
    const latRef = latRefRaw.charAt(0) || 'N';
    const latDms = readRationals(gpsIfd.get(0x0002), 3);
    const lngRefRaw = (readAsciiTag(gpsIfd.get(0x0003), 1) || 'E').trim().toUpperCase();
    const lngRef = lngRefRaw.charAt(0) || 'E';
    const lngDms = readRationals(gpsIfd.get(0x0004), 3);
    if (latDms && lngDms) {
      let lat = Math.abs(latDms[0]) + Math.abs(latDms[1]) / 60 + Math.abs(latDms[2]) / 3600;
      let lng = Math.abs(lngDms[0]) + Math.abs(lngDms[1]) / 60 + Math.abs(lngDms[2]) / 3600;
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

/**
 * Parses an Exif payload block (may start with 4-byte HEIC offset, "Exif\0\0", or raw TIFF header).
 */
function parseExifPayloadBuffer(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 8) return null;

  // 1. Direct TIFF header
  const first2 = buf.toString('ascii', 0, 2);
  if (first2 === 'II' || first2 === 'MM') {
    const res = parseTiffExifFromBuffer(buf, 0, buf.length);
    if (res) return res;
  }

  // 2. "Exif\0\0" + TIFF header
  if (buf.length >= 14 && buf.toString('ascii', 0, 6) === 'Exif\0\0') {
    const res = parseTiffExifFromBuffer(buf, 6, buf.length);
    if (res) return res;
  }

  // 3. ISO/IEC 23008-12 HEIF Exif item: 4-byte big-endian tiff_header_offset relative to byte 4
  if (buf.length >= 12) {
    const tiffOffset = buf.readUInt32BE(0);
    const candidateStart = 4 + tiffOffset;
    if (candidateStart >= 4 && candidateStart + 8 <= buf.length) {
      const res = parseTiffExifFromBuffer(buf, candidateStart, buf.length);
      if (res) return res;
    }
  }

  // 4. Fallback scan for "Exif\0\0" inside payload
  const markerIdx = buf.indexOf(Buffer.from([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]));
  if (markerIdx !== -1 && markerIdx + 14 <= buf.length) {
    const res = parseTiffExifFromBuffer(buf, markerIdx + 6, buf.length);
    if (res) return res;
  }

  return null;
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
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      pos += 2;
      continue;
    }
    const segLen = buf.readUInt16BE(pos + 2);
    if (segLen < 2 || pos + 2 + segLen > buf.length) break;

    if (
      marker === 0xe1 &&
      segLen >= 16 &&
      buf.toString('ascii', pos + 4, pos + 10) === 'Exif\0\0'
    ) {
      const res = parseTiffExifFromBuffer(buf, pos + 10, pos + 2 + segLen);
      if (res) return res;
    }

    pos += 2 + segLen;
  }
  return null;
}

/**
 * Parses PNG eXIf chunk from a Buffer.
 */
function parsePngExifFromBuffer(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 24) return null;
  if (buf[0] !== 0x89 || buf[1] !== 0x50 || buf[2] !== 0x4e || buf[3] !== 0x47) return null;
  let pos = 8;
  while (pos + 12 <= buf.length) {
    const chunkLen = buf.readUInt32BE(pos);
    const type = buf.toString('ascii', pos + 4, pos + 8);
    const dataStart = pos + 8;
    const dataEnd = dataStart + chunkLen;
    if (dataEnd > buf.length) break;
    if (type === 'eXIf') {
      const res = parseExifPayloadBuffer(buf.subarray(dataStart, dataEnd));
      if (res) return res;
    }
    if (type === 'IEND') break;
    pos = dataEnd + 4; // skip 4-byte CRC
  }
  return null;
}

/**
 * Parses WebP RIFF EXIF chunk from a Buffer.
 */
function parseWebpExifFromBuffer(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 20) return null;
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WEBP') {
    return null;
  }
  let pos = 12;
  while (pos + 8 <= buf.length) {
    const fourcc = buf.toString('ascii', pos, pos + 4);
    const size = buf.readUInt32LE(pos + 4);
    const dataStart = pos + 8;
    const dataEnd = Math.min(buf.length, dataStart + size);
    if (fourcc === 'EXIF' && dataEnd > dataStart) {
      const res = parseExifPayloadBuffer(buf.subarray(dataStart, dataEnd));
      if (res) return res;
    }
    pos = dataStart + size + (size % 2);
  }
  return null;
}

// ==================== ISO BMFF (HEIC / HEIF / AVIF / MOV / MP4) ====================

function readUIntBEVar(buf, offset, byteCount) {
  if (byteCount === 0) return 0;
  if (offset + byteCount > buf.length) return -1;
  if (byteCount === 1) return buf.readUInt8(offset);
  if (byteCount === 2) return buf.readUInt16BE(offset);
  if (byteCount === 4) return buf.readUInt32BE(offset);
  if (byteCount === 8) {
    const hi = buf.readUInt32BE(offset);
    const lo = buf.readUInt32BE(offset + 4);
    return hi * 4294967296 + lo;
  }
  let val = 0;
  for (let i = 0; i < byteCount; i++) {
    val = val * 256 + buf[offset + i];
  }
  return val;
}

function readBoxHeaderFromBuffer(buf, pos, end) {
  if (pos + 8 > end) return null;
  const size32 = buf.readUInt32BE(pos);
  const type = buf.toString('ascii', pos + 4, pos + 8);
  let size = size32;
  let headerSize = 8;
  if (size32 === 1) {
    if (pos + 16 > end) return null;
    const hi = buf.readUInt32BE(pos + 8);
    const lo = buf.readUInt32BE(pos + 12);
    size = hi * 4294967296 + lo;
    headerSize = 16;
  } else if (size32 === 0) {
    size = end - pos;
  }
  if (size < headerSize || pos + size > end) return null;
  return { type, start: pos, dataStart: pos + headerSize, end: pos + size, size };
}

/**
 * Determines where child boxes begin inside a `meta` box (ISO BMFF FullBox has 4-byte
 * version/flags; QuickTime `moov -> meta` sometimes omits them).
 */
function resolveMetaChildrenStart(buf, dataStart, end) {
  if (dataStart + 12 <= end) {
    const afterFull = buf.toString('ascii', dataStart + 8, dataStart + 12);
    if (ISO_META_CHILD_FOURCCS.has(afterFull)) {
      return dataStart + 4;
    }
  }
  if (dataStart + 8 <= end) {
    const direct = buf.toString('ascii', dataStart + 4, dataStart + 8);
    if (ISO_META_CHILD_FOURCCS.has(direct)) {
      return dataStart;
    }
  }
  return dataStart + 4;
}

/**
 * Parses a HEIC/HEIF/AVIF `meta` box to locate Exif item extents (file offset + length).
 */
function parseHeifMetaExifExtents(metaBuf, metaDataStart, metaEnd, metaFileBaseOffset = 0) {
  const childStart = resolveMetaChildrenStart(metaBuf, metaDataStart, metaEnd);
  const exifItemIds = new Set();
  let idatDataFileOffset = -1;
  let ilocBox = null;

  let pos = childStart;
  while (pos + 8 <= metaEnd) {
    const box = readBoxHeaderFromBuffer(metaBuf, pos, metaEnd);
    if (!box) break;
    if (box.type === 'iinf') {
      const version = metaBuf[box.dataStart];
      let p = box.dataStart + 4;
      const entryCount =
        version === 0
          ? p + 2 <= box.end
            ? metaBuf.readUInt16BE(p)
            : 0
          : p + 4 <= box.end
            ? metaBuf.readUInt32BE(p)
            : 0;
      p += version === 0 ? 2 : 4;
      for (let i = 0; i < entryCount && p + 8 <= box.end; i++) {
        const infe = readBoxHeaderFromBuffer(metaBuf, p, box.end);
        if (!infe) break;
        if (infe.type === 'infe' && infe.dataStart + 4 <= infe.end) {
          const iv = metaBuf[infe.dataStart];
          if (iv === 2 && infe.dataStart + 12 <= infe.end) {
            const itemId = metaBuf.readUInt16BE(infe.dataStart + 4);
            const itemType = metaBuf.toString('ascii', infe.dataStart + 8, infe.dataStart + 12);
            if (itemType === 'Exif') exifItemIds.add(itemId);
          } else if (iv === 3 && infe.dataStart + 14 <= infe.end) {
            const itemId = metaBuf.readUInt32BE(infe.dataStart + 4);
            const itemType = metaBuf.toString('ascii', infe.dataStart + 10, infe.dataStart + 14);
            if (itemType === 'Exif') exifItemIds.add(itemId);
          }
        }
        p = infe.end;
      }
    } else if (box.type === 'idat') {
      idatDataFileOffset = metaFileBaseOffset + box.dataStart;
    } else if (box.type === 'iloc') {
      ilocBox = box;
    }
    pos = box.end;
  }

  if (!ilocBox || exifItemIds.size === 0 || ilocBox.dataStart + 8 > ilocBox.end) {
    return [];
  }

  const version = metaBuf[ilocBox.dataStart];
  const b0 = metaBuf[ilocBox.dataStart + 4];
  const b1 = metaBuf[ilocBox.dataStart + 5];
  const offsetSize = (b0 >> 4) & 0x0f;
  const lengthSize = b0 & 0x0f;
  const baseOffsetSize = (b1 >> 4) & 0x0f;
  const indexSize = version === 1 || version === 2 ? b1 & 0x0f : 0;

  let p = ilocBox.dataStart + 6;
  const itemCount =
    version < 2
      ? p + 2 <= ilocBox.end
        ? metaBuf.readUInt16BE(p)
        : 0
      : p + 4 <= ilocBox.end
        ? metaBuf.readUInt32BE(p)
        : 0;
  p += version < 2 ? 2 : 4;

  const extents = [];
  for (let i = 0; i < itemCount && p < ilocBox.end; i++) {
    const itemId = version < 2 ? readUIntBEVar(metaBuf, p, 2) : readUIntBEVar(metaBuf, p, 4);
    p += version < 2 ? 2 : 4;
    if (itemId < 0) break;

    let constructionMethod = 0;
    if (version === 1 || version === 2) {
      const cm = readUIntBEVar(metaBuf, p, 2);
      if (cm < 0) break;
      constructionMethod = cm & 0x0f;
      p += 2;
    }
    const dataRefIdx = readUIntBEVar(metaBuf, p, 2);
    p += 2;
    const baseOffset = readUIntBEVar(metaBuf, p, baseOffsetSize);
    p += baseOffsetSize;
    const extentCount = readUIntBEVar(metaBuf, p, 2);
    p += 2;
    if (dataRefIdx < 0 || baseOffset < 0 || extentCount < 0) break;

    const isExif = exifItemIds.has(itemId) && dataRefIdx === 0 && (constructionMethod === 0 || constructionMethod === 1);
    for (let e = 0; e < extentCount && p < ilocBox.end; e++) {
      if ((version === 1 || version === 2) && indexSize > 0) {
        p += indexSize;
      }
      const extOff = readUIntBEVar(metaBuf, p, offsetSize);
      p += offsetSize;
      const extLen = readUIntBEVar(metaBuf, p, lengthSize);
      p += lengthSize;
      if (extOff < 0 || extLen < 0) break;
      if (isExif && extLen > 8 && extLen <= 512 * 1024) {
        const fileOffset =
          (constructionMethod === 1 ? (idatDataFileOffset >= 0 ? idatDataFileOffset : 0) : 0) +
          baseOffset +
          extOff;
        if (constructionMethod === 0 || idatDataFileOffset >= 0) {
          extents.push({ offset: fileOffset, length: extLen });
        }
      }
    }
  }
  return extents;
}

/**
 * Extracts GPS, camera make/model, and creation date from QuickTime/MP4 `meta` or `udta` box buffers.
 */
function parseQuickTimeMetaOrUdtaBuffer(buf, start, end) {
  let coords = null;
  let make = null;
  let model = null;
  let parsedDate = null;

  const parseMetaBox = (mStart, mEnd) => {
    const cStart = resolveMetaChildrenStart(buf, mStart, mEnd);
    const keyList = []; // 1-indexed via keyList[idx - 1]
    let ilstBox = null;

    let pos = cStart;
    while (pos + 8 <= mEnd) {
      const box = readBoxHeaderFromBuffer(buf, pos, mEnd);
      if (!box) break;
      if (box.type === 'keys' && box.dataStart + 8 <= box.end) {
        const entryCount = Math.min(buf.readUInt32BE(box.dataStart + 4), 256);
        let kp = box.dataStart + 8;
        for (let i = 0; i < entryCount && kp + 8 <= box.end; i++) {
          const kSize = buf.readUInt32BE(kp);
          if (kSize < 8 || kp + kSize > box.end) break;
          const kName = buf.toString('utf8', kp + 8, kp + kSize).replace(/\0+$/, '');
          keyList.push(kName);
          kp += kSize;
        }
      } else if (box.type === 'ilst') {
        ilstBox = box;
      }
      pos = box.end;
    }

    if (ilstBox) {
      let ip = ilstBox.dataStart;
      while (ip + 8 <= ilstBox.end) {
        const item = readBoxHeaderFromBuffer(buf, ip, ilstBox.end);
        if (!item) break;
        const keyIndex = buf.readUInt32BE(item.start + 4);
        const keyName =
          keyIndex >= 1 && keyIndex <= keyList.length
            ? keyList[keyIndex - 1]
            : item.type;

        // Read `data` atom payload inside item
        let dp = item.dataStart;
        while (dp + 8 <= item.end) {
          const dBox = readBoxHeaderFromBuffer(buf, dp, item.end);
          if (!dBox) break;
          if (dBox.type === 'data' && dBox.dataStart + 8 < dBox.end) {
            const textVal = buf
              .toString('utf8', dBox.dataStart + 8, dBox.end)
              .replace(/\0+$/, '')
              .trim();
            if (textVal) {
              const lowerKey = String(keyName || '').toLowerCase();
              if (
                lowerKey === 'com.apple.quicktime.location.iso6709' ||
                lowerKey === '\u00a9xyz' ||
                (item.start + 8 <= item.end &&
                  buf[item.start + 4] === 0xa9 &&
                  buf[item.start + 5] === 0x78 &&
                  buf[item.start + 6] === 0x79 &&
                  buf[item.start + 7] === 0x7a)
              ) {
                const c = parseIso6709String(textVal);
                if (c && !coords) coords = c;
              } else if (lowerKey === 'com.apple.quicktime.make') {
                make = textVal;
              } else if (lowerKey === 'com.apple.quicktime.model') {
                model = textVal;
              } else if (lowerKey === 'com.apple.quicktime.creationdate') {
                const d = parseExifDateString(textVal);
                if (d && !parsedDate) parsedDate = d;
              }
            }
          }
          dp = dBox.end;
        }
        ip = item.end;
      }
    }
  };

  // Walk child boxes of udta or meta
  let pos = start;
  while (pos + 8 <= end) {
    const box = readBoxHeaderFromBuffer(buf, pos, end);
    if (!box) break;
    // QuickTime `©xyz` atom (bytes: 0xA9 'x' 'y' 'z')
    if (
      buf[box.start + 4] === 0xa9 &&
      buf[box.start + 5] === 0x78 &&
      buf[box.start + 6] === 0x79 &&
      buf[box.start + 7] === 0x7a
    ) {
      if (box.dataStart + 4 < box.end) {
        // Classic QuickTime international text atom: [2-byte strLen][2-byte lang][UTF-8 text]
        const strLen = buf.readUInt16BE(box.dataStart);
        let text = '';
        if (strLen > 0 && box.dataStart + 4 + strLen <= box.end) {
          text = buf.toString('utf8', box.dataStart + 4, box.dataStart + 4 + strLen);
        } else {
          text = buf.toString('utf8', box.dataStart, box.end);
        }
        const m = text.match(/([+-]\d{1,2}(?:\.\d+)?[+-]\d{1,3}(?:\.\d+)?(?:[+-]\d+(?:\.\d+)?)?\/?)/);
        if (m) {
          const c = parseIso6709String(m[1]);
          if (c && !coords) coords = c;
        }
      }
    } else if (box.type === 'meta') {
      parseMetaBox(box.dataStart, box.end);
    } else if (box.type === 'udta') {
      const nested = parseQuickTimeMetaOrUdtaBuffer(buf, box.dataStart, box.end);
      if (nested) {
        if (!coords && typeof nested.gpsLat === 'number') {
          coords = { gpsLat: nested.gpsLat, gpsLng: nested.gpsLng };
        }
        if (!model && nested.cameraModel) model = nested.cameraModel;
        if (!parsedDate && nested.day) parsedDate = { day: nested.day, takenAt: nested.takenAt };
      }
    }
    pos = box.end;
  }

  // Also handle the case where `buf[start..end]` IS directly a `meta` box payload
  if (!coords && !model && !parsedDate) {
    parseMetaBox(start, end);
  }

  const cameraModel = combineCameraMakeModel(make, model);
  if (coords || cameraModel || parsedDate) {
    return {
      day: parsedDate ? parsedDate.day : null,
      takenAt: parsedDate ? parsedDate.takenAt : null,
      cameraModel,
      gpsLat: coords ? coords.gpsLat : null,
      gpsLng: coords ? coords.gpsLng : null,
      locationLabel: coords ? reverseGeocodeOffline(coords.gpsLat, coords.gpsLng) : null,
    };
  }
  return null;
}

/**
 * Parses an ISO BMFF buffer (HEIC/HEIF/AVIF or small MP4/MOV already in RAM).
 */
function parseIsoBmffExifFromBuffer(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 16) return null;
  if (buf.toString('ascii', 4, 8) !== 'ftyp') return null;

  let pos = 0;
  let fallbackResult = null;
  while (pos + 8 <= buf.length) {
    const box = readBoxHeaderFromBuffer(buf, pos, buf.length);
    if (!box) break;
    if (box.type === 'meta') {
      const extents = parseHeifMetaExifExtents(buf, box.dataStart, box.end, 0);
      for (const ext of extents) {
        if (ext.offset + ext.length <= buf.length) {
          const exifRes = parseExifPayloadBuffer(buf.subarray(ext.offset, ext.offset + ext.length));
          if (exifRes && typeof exifRes.gpsLat === 'number') return exifRes;
          if (exifRes && !fallbackResult) fallbackResult = exifRes;
        }
      }
    } else if (box.type === 'moov') {
      const qtRes = parseQuickTimeMetaOrUdtaBuffer(buf, box.dataStart, box.end);
      if (qtRes && typeof qtRes.gpsLat === 'number') return qtRes;
      if (qtRes && !fallbackResult) fallbackResult = qtRes;
    }
    pos = box.end;
  }

  if (fallbackResult) return fallbackResult;

  // Fallback scan for embedded Exif\0\0 inside HEIC buffer
  const marker = Buffer.from([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]);
  let idx = buf.indexOf(marker);
  while (idx !== -1 && idx + 14 <= buf.length) {
    const res = parseTiffExifFromBuffer(buf, idx + 6, Math.min(buf.length, idx + 6 + 65536));
    if (res) return res;
    idx = buf.indexOf(marker, idx + 6);
  }
  return null;
}

/**
 * Universal in-memory EXIF/GPS parser dispatching by file magic bytes.
 */
function parseMediaExifFromBuffer(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 12) return null;
  if (buf[0] === 0xff && buf[1] === 0xd8) {
    return parseJpegExifFromBuffer(buf);
  }
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
    return parsePngExifFromBuffer(buf);
  }
  if (buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') {
    return parseWebpExifFromBuffer(buf);
  }
  const first2 = buf.toString('ascii', 0, 2);
  if ((first2 === 'II' || first2 === 'MM') && (buf[2] === 0x2a || buf[3] === 0x2a)) {
    return parseTiffExifFromBuffer(buf, 0, buf.length);
  }
  if (buf.toString('ascii', 4, 8) === 'ftyp') {
    return parseIsoBmffExifFromBuffer(buf);
  }
  return null;
}

async function readBoxHeaderFromFile(fh, filePos, fileSize) {
  if (filePos + 8 > fileSize) return null;
  const hdr = Buffer.allocUnsafe(16);
  const toRead = Math.min(16, fileSize - filePos);
  const { bytesRead } = await fh.read(hdr, 0, toRead, filePos);
  if (bytesRead < 8) return null;

  const size32 = hdr.readUInt32BE(0);
  const type = hdr.toString('ascii', 4, 8);
  let size = size32;
  let headerSize = 8;
  if (size32 === 1) {
    if (bytesRead < 16) return null;
    const hi = hdr.readUInt32BE(8);
    const lo = hdr.readUInt32BE(12);
    size = hi * 4294967296 + lo;
    headerSize = 16;
  } else if (size32 === 0) {
    size = fileSize - filePos;
  }
  if (!Number.isFinite(size) || size < headerSize || filePos + size > fileSize) {
    return null;
  }
  return { type, start: filePos, dataStart: filePos + headerSize, end: filePos + size, size };
}

async function readSliceFromFile(fh, offset, length) {
  if (length <= 0) return Buffer.alloc(0);
  const buf = Buffer.allocUnsafe(length);
  const { bytesRead } = await fh.read(buf, 0, length, offset);
  return buf.subarray(0, bytesRead);
}

/**
 * Walks an ISO BMFF file on disk (HEIC/HEIF/AVIF/MOV/MP4/M4V/3GP) via O(boxes) seeks,
 * skipping multi-GB `mdat` payloads so 4K videos and HEIC photos parse in < 2 ms.
 */
async function readIsoBmffExifFromFile(fh, fileSize) {
  let filePos = 0;
  let boxCount = 0;
  let bestFallback = null;

  while (filePos + 8 <= fileSize && boxCount < 128) {
    boxCount += 1;
    const box = await readBoxHeaderFromFile(fh, filePos, fileSize);
    if (!box) break;

    if (box.type === 'meta') {
      const metaSize = Math.min(box.size, 2 * 1024 * 1024);
      const metaBuf = await readSliceFromFile(fh, box.start, metaSize);
      const metaHeaderSize = box.dataStart - box.start;
      const extents = parseHeifMetaExifExtents(metaBuf, metaHeaderSize, metaBuf.length, box.start);
      for (const ext of extents) {
        if (ext.offset >= 0 && ext.offset + ext.length <= fileSize) {
          const exifBuf = await readSliceFromFile(fh, ext.offset, Math.min(ext.length, 512 * 1024));
          const res = parseExifPayloadBuffer(exifBuf);
          if (res && typeof res.gpsLat === 'number') return res;
          if (res && !bestFallback) bestFallback = res;
        }
      }
    } else if (box.type === 'moov') {
      // Walk direct children of `moov` without loading large `trak` sample tables into RAM
      let mp = box.dataStart;
      let childCount = 0;
      while (mp + 8 <= box.end && childCount < 64) {
        childCount += 1;
        const child = await readBoxHeaderFromFile(fh, mp, box.end);
        if (!child) break;
        if ((child.type === 'meta' || child.type === 'udta') && child.size <= 2 * 1024 * 1024) {
          const childBuf = await readSliceFromFile(fh, child.start, child.size);
          const res = parseQuickTimeMetaOrUdtaBuffer(childBuf, 0, childBuf.length);
          if (res && typeof res.gpsLat === 'number') return res;
          if (res && !bestFallback) bestFallback = res;
        }
        mp = child.end;
      }
    }

    filePos = box.end;
  }

  if (bestFallback) return bestFallback;

  // Fallback scan of the first 256 KB for HEIC files with non-standard Exif placement
  const headLen = Math.min(fileSize, 256 * 1024);
  const headBuf = await readSliceFromFile(fh, 0, headLen);
  const marker = Buffer.from([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]);
  const idx = headBuf.indexOf(marker);
  if (idx !== -1 && idx + 14 <= headBuf.length) {
    return parseTiffExifFromBuffer(headBuf, idx + 6, Math.min(headBuf.length, idx + 6 + 65536));
  }
  return null;
}

/**
 * Walks PNG chunks on disk to locate `eXIf` even when it appears after `IDAT`.
 */
async function readPngExifFromFile(fh, fileSize) {
  let pos = 8;
  let chunks = 0;
  const hdr = Buffer.allocUnsafe(8);
  while (pos + 12 <= fileSize && chunks < 256) {
    chunks += 1;
    const { bytesRead } = await fh.read(hdr, 0, 8, pos);
    if (bytesRead < 8) break;
    const len = hdr.readUInt32BE(0);
    const type = hdr.toString('ascii', 4, 8);
    const dataStart = pos + 8;
    const nextPos = dataStart + len + 4;
    if (nextPos > fileSize) break;
    if (type === 'eXIf' && len >= 8 && len <= 512 * 1024) {
      const payload = await readSliceFromFile(fh, dataStart, len);
      const res = parseExifPayloadBuffer(payload);
      if (res) return res;
    }
    if (type === 'IEND') break;
    pos = nextPos;
  }
  return null;
}

/**
 * Walks WebP RIFF chunks on disk to locate `EXIF`.
 */
async function readWebpExifFromFile(fh, fileSize) {
  let pos = 12;
  let chunks = 0;
  const hdr = Buffer.allocUnsafe(8);
  while (pos + 8 <= fileSize && chunks < 128) {
    chunks += 1;
    const { bytesRead } = await fh.read(hdr, 0, 8, pos);
    if (bytesRead < 8) break;
    const fourcc = hdr.toString('ascii', 0, 4);
    const size = hdr.readUInt32LE(4);
    const dataStart = pos + 8;
    if (dataStart + size > fileSize) break;
    if (fourcc === 'EXIF' && size >= 8 && size <= 512 * 1024) {
      const payload = await readSliceFromFile(fh, dataStart, size);
      const res = parseExifPayloadBuffer(payload);
      if (res) return res;
    }
    pos = dataStart + size + (size % 2);
  }
  return null;
}

/**
 * Universal file-based EXIF/GPS metadata reader.
 * Detects file format via magic bytes (so `.tmp` staging files work cleanly too!).
 */
async function readMediaExifMetadata(fullPath) {
  if (!fullPath || typeof fullPath !== 'string') return null;

  let fh = null;
  try {
    fh = await fsp.open(fullPath, 'r');
    const stat = await fh.stat();
    const fileSize = stat.size;
    if (fileSize < 16) return null;

    const probe = await readSliceFromFile(fh, 0, Math.min(32, fileSize));
    if (probe.length < 12) return null;

    // 1. JPEG
    if (probe[0] === 0xff && probe[1] === 0xd8) {
      const buf = await readSliceFromFile(fh, 0, Math.min(fileSize, 512 * 1024));
      return parseJpegExifFromBuffer(buf);
    }

    // 2. ISO BMFF: HEIC / HEIF / AVIF / MOV / MP4 / M4V / 3GP
    if (probe.toString('ascii', 4, 8) === 'ftyp') {
      return await readIsoBmffExifFromFile(fh, fileSize);
    }

    // 3. QuickTime `.mov` that starts directly with `wide`/`mdat`/`moov`/`free` (no `ftyp`)
    const top4 = probe.toString('ascii', 4, 8);
    if (top4 === 'moov' || top4 === 'mdat' || top4 === 'wide' || top4 === 'free' || top4 === 'skip') {
      return await readIsoBmffExifFromFile(fh, fileSize);
    }

    // 4. PNG
    if (probe[0] === 0x89 && probe[1] === 0x50 && probe[2] === 0x4e && probe[3] === 0x47) {
      return await readPngExifFromFile(fh, fileSize);
    }

    // 5. WebP
    if (probe.toString('ascii', 0, 4) === 'RIFF' && probe.toString('ascii', 8, 12) === 'WEBP') {
      return await readWebpExifFromFile(fh, fileSize);
    }

    // 6. TIFF / DNG
    const first2 = probe.toString('ascii', 0, 2);
    if ((first2 === 'II' || first2 === 'MM') && (probe[2] === 0x2a || probe[3] === 0x2a)) {
      const buf = await readSliceFromFile(fh, 0, Math.min(fileSize, 256 * 1024));
      return parseTiffExifFromBuffer(buf, 0, buf.length);
    }

    return null;
  } catch {
    return null;
  } finally {
    if (fh) {
      await fh.close().catch(() => {});
    }
  }
}

// Backward-compatible alias
async function readJpegExifMetadata(fullPath) {
  return readMediaExifMetadata(fullPath);
}

module.exports = {
  EXIF_SCHEMA_VERSION,
  parseTiffExifFromBuffer,
  parseJpegExifFromBuffer,
  parseMediaExifFromBuffer,
  readMediaExifMetadata,
  readJpegExifMetadata,
  normalizeGpsCoords,
  parseIso6709String,
  reverseGeocodeOffline,
  haversineKm,
};
