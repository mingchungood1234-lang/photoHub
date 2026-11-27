/**
 * MEMORIES CURATION ENGINE ("On This Day", Trips, Favorites & Recent Highlights)
 *
 * Computes personal memory reels dynamically from a user's `HashIndex` timeline without
 * duplicating files on disk. Supports an optional `referenceDate` (`YYYY-MM-DD`) so results
 * align cleanly with the user's local calendar date.
 */

const { isVideoFilename } = require('./proxyService');

const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

function parseYmdParts(photo) {
  const raw = String(
    photo.photoDate || (photo.takenAt || '').slice(0, 10) || (photo.uploadedAt || '').slice(0, 10)
  );
  const m = raw.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return null;
  return {
    year: Number(m[1]),
    month: Number(m[2]),
    day: Number(m[3]),
    ymd: `${m[1]}-${m[2]}-${m[3]}`,
  };
}

function dayOfYear(month, day) {
  const dt = new Date(Date.UTC(2024, month - 1, day)); // leap-year neutral calendar index
  const start = new Date(Date.UTC(2024, 0, 1));
  return Math.round((dt - start) / 86400000);
}

function circularDayDiff(doyA, doyB) {
  const raw = Math.abs(doyA - doyB);
  return Math.min(raw, 366 - raw);
}

function pickCoverPhoto(items) {
  // Prefer a favorite photo, then any non-video photo with a preview, else first item
  return (
    items.find((p) => p.isFavorite && !isVideoFilename(p.originalName || p.savedPath || '')) ||
    items.find((p) => !isVideoFilename(p.originalName || p.savedPath || '')) ||
    items[0] ||
    null
  );
}

function buildMemories(allPhotos, { referenceDate = null, maxMemories = 12 } = {}) {
  const photos = Array.isArray(allPhotos) ? allPhotos : [];
  if (photos.length === 0) return [];

  let refYear;
  let refMonth;
  let refDay;
  if (referenceDate && /^\d{4}-\d{2}-\d{2}$/.test(String(referenceDate).trim())) {
    const parts = String(referenceDate).trim().split('-').map(Number);
    refYear = parts[0];
    refMonth = parts[1];
    refDay = parts[2];
  } else {
    const now = new Date();
    refYear = now.getFullYear();
    refMonth = now.getMonth() + 1;
    refDay = now.getDate();
  }
  const refDoy = dayOfYear(refMonth, refDay);
  const refMs = Date.UTC(refYear, refMonth - 1, refDay);

  const memories = [];
  const usedIds = new Set();

  const pushMemory = (mem) => {
    if (!mem || !Array.isArray(mem.photos) || mem.photos.length === 0) return;
    if (usedIds.has(mem.id)) return;
    usedIds.add(mem.id);
    const limited = mem.photos.slice(0, 40);
    const cover = pickCoverPhoto(limited);
    memories.push({
      id: mem.id,
      type: mem.type,
      badge: mem.badge,
      title: mem.title,
      subtitle: mem.subtitle,
      coverHash: cover ? cover.hash : limited[0].hash,
      itemCount: limited.length,
      hashes: limited.map((p) => p.hash),
      photos: limited,
    });
  };

  // 1. "On This Day" memories across previous years (exact day preferred, fallback ±3 days window)
  const byPastYearExact = new Map();
  const byPastYearNear = new Map();
  for (const p of photos) {
    const parts = parseYmdParts(p);
    if (!parts || parts.year >= refYear) continue;
    const diff = circularDayDiff(dayOfYear(parts.month, parts.day), refDoy);
    if (diff === 0) {
      if (!byPastYearExact.has(parts.year)) byPastYearExact.set(parts.year, []);
      byPastYearExact.get(parts.year).push(p);
    } else if (diff <= 3) {
      if (!byPastYearNear.has(parts.year)) byPastYearNear.set(parts.year, []);
      byPastYearNear.get(parts.year).push(p);
    }
  }

  const pastYears = Array.from(new Set([...byPastYearExact.keys(), ...byPastYearNear.keys()])).sort(
    (a, b) => b - a
  );
  for (const yr of pastYears) {
    const exact = byPastYearExact.get(yr) || [];
    const near = byPastYearNear.get(yr) || [];
    const list = exact.length > 0 ? exact : near;
    const yearsAgo = refYear - yr;
    const exactTag = exact.length > 0 ? 'On This Day' : 'This Week';
    pushMemory({
      id: `onthisday_${yr}`,
      type: 'on_this_day',
      badge: exactTag,
      title: yearsAgo === 1 ? '1 Year Ago' : `${yearsAgo} Years Ago`,
      subtitle: `${MONTH_NAMES[refMonth - 1]} ${refDay}, ${yr} · ${list.length} moment${list.length === 1 ? '' : 's'}`,
      photos: list,
    });
  }

  // 2. Place / Trip Memories (photos with GPS locationLabel grouped by location + month)
  const byPlaceMonth = new Map();
  for (const p of photos) {
    if (!p.locationLabel) continue;
    const parts = parseYmdParts(p);
    const ym = parts ? `${parts.year}-${String(parts.month).padStart(2, '0')}` : 'trip';
    const key = `${p.locationLabel}|${ym}`;
    if (!byPlaceMonth.has(key)) {
      byPlaceMonth.set(key, {
        location: p.locationLabel,
        year: parts ? parts.year : null,
        month: parts ? parts.month : null,
        items: [],
      });
    }
    byPlaceMonth.get(key).items.push(p);
  }
  const placeGroups = Array.from(byPlaceMonth.values())
    .filter((g) => g.items.length >= 2)
    .sort((a, b) => b.items.length - a.items.length)
    .slice(0, 4);
  for (const g of placeGroups) {
    const dateSub =
      g.month && g.year ? `${MONTH_NAMES[g.month - 1]} ${g.year}` : 'Trip Highlights';
    pushMemory({
      id: `trip_${g.location.toLowerCase().replace(/[^a-z0-9]+/g, '_')}_${g.year || ''}_${g.month || ''}`,
      type: 'trip',
      badge: 'Trip',
      title: g.location.split(',')[0],
      subtitle: `${dateSub} · ${g.items.length} photos`,
      photos: g.items,
    });
  }

  // 3. Favorites Highlight Reel
  const favs = photos.filter((p) => Boolean(p.isFavorite));
  if (favs.length >= 2) {
    pushMemory({
      id: 'favorites_reel',
      type: 'favorites',
      badge: '♥ Favorites',
      title: 'Best Loved',
      subtitle: `${favs.length} favorite moments`,
      photos: favs,
    });
  }

  // 4. Busy Day / Event Highlights (days with >= 3 photos)
  const byDay = new Map();
  for (const p of photos) {
    const parts = parseYmdParts(p);
    if (!parts) continue;
    if (!byDay.has(parts.ymd)) byDay.set(parts.ymd, { parts, items: [] });
    byDay.get(parts.ymd).items.push(p);
  }
  const highlightDays = Array.from(byDay.values())
    .filter((d) => d.items.length >= 3)
    .sort((a, b) => b.items.length - a.items.length || b.parts.ymd.localeCompare(a.parts.ymd))
    .slice(0, 3);
  for (const d of highlightDays) {
    pushMemory({
      id: `day_${d.parts.ymd}`,
      type: 'highlight',
      badge: 'Highlight',
      title: `${MONTH_NAMES[d.parts.month - 1]} ${d.parts.day}, ${d.parts.year}`,
      subtitle: `${d.items.length} captures from one day`,
      photos: d.items,
    });
  }

  // 5. Recent Highlights (last 30 days)
  const recent = photos.filter((p) => {
    const parts = parseYmdParts(p);
    if (!parts) return false;
    const ms = Date.UTC(parts.year, parts.month - 1, parts.day);
    return refMs - ms >= -86400000 && refMs - ms <= 30 * 86400000;
  });
  if (recent.length >= 2) {
    pushMemory({
      id: 'recent_30d',
      type: 'recent',
      badge: 'Recent',
      title: 'Past 30 Days',
      subtitle: `${recent.length} recent memories`,
      photos: recent,
    });
  }

  return memories.slice(0, maxMemories);
}

module.exports = { buildMemories };
