(() => {
  'use strict';

  const SESSION_KEY = 'photohub_web_session_v1';
  const PKCE_KEY = 'photohub_web_pkce_v1';
  const THEME_KEY = 'photohub_web_theme_v1';
  const VIDEO_EXTS = new Set(['mov', 'mp4', 'm4v', '3gp', 'avi']);

  // ==================== STATE ====================
  const state = {
    serverConfig: {
      googleEnabled: false,
      s3Enabled: false,
    },
    session: null, // { token, serverUrl, authMode, user }
    whoami: null,
    activeView: 'landing', // 'landing' | 'gallery'
    photos: [],
    years: [],
    totalPhotos: 0,
    hasMore: false,
    isLoadingPhotos: false,
    isLoadingMore: false,
    photosEtag: null,
    filterMedia: 'all', // 'all' | 'photo' | 'video' | 'protected'
    grouping: 'day', // 'day' | 'month' | 'year'
    searchQuery: '',
    selectedYear: null,
    isSelectionMode: false,
    selectedHashes: new Set(),
    visibleFlatPhotos: [],
    lightboxIndex: -1,
    lightboxBlobUrl: null,
    confirmCallback: null,
  };

  // Bounded LRU ObjectURL cache for grid thumbnails (prevents memory leaks on huge libraries)
  const MAX_THUMB_CACHE = 300;
  const thumbUrlCache = new Map(); // hash -> objectURL
  const inFlightThumbs = new Set();
  let activeThumbFetches = 0;
  const MAX_CONCURRENT_THUMBS = 6;
  const thumbFetchQueue = [];

  // ==================== SUNNY MASCOT SVG GENERATOR ====================
  function createSunnySvg(mood = 'happy') {
    const faceMarkup =
      mood === 'sleeping'
        ? `<path d="M44 63 Q48 67 52 63" fill="none" stroke="#3B2316" stroke-width="2.6" stroke-linecap="round"/>
           <path d="M68 63 Q72 67 76 63" fill="none" stroke="#3B2316" stroke-width="2.6" stroke-linecap="round"/>
           <path d="M56 71 Q60 74 64 71" fill="none" stroke="#3B2316" stroke-width="2.4" stroke-linecap="round"/>`
        : mood === 'celebrate'
          ? `<path d="M44 63 Q48 57 52 63" fill="none" stroke="#3B2316" stroke-width="2.8" stroke-linecap="round"/>
             <path d="M68 63 Q72 57 76 63" fill="none" stroke="#3B2316" stroke-width="2.8" stroke-linecap="round"/>
             <path d="M53 68 Q60 77 67 68" fill="none" stroke="#3B2316" stroke-width="2.8" stroke-linecap="round"/>`
          : `<g class="sunny-eyes">
               <circle cx="48" cy="61" r="4.6" fill="#3B2316"/>
               <circle cx="46.5" cy="59.4" r="1.6" fill="#FFFFFF"/>
               <circle cx="49.7" cy="62.4" r="0.9" fill="#FFFFFF"/>
               <circle cx="72" cy="61" r="4.6" fill="#3B2316"/>
               <circle cx="70.5" cy="59.4" r="1.6" fill="#FFFFFF"/>
               <circle cx="73.7" cy="62.4" r="0.9" fill="#FFFFFF"/>
             </g>
             <path d="M54 68 Q60 74 66 68" fill="none" stroke="#3B2316" stroke-width="2.7" stroke-linecap="round"/>`;

    const haloColor =
      mood === 'celebrate' ? '#34D399' : mood === 'uploading' ? '#FBBF24' : '#F97316';
    const uid = `sg_${Math.random().toString(36).slice(2, 8)}`;

    return `
      <svg class="sunny-svg" viewBox="0 0 120 116" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        <defs>
          <radialGradient id="${uid}_halo" cx="50%" cy="50%" r="50%">
            <stop offset="10%" stop-color="${haloColor}" stop-opacity="0.34"/>
            <stop offset="100%" stop-color="${haloColor}" stop-opacity="0"/>
          </radialGradient>
          <linearGradient id="${uid}_body" x1="15%" y1="10%" x2="88%" y2="95%">
            <stop offset="0%" stop-color="#FFB25A"/>
            <stop offset="52%" stop-color="#FA781C"/>
            <stop offset="100%" stop-color="#EA530B"/>
          </linearGradient>
        </defs>
        <circle class="sunny-halo" cx="60" cy="58" r="52" fill="url(#${uid}_halo)"/>
        <path class="sunny-sparkle-1" d="M99 17 L101.6 24.4 L109 27 L101.6 29.6 L99 37 L96.4 29.6 L89 27 L96.4 24.4 Z" fill="#FBBF24"/>
        <circle class="sunny-sparkle-2" cx="21" cy="31" r="3.2" fill="#FF865E"/>
        <!-- Fluffy Cloud Cushion -->
        <g opacity="0.96">
          <ellipse cx="60" cy="95" rx="34" ry="10" fill="#EBF3FF"/>
          <circle cx="40" cy="89" r="11" fill="#FFFFFF"/>
          <circle cx="57" cy="86" r="14" fill="#FFFFFF"/>
          <circle cx="75" cy="89" r="11.5" fill="#FFFFFF"/>
          <rect x="33" y="87" width="52" height="12" rx="6" fill="#FFFFFF"/>
        </g>
        <!-- Floating Sunny Camera Body -->
        <g class="sunny-body-group">
          <rect x="19" y="55" width="12" height="20" rx="6" fill="#EA580C" transform="rotate(24 25 65)"/>
          <g class="sunny-paw-right">
            <rect x="89" y="51" width="12" height="20" rx="6" fill="#EA580C" transform="rotate(-24 95 61)"/>
          </g>
          <!-- Shutter + Viewfinder Hump -->
          <rect x="36" y="30" width="13" height="9" rx="4.5" fill="#F59E0B"/>
          <rect x="50" y="25" width="24" height="14" rx="7" fill="#F97316"/>
          <!-- Main Plump Body -->
          <rect x="26" y="35" width="68" height="53" rx="20" fill="url(#${uid}_body)"/>
          <!-- Gloss Highlight -->
          <ellipse cx="47" cy="44" rx="14" ry="4.5" fill="#FFFFFF" opacity="0.28" transform="rotate(-12 47 44)"/>
          <!-- Warm Cream Face Screen -->
          <rect x="36" y="47" width="48" height="33" rx="13" fill="#FFF6EC"/>
          <!-- Cheeks -->
          <ellipse cx="43" cy="68" rx="4.6" ry="2.6" fill="#FF7E6B" opacity="0.72"/>
          <ellipse cx="77" cy="68" rx="4.6" ry="2.6" fill="#FF7E6B" opacity="0.72"/>
          ${faceMarkup}
        </g>
      </svg>`;
  }

  function hydrateSunnyMascots() {
    document.querySelectorAll('.sunny-stage').forEach((el) => {
      const mood = el.getAttribute('data-sunny-mood') || 'happy';
      el.innerHTML = createSunnySvg(mood);
    });
  }

  function setMascotMood(el, mood) {
    if (!el) return;
    el.setAttribute('data-sunny-mood', mood);
    el.innerHTML = createSunnySvg(mood);
  }

  // ==================== HELPERS ====================
  const $ = (id) => document.getElementById(id);

  function formatBytes(bytes) {
    const n = Number(bytes) || 0;
    if (n <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let val = n;
    let idx = 0;
    while (val >= 1000 && idx < units.length - 1) {
      val /= 1000;
      idx++;
    }
    return `${val >= 100 || idx === 0 ? Math.round(val) : val.toFixed(1)} ${units[idx]}`;
  }

  function isVideoPhoto(photo) {
    const name = String(photo.originalName || photo.savedPath || '');
    const ext = name.includes('.') ? name.split('.').pop().toLowerCase() : '';
    return VIDEO_EXTS.has(ext);
  }

  function parsePhotoDateMs(photo) {
    const candidates = [photo.takenAt, photo.photoDate, photo.uploadedAt];
    for (const raw of candidates) {
      if (!raw) continue;
      const str = String(raw).trim();
      if (/^\d{4}-\d{2}-\d{2}$/.test(str)) {
        const ms = Date.parse(`${str}T12:00:00Z`);
        if (!Number.isNaN(ms)) return ms;
      }
      const ms = Date.parse(str);
      if (!Number.isNaN(ms)) return ms;
    }
    return null;
  }

  function showToast(msg, variant = 'orange') {
    const stack = $('toastStack');
    if (!stack) return;
    const el = document.createElement('div');
    el.className = `toast toast--${variant}`;
    el.textContent = msg;
    stack.appendChild(el);
    setTimeout(() => {
      el.style.opacity = '0';
      el.style.transform = 'translateY(8px)';
      el.style.transition = 'opacity 0.25s ease, transform 0.25s ease';
      setTimeout(() => el.remove(), 260);
    }, 3200);
  }

  // Pure-JS SHA-256 fallback so PKCE S256 also works if user opens over plain HTTP LAN IP
  function sha256FallbackBytes(ascii) {
    const rightRotate = (v, a) => (v >>> a) | (v << (32 - a));
    const maxWord = 4294967296;
    const words = [];
    const bytes = new TextEncoder().encode(ascii);
    const bitLen = bytes.length * 8;
    let hash = [];
    let k = [];
    let primeCounter = 0;
    const isComposite = {};
    for (let candidate = 2; primeCounter < 64; candidate++) {
      if (!isComposite[candidate]) {
        for (let i = 0; i < 313; i += candidate) isComposite[i] = candidate;
        hash[primeCounter] = (Math.pow(candidate, 0.5) * maxWord) | 0;
        k[primeCounter++] = (Math.pow(candidate, 1 / 3) * maxWord) | 0;
      }
    }
    const padded = new Uint8Array(((bytes.length + 9 + 63) & ~63));
    padded.set(bytes);
    padded[bytes.length] = 0x80;
    const view = new DataView(padded.buffer);
    view.setUint32(padded.length - 8, Math.floor(bitLen / maxWord), false);
    view.setUint32(padded.length - 4, bitLen >>> 0, false);

    for (let i = 0; i < padded.length; i += 4) {
      words.push(view.getUint32(i, false));
    }
    hash = hash.slice(0, 8);
    for (let j = 0; j < words.length; ) {
      const w = words.slice(j, (j += 16));
      const oldHash = hash.slice(0);
      for (let i = 0; i < 64; i++) {
        const w15 = w[i - 15];
        const w2 = w[i - 2];
        const a = hash[0];
        const e = hash[4];
        const t1 =
          hash[7] +
          (rightRotate(e, 6) ^ rightRotate(e, 11) ^ rightRotate(e, 25)) +
          ((e & hash[5]) ^ (~e & hash[6])) +
          k[i] +
          (w[i] =
            i < 16
              ? w[i]
              : (w[i - 16] +
                  (rightRotate(w15, 7) ^ rightRotate(w15, 18) ^ (w15 >>> 3)) +
                  w[i - 7] +
                  (rightRotate(w2, 17) ^ rightRotate(w2, 19) ^ (w2 >>> 10))) |
                0);
        const t2 =
          (rightRotate(a, 2) ^ rightRotate(a, 13) ^ rightRotate(a, 22)) +
          ((a & hash[1]) ^ (a & hash[2]) ^ (hash[1] & hash[2]));
        hash = [(t1 + t2) | 0].concat(hash);
        hash[4] = (hash[4] + t1) | 0;
        hash.pop();
      }
      for (let i = 0; i < 8; i++) hash[i] = (hash[i] + oldHash[i]) | 0;
    }
    const out = new Uint8Array(32);
    const outView = new DataView(out.buffer);
    for (let i = 0; i < 8; i++) outView.setUint32(i * 4, hash[i], false);
    return out;
  }

  function toBase64Url(uint8) {
    let bin = '';
    for (let i = 0; i < uint8.length; i++) bin += String.fromCharCode(uint8[i]);
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  async function computePkceChallenge(verifier) {
    if (window.crypto && window.crypto.subtle) {
      const buf = await window.crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
      return toBase64Url(new Uint8Array(buf));
    }
    return toBase64Url(sha256FallbackBytes(verifier));
  }

  function randomPkceVerifier() {
    const arr = new Uint8Array(40);
    if (window.crypto && window.crypto.getRandomValues) {
      window.crypto.getRandomValues(arr);
    } else {
      for (let i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 256);
    }
    return toBase64Url(arr);
  }

  // ==================== THEME ====================
  function initTheme() {
    const saved = localStorage.getItem(THEME_KEY);
    const prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    const theme = saved || (prefersDark ? 'dark' : 'light');
    document.documentElement.setAttribute('data-theme', theme);
  }

  function toggleTheme() {
    const cur = document.documentElement.getAttribute('data-theme') || 'light';
    const next = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    localStorage.setItem(THEME_KEY, next);
  }

  // ==================== SESSION & API ====================
  function loadStoredSession() {
    try {
      const raw = localStorage.getItem(SESSION_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (parsed && parsed.token && parsed.authMode === 'google') return parsed;
    } catch {
      // ignore
    }
    return null;
  }

  function saveSession(session) {
    state.session = session;
    if (session) {
      localStorage.setItem(SESSION_KEY, JSON.stringify(session));
    } else {
      localStorage.removeItem(SESSION_KEY);
    }
  }

  function apiUrlFor(path) {
    // Always call same-origin (`window.location.origin`) to avoid CORS & HTTPS->HTTP mixed-content blocks.
    // When assigned to a remote storage node, route through Gateway's authenticated `/api/web-node/*` proxy.
    const needsProxy = Boolean(
      state.session &&
        (state.session.useGatewayProxy === true ||
          (state.session.isLocalNode === false) ||
          (state.session.useGatewayProxy === undefined &&
            state.session.nodeId &&
            state.session.nodeId !== 'primary'))
    );
    const resolvedPath =
      needsProxy && path.startsWith('/api/')
        ? `/api/web-node/${path.slice(5)}`
        : path;
    return `${window.location.origin}${resolvedPath}`;
  }

  function authHeaders(extra = {}) {
    const h = { ...extra };
    const token = state.session && state.session.token;
    if (token) {
      h['Authorization'] = `Bearer ${token}`;
    }
    return h;
  }

  async function apiFetch(path, options = {}) {
    const url = apiUrlFor(path);
    const res = await fetch(url, {
      ...options,
      headers: authHeaders(options.headers || {}),
    });
    if (res.status === 401 && state.session) {
      signOut(false);
      showToast('Session expired — please sign in again.', 'rose');
      openLoginModal();
      const err = new Error('Unauthorized');
      err.isUnauthorized = true;
      throw err;
    }
    return res;
  }

  function mediaUrlWithAuth(path) {
    const base = apiUrlFor(path);
    const token = state.session && state.session.token;
    if (!token) return base;
    const sep = base.includes('?') ? '&' : '?';
    return `${base}${sep}apiKey=${encodeURIComponent(token)}`;
  }

  // ==================== NAVIGATION & VIEWS ====================
  function switchView(view) {
    if (view === 'gallery' && !state.session) {
      openLoginModal();
      return;
    }
    state.activeView = view;
    const isGallery = view === 'gallery';
    $('landingView').classList.toggle('hidden', isGallery);
    $('galleryView').classList.toggle('hidden', !isGallery);
    $('tabGuideBtn').classList.toggle('is-active', !isGallery);
    $('tabGalleryBtn').classList.toggle('is-active', isGallery);

    const targetPath = isGallery ? '/gallery' : '/';
    if (
      window.location.pathname === '/' ||
      window.location.pathname === '/gallery' ||
      window.location.pathname === '/about' ||
      window.location.pathname === '/auth/callback'
    ) {
      if (window.location.pathname !== targetPath || window.location.search) {
        window.history.replaceState({}, document.title, targetPath);
      }
    }

    if (isGallery && state.photos.length === 0 && !state.isLoadingPhotos) {
      loadGallery(false);
    }
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function updateAuthUI() {
    const signedIn = Boolean(state.session);
    $('navSignInBtn').classList.toggle('hidden', signedIn);
    $('navUserMenu').classList.toggle('hidden', !signedIn);
    $('heroSignInLabel').textContent = signedIn ? 'Open My Photos' : 'Sign In to My Photos';

    if (signedIn) {
      const displayName =
        (state.whoami && (state.whoami.name || state.whoami.email || state.whoami.userFolder)) ||
        (state.session.user && (state.session.user.name || state.session.user.email)) ||
        'PhotoHub User';
      $('navUserName').textContent = displayName;
      $('navUserInitial').textContent = String(displayName).trim().charAt(0).toUpperCase() || 'P';
      $('galleryGreeting').textContent =
        state.whoami && state.whoami.name ? `Hi, ${state.whoami.name.split(' ')[0]}` : 'Your Cloud Photos';
      $('galleryFolderBadge').textContent =
        state.whoami && state.whoami.userFolder ? `/${state.whoami.userFolder}` : '/ root';
      const s3 = state.whoami ? Boolean(state.whoami.s3Enabled) : Boolean(state.serverConfig.s3Enabled);
      $('galleryModeBadge').textContent = s3 ? 'Auto · S3' : 'Auto · Direct';
      updateStorageBanner(state.whoami && state.whoami.storage);
    }
  }

  function updateStorageBanner(storage) {
    if (!storage) {
      $('storageUsedLabel').textContent = `${state.totalPhotos} items`;
      $('storageQuotaLabel').textContent = 'Connected';
      $('storageFillBar').style.width = '12%';
      $('storageSplitLabel').textContent = 'Originals & proxies synced';
      return;
    }
    const used = Number(storage.usedBytes) || 0;
    const quota = Number(storage.quotaBytes) || 0;
    const masters = Number(storage.mastersBytes) || 0;
    const proxies = Number(storage.proxiesBytes) || 0;
    $('storageUsedLabel').textContent = `${formatBytes(used)} used`;
    if (quota > 0) {
      const pct = Math.min(100, Math.max(2, Math.round((used / quota) * 100)));
      $('storageQuotaLabel').textContent = `${formatBytes(quota)} (${pct}%)`;
      $('storageFillBar').style.width = `${pct}%`;
    } else {
      $('storageQuotaLabel').textContent = 'Unlimited';
      $('storageFillBar').style.width = used > 0 ? '24%' : '4%';
    }
    $('storageSplitLabel').textContent = `Originals ${formatBytes(masters)} · Proxies ${formatBytes(proxies)}`;
  }

  // ==================== LOGIN FLOW (GOOGLE OAUTH PKCE) ====================
  function openLoginModal(errorMsg = '') {
    const googleReady = Boolean(state.serverConfig.googleEnabled);
    const googleBtn = $('googleSignInBtn');
    googleBtn.disabled = !googleReady;

    const errEl = $('loginErrorBanner');
    const displayErr =
      errorMsg ||
      (!googleReady
        ? 'Google Login is not configured on this server yet. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in .env.'
        : '');
    if (displayErr) {
      errEl.textContent = displayErr;
      errEl.classList.remove('hidden');
    } else {
      errEl.classList.add('hidden');
    }
    $('loginModal').classList.remove('hidden');
  }

  function closeLoginModal() {
    $('loginModal').classList.add('hidden');
  }

  function storePkceVerifier(verifier) {
    const payload = JSON.stringify({ v: verifier, exp: Date.now() + 10 * 60 * 1000 });
    try {
      sessionStorage.setItem(PKCE_KEY, payload);
    } catch {
      // ignore storage quota/privacy restrictions
    }
    try {
      localStorage.setItem(PKCE_KEY, payload);
    } catch {
      // ignore storage quota/privacy restrictions
    }
  }

  function consumePkceVerifier() {
    let raw = null;
    try {
      raw = sessionStorage.getItem(PKCE_KEY);
      sessionStorage.removeItem(PKCE_KEY);
    } catch {
      // ignore
    }
    let fallbackRaw = null;
    try {
      fallbackRaw = localStorage.getItem(PKCE_KEY);
      localStorage.removeItem(PKCE_KEY);
    } catch {
      // ignore
    }
    const candidate = raw || fallbackRaw;
    if (!candidate) return null;
    try {
      const parsed = JSON.parse(candidate);
      if (parsed && typeof parsed.v === 'string') {
        if (parsed.exp && Date.now() > parsed.exp) return null;
        return parsed.v;
      }
    } catch {
      // Support legacy raw string value
      return candidate;
    }
    return null;
  }

  async function startGoogleLogin() {
    if (!state.serverConfig.googleEnabled) {
      openLoginModal('Google Login is not configured on this server yet.');
      return;
    }
    try {
      const verifier = randomPkceVerifier();
      const challenge = await computePkceChallenge(verifier);
      storePkceVerifier(verifier);
      const redirectUri = `${window.location.origin}/auth/callback`;
      const startUrl = new URL('/api/auth/google/start', window.location.origin);
      startUrl.searchParams.set('code_challenge', challenge);
      startUrl.searchParams.set('redirect_uri', redirectUri);
      window.location.href = startUrl.toString();
    } catch (err) {
      openLoginModal(err.message || 'Could not start Google sign-in.');
    }
  }

  async function handleOAuthCallbackIfPresent() {
    const params = new URLSearchParams(window.location.search);
    const oauthErr = params.get('error');
    const code = params.get('code');
    if (!oauthErr && !code) return false;

    // Clean callback params from URL immediately
    window.history.replaceState({}, document.title, '/');

    if (oauthErr) {
      openLoginModal(oauthErr);
      return false;
    }

    const verifier = consumePkceVerifier();
    if (!verifier) {
      openLoginModal('Sign-in session expired. Please try Google Sign-In again.');
      return false;
    }

    $('splashStatusText').textContent = 'Completing Google sign-in…';
    try {
      const res = await fetch('/api/auth/exchange', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code, codeVerifier: verifier }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.success || !data.token) {
        openLoginModal(data.error || 'Could not exchange login code.');
        return false;
      }

      saveSession({
        token: data.token,
        serverUrl: data.serverUrl || window.location.origin,
        nodeId: data.nodeId || 'primary',
        isLocalNode: data.isLocalNode !== false,
        useGatewayProxy: data.isLocalNode === false,
        authMode: 'google',
        user: data.user || null,
      });
      showToast('Signed in with Google!', 'mint');
      return true;
    } catch (err) {
      openLoginModal(err.message || 'Network error while completing Google sign-in.');
      return false;
    }
  }

  function signOut(notify = true) {
    saveSession(null);
    state.whoami = null;
    state.photos = [];
    state.years = [];
    state.photosEtag = null;
    state.selectedHashes.clear();
    state.isSelectionMode = false;
    clearThumbCache();
    updateSelectionBar();
    updateAuthUI();
    switchView('landing');
    if (notify) showToast('Signed out.');
  }

  async function verifySession() {
    if (!state.session) return { ok: false, unauthorized: false };
    try {
      const res = await apiFetch('/api/whoami');
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        return {
          ok: false,
          unauthorized: res.status === 401,
          error: body.error || `Server returned HTTP ${res.status}`,
        };
      }
      const data = await res.json();
      state.whoami = data;
      updateAuthUI();
      return { ok: true, unauthorized: false };
    } catch (err) {
      return {
        ok: false,
        unauthorized: Boolean(err && err.isUnauthorized),
        error: (err && err.message) || 'Connection error',
      };
    }
  }

  // ==================== GALLERY DATA & TIMELINE ====================
  async function loadGallery(forceSync = false) {
    if (!state.session || state.isLoadingPhotos) return;
    state.isLoadingPhotos = true;
    $('refreshGalleryBtn').querySelector('.refresh-svg').classList.add('is-spinning');
    if (state.photos.length === 0) {
      $('gallerySkeleton').classList.remove('hidden');
      $('galleryEmptyState').classList.add('hidden');
    }

    try {
      const headers = {};
      if (!forceSync && state.photosEtag && state.photos.length > 0 && !state.hasMore) {
        headers['If-None-Match'] = state.photosEtag;
      }
      const query = new URLSearchParams({ limit: '240', offset: '0' });
      if (forceSync) query.set('sync', '1');
      if (state.selectedYear) query.set('year', String(state.selectedYear));

      const res = await apiFetch(`/api/photos?${query.toString()}`, { headers });
      if (res.status === 304) {
        // Gallery unchanged!
        renderGallery();
        return;
      }
      if (!res.ok) throw new Error(`Server returned HTTP ${res.status}`);
      const etag = res.headers.get('ETag');
      if (etag && !state.selectedYear) state.photosEtag = etag;

      const data = await res.json();
      state.photos = Array.isArray(data.photos) ? data.photos : [];
      state.totalPhotos = Number(data.total) || state.photos.length;
      state.hasMore = Boolean(data.hasMore);
      if (Array.isArray(data.years)) {
        state.years = data.years;
        renderYearPills();
      }
      renderGallery();
      verifySession();
    } catch (err) {
      if (state.photos.length === 0) {
        $('galleryEmptyState').classList.remove('hidden');
        setMascotMood($('emptyStateMascot'), 'alert');
        $('emptyStateTitle').textContent = 'Could Not Load Photos';
        $('emptyStateText').textContent = err.message || 'Check your connection and retry.';
      } else {
        showToast(err.message || 'Refresh failed', 'rose');
      }
    } finally {
      state.isLoadingPhotos = false;
      $('gallerySkeleton').classList.add('hidden');
      $('refreshGalleryBtn').querySelector('.refresh-svg').classList.remove('is-spinning');
    }
  }

  async function loadMorePhotos() {
    if (!state.session || !state.hasMore || state.isLoadingMore || state.isLoadingPhotos) return;
    state.isLoadingMore = true;
    $('loadMoreWrap').classList.remove('hidden');
    try {
      const query = new URLSearchParams({
        limit: '240',
        offset: String(state.photos.length),
      });
      if (state.selectedYear) query.set('year', String(state.selectedYear));
      const res = await apiFetch(`/api/photos?${query.toString()}`);
      if (!res.ok) return;
      const data = await res.json();
      const incoming = Array.isArray(data.photos) ? data.photos : [];
      const seen = new Set(state.photos.map((p) => p.hash.toLowerCase()));
      for (const p of incoming) {
        if (!seen.has(p.hash.toLowerCase())) {
          seen.add(p.hash.toLowerCase());
          state.photos.push(p);
        }
      }
      state.hasMore = Boolean(data.hasMore) && incoming.length > 0;
      renderGallery();
    } finally {
      state.isLoadingMore = false;
      if (!state.hasMore) $('loadMoreWrap').classList.add('hidden');
    }
  }

  function renderYearPills() {
    const bar = $('yearJumpBar');
    if (!state.years || state.years.length <= 1) {
      bar.classList.add('hidden');
      return;
    }
    bar.classList.remove('hidden');
    bar.innerHTML = '';

    const allBtn = document.createElement('button');
    allBtn.type = 'button';
    allBtn.className = `year-pill${state.selectedYear === null ? ' is-active' : ''}`;
    allBtn.textContent = `All (${state.years.reduce((s, y) => s + y.count, 0)})`;
    allBtn.addEventListener('click', () => {
      state.selectedYear = null;
      state.photosEtag = null;
      renderYearPills();
      loadGallery(false);
    });
    bar.appendChild(allBtn);

    for (const yr of state.years) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = `year-pill${state.selectedYear === yr.year ? ' is-active' : ''}`;
      btn.textContent = `${yr.year} · ${yr.count}`;
      btn.addEventListener('click', () => {
        state.selectedYear = yr.year;
        state.photosEtag = null;
        renderYearPills();
        loadGallery(false);
      });
      bar.appendChild(btn);
    }
  }

  function filteredPhotos() {
    const q = state.searchQuery.trim().toLowerCase();
    return state.photos.filter((p) => {
      const isVid = isVideoPhoto(p);
      if (state.filterMedia === 'photo' && isVid) return false;
      if (state.filterMedia === 'video' && !isVid) return false;
      if (state.filterMedia === 'protected' && !p.keepOriginalOnDevice) return false;
      if (q) {
        const hay = `${p.originalName || ''} ${p.photoDate || ''} ${p.savedPath || ''}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }

  function groupPhotosIntoSections(items) {
    const now = new Date();
    const todayKey = now.toISOString().slice(0, 10);
    const yest = new Date(now.getTime() - 86400000).toISOString().slice(0, 10);
    const map = new Map();

    const dayFmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
    const monthFmt = new Intl.DateTimeFormat(undefined, { month: 'long', year: 'numeric' });

    for (const p of items) {
      const ms = parsePhotoDateMs(p);
      let key = 'undated';
      let label = 'Undated';
      if (ms !== null) {
        const dt = new Date(ms);
        const ymd = dt.toISOString().slice(0, 10);
        if (state.grouping === 'year') {
          key = String(dt.getFullYear());
          label = key;
        } else if (state.grouping === 'month') {
          key = ymd.slice(0, 7);
          label = monthFmt.format(dt);
        } else {
          key = ymd;
          if (ymd === todayKey) label = 'Today';
          else if (ymd === yest) label = 'Yesterday';
          else label = dayFmt.format(dt);
        }
      }
      if (!map.has(key)) map.set(key, { key, label, photos: [] });
      map.get(key).photos.push(p);
    }
    return Array.from(map.values());
  }

  // Lazy Thumbnail IntersectionObserver
  const thumbObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const tile = entry.target;
        thumbObserver.unobserve(tile);
        const hash = tile.dataset.hash;
        const isVid = tile.dataset.video === '1';
        const needsProxy = tile.dataset.needsProxy === '1';
        if (hash) {
          queueThumbnailLoad(tile, hash, isVid, needsProxy);
        }
      }
    },
    { rootMargin: '260px 0px' }
  );

  function clearThumbCache() {
    for (const url of thumbUrlCache.values()) {
      URL.revokeObjectURL(url);
    }
    thumbUrlCache.clear();
    inFlightThumbs.clear();
    thumbFetchQueue.length = 0;
  }

  function rememberThumbUrl(hash, objectUrl) {
    if (thumbUrlCache.has(hash)) {
      thumbUrlCache.delete(hash);
    }
    thumbUrlCache.set(hash, objectUrl);
    if (thumbUrlCache.size > MAX_THUMB_CACHE) {
      const oldestKey = thumbUrlCache.keys().next().value;
      const oldUrl = thumbUrlCache.get(oldestKey);
      thumbUrlCache.delete(oldestKey);
      if (oldUrl) URL.revokeObjectURL(oldUrl);
    }
  }

  function applyThumbToTile(tile, url) {
    const img = tile.querySelector('img');
    const shimmer = tile.querySelector('.photo-tile-shimmer');
    if (img) {
      img.src = url;
      img.onload = () => {
        img.classList.add('is-loaded');
        if (shimmer) shimmer.remove();
      };
    }
  }

  function showTileFallback(tile, isVid) {
    const shimmer = tile.querySelector('.photo-tile-shimmer');
    if (shimmer) shimmer.remove();
    const ph = document.createElement('div');
    ph.className = 'tile-placeholder';
    ph.innerHTML = isVid
      ? `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="24" height="24"><polygon points="5 3 19 12 5 21 5 3"/></svg><span>Video</span>`
      : `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="24" height="24"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg><span>Photo</span>`;
    tile.appendChild(ph);
  }

  function queueThumbnailLoad(tile, hash, isVid, needsProxy) {
    if (thumbUrlCache.has(hash)) {
      applyThumbToTile(tile, thumbUrlCache.get(hash));
      return;
    }
    if (isVid && needsProxy) {
      showTileFallback(tile, true);
      return;
    }
    thumbFetchQueue.push({ tile, hash, isVid });
    drainThumbQueue();
  }

  function drainThumbQueue() {
    while (activeThumbFetches < MAX_CONCURRENT_THUMBS && thumbFetchQueue.length > 0) {
      const job = thumbFetchQueue.shift();
      if (!job || !job.tile.isConnected) continue;
      if (thumbUrlCache.has(job.hash)) {
        applyThumbToTile(job.tile, thumbUrlCache.get(job.hash));
        continue;
      }
      if (inFlightThumbs.has(job.hash)) continue;
      inFlightThumbs.add(job.hash);
      activeThumbFetches++;

      apiFetch(`/api/photo/${encodeURIComponent(job.hash)}/preview`)
        .then((res) => (res.ok ? res.blob() : null))
        .then((blob) => {
          if (blob && blob.size > 0) {
            const objUrl = URL.createObjectURL(blob);
            rememberThumbUrl(job.hash, objUrl);
            document
              .querySelectorAll(`.photo-tile[data-hash="${CSS.escape(job.hash)}"]`)
              .forEach((t) => applyThumbToTile(t, objUrl));
          } else {
            showTileFallback(job.tile, job.isVid);
          }
        })
        .catch(() => {
          showTileFallback(job.tile, job.isVid);
        })
        .finally(() => {
          inFlightThumbs.delete(job.hash);
          activeThumbFetches--;
          drainThumbQueue();
        });
    }
  }

  function renderGallery() {
    const items = filteredPhotos();
    state.visibleFlatPhotos = items;

    const vidCount = state.photos.filter(isVideoPhoto).length;
    const photoCount = state.photos.length - vidCount;
    $('galleryCountsText').textContent = `${state.totalPhotos} total · ${photoCount} photos · ${vidCount} videos`;

    const container = $('galleryTimeline');
    container.innerHTML = '';

    if (items.length === 0) {
      $('galleryEmptyState').classList.remove('hidden');
      setMascotMood($('emptyStateMascot'), 'sleeping');
      $('emptyStateTitle').textContent = state.photos.length === 0 ? 'No Backups Yet' : 'No Matching Items';
      $('emptyStateText').textContent =
        state.photos.length === 0
          ? 'Open PhotoHub on iOS or Android to start backing up photos.'
          : 'Try clearing your search or switching filters.';
      $('loadMoreWrap').classList.add('hidden');
      return;
    }

    $('galleryEmptyState').classList.add('hidden');
    const sections = groupPhotosIntoSections(items);
    const frag = document.createDocumentFragment();
    let flatIndex = 0;

    for (const sec of sections) {
      const secEl = document.createElement('section');
      secEl.className = 'timeline-section';

      const head = document.createElement('div');
      head.className = 'timeline-heading';
      head.innerHTML = `<h3></h3><span class="timeline-count"></span>`;
      head.querySelector('h3').textContent = sec.label;
      head.querySelector('.timeline-count').textContent = `${sec.photos.length}`;
      secEl.appendChild(head);

      const grid = document.createElement('div');
      grid.className = 'photo-grid';

      for (const photo of sec.photos) {
        const idx = flatIndex++;
        const isVid = isVideoPhoto(photo);
        const needsProxy = photo.hasProxy !== true || photo.hasPreview === false;
        const normHash = photo.hash.toLowerCase();
        const isSelected = state.selectedHashes.has(normHash);

        const tile = document.createElement('div');
        tile.className = `photo-tile${isSelected ? ' is-selected' : ''}`;
        tile.dataset.hash = photo.hash;
        tile.dataset.video = isVid ? '1' : '0';
        tile.dataset.needsProxy = needsProxy ? '1' : '0';
        tile.tabIndex = 0;
        tile.setAttribute('role', 'button');
        tile.setAttribute('aria-label', photo.originalName || 'Photo');

        tile.innerHTML = `<div class="photo-tile-shimmer"></div><img alt="" loading="lazy" />`;
        tile.querySelector('img').alt = photo.originalName || '';

        if (state.isSelectionMode) {
          const chk = document.createElement('div');
          chk.className = 'tile-select-check';
          chk.textContent = isSelected ? '✓' : '';
          tile.appendChild(chk);
        }

        if (isVid) {
          const vp = document.createElement('div');
          vp.className = 'tile-video-pill';
          vp.innerHTML = `▶ Video`;
          tile.appendChild(vp);
        }

        if (photo.keepOriginalOnDevice) {
          const badges = document.createElement('div');
          badges.className = 'tile-badges';
          badges.innerHTML = `<span class="tile-badge tile-badge--protected" title="Restored original protected">✓</span>`;
          tile.appendChild(badges);
        }

        tile.addEventListener('click', () => {
          if (state.isSelectionMode) {
            togglePhotoSelect(photo.hash, tile);
          } else {
            openLightbox(idx);
          }
        });

        tile.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            tile.click();
          }
        });

        grid.appendChild(tile);
        thumbObserver.observe(tile);
      }

      secEl.appendChild(grid);
      frag.appendChild(secEl);
    }

    container.appendChild(frag);
    $('loadMoreWrap').classList.toggle('hidden', !state.hasMore);
    if (state.hasMore) {
      $('loadMoreLabel').textContent = `Showing ${state.photos.length} of ${state.totalPhotos} — scroll for more`;
    }
  }

  // Infinite scroll sentinel observer
  const loadMoreObserver = new IntersectionObserver(
    (entries) => {
      if (entries.some((e) => e.isIntersecting) && state.hasMore && state.activeView === 'gallery') {
        loadMorePhotos();
      }
    },
    { rootMargin: '300px 0px' }
  );

  // ==================== MULTI-SELECT & DELETE ====================
  function toggleSelectionMode(force) {
    state.isSelectionMode = typeof force === 'boolean' ? force : !state.isSelectionMode;
    if (!state.isSelectionMode) state.selectedHashes.clear();
    $('selectModeBtn').textContent = state.isSelectionMode ? 'Done' : 'Select';
    updateSelectionBar();
    renderGallery();
  }

  function togglePhotoSelect(hash, tileEl) {
    const norm = hash.toLowerCase();
    if (state.selectedHashes.has(norm)) {
      state.selectedHashes.delete(norm);
    } else {
      state.selectedHashes.add(norm);
    }
    if (tileEl) {
      const selected = state.selectedHashes.has(norm);
      tileEl.classList.toggle('is-selected', selected);
      const chk = tileEl.querySelector('.tile-select-check');
      if (chk) chk.textContent = selected ? '✓' : '';
    }
    updateSelectionBar();
  }

  function updateSelectionBar() {
    const bar = $('selectionBar');
    bar.classList.toggle('hidden', !state.isSelectionMode);
    if (!state.isSelectionMode) return;
    const count = state.selectedHashes.size;
    let totalBytes = 0;
    for (const p of state.photos) {
      if (state.selectedHashes.has(p.hash.toLowerCase())) {
        totalBytes += Number(p.size) || 0;
      }
    }
    $('selectionCountText').textContent = `${count} selected`;
    $('selectionSizeText').textContent = formatBytes(totalBytes);
    $('deleteSelectedBtn').disabled = count === 0;
  }

  function openConfirmModal(title, text, onConfirm) {
    $('confirmTitle').textContent = title;
    $('confirmText').textContent = text;
    state.confirmCallback = onConfirm;
    $('confirmModal').classList.remove('hidden');
  }

  function closeConfirmModal() {
    $('confirmModal').classList.add('hidden');
    state.confirmCallback = null;
  }

  async function deletePhotosOnServer(hashes) {
    if (!hashes || hashes.length === 0) return;
    try {
      const res = await apiFetch('/api/photos/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ hashes }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Delete failed');
      const removed = new Set(
        [...(data.deleted || []), ...(data.missing || [])].map((h) => String(h).toLowerCase())
      );
      state.photos = state.photos.filter((p) => !removed.has(p.hash.toLowerCase()));
      state.totalPhotos = Math.max(0, state.totalPhotos - removed.size);
      state.photosEtag = null;
      for (const h of removed) state.selectedHashes.delete(h);
      if (data.storage && state.whoami) {
        state.whoami.storage = { ...(state.whoami.storage || {}), ...data.storage };
        updateStorageBanner(state.whoami.storage);
      }
      showToast(`Deleted ${removed.size} item(s) · Freed ${formatBytes(data.freedBytes || 0)}`, 'mint');
      toggleSelectionMode(false);
    } catch (err) {
      showToast(err.message || 'Delete failed', 'rose');
    }
  }

  // ==================== LIGHTBOX ====================
  function cleanupLightboxMedia() {
    const img = $('lbImage');
    const vid = $('lbVideo');
    vid.pause();
    vid.removeAttribute('src');
    vid.load();
    vid.classList.add('hidden');
    img.classList.add('hidden');
    img.removeAttribute('src');
    if (state.lightboxBlobUrl) {
      URL.revokeObjectURL(state.lightboxBlobUrl);
      state.lightboxBlobUrl = null;
    }
    $('lbDownloadBar').classList.add('hidden');
  }

  function openLightbox(index) {
    if (index < 0 || index >= state.visibleFlatPhotos.length) return;
    state.lightboxIndex = index;
    $('lightbox').classList.remove('hidden');
    document.body.style.overflow = 'hidden';
    renderLightboxItem();
  }

  function closeLightbox() {
    cleanupLightboxMedia();
    $('lightbox').classList.add('hidden');
    document.body.style.overflow = '';
    state.lightboxIndex = -1;
  }

  async function renderLightboxItem() {
    const photo = state.visibleFlatPhotos[state.lightboxIndex];
    if (!photo) return;
    cleanupLightboxMedia();

    const isVid = isVideoPhoto(photo);
    $('lbFilename').textContent = photo.originalName || photo.hash.slice(0, 12);
    const dateStr = photo.photoDate || (photo.uploadedAt || '').slice(0, 10) || 'Undated';
    $('lbMeta').textContent = `${dateStr} · Original ${formatBytes(photo.size)}`;

    $('lbPrevBtn').disabled = state.lightboxIndex <= 0;
    $('lbNextBtn').disabled = state.lightboxIndex >= state.visibleFlatPhotos.length - 1;

    const badges = $('lbBadges');
    badges.innerHTML = '';
    if (isVid) {
      badges.innerHTML += `<span class="mini-badge mini-badge--orange">Video</span>`;
    }
    if (photo.keepOriginalOnDevice) {
      badges.innerHTML += `<span class="mini-badge mini-badge--mint">Protected Original</span>`;
    }
    if (photo.proxySize) {
      badges.innerHTML += `<span class="mini-badge mini-badge--amber">Proxy ${formatBytes(photo.proxySize)}</span>`;
    }

    $('lbProtectBtn').textContent = photo.keepOriginalOnDevice ? 'Unprotect' : 'Protect';

    const spinner = $('lbSpinner');
    spinner.classList.remove('hidden');
    $('lbSpinnerText').textContent = isVid ? 'Loading video…' : 'Loading photo…';

    if (isVid) {
      const vid = $('lbVideo');
      const useProxy = Boolean(photo.hasVideoProxy);
      const primarySrc = mediaUrlWithAuth(
        useProxy
          ? `/api/photo/${encodeURIComponent(photo.hash)}/video-proxy`
          : `/api/photo/${encodeURIComponent(photo.hash)}`
      );
      vid.src = primarySrc;
      vid.onloadeddata = () => {
        spinner.classList.add('hidden');
        vid.classList.remove('hidden');
      };
      vid.onerror = () => {
        if (useProxy) {
          vid.onerror = () => {
            spinner.classList.add('hidden');
            showToast('Could not play video in browser. Use Original download.', 'rose');
          };
          vid.src = mediaUrlWithAuth(`/api/photo/${encodeURIComponent(photo.hash)}`);
        } else {
          spinner.classList.add('hidden');
          showToast('Video codec not playable in browser — tap Original to download.', 'amber');
        }
      };
      return;
    }

    try {
      const res = await apiFetch(`/api/photo/${encodeURIComponent(photo.hash)}/preview`);
      if (!res.ok) throw new Error('Preview unavailable');
      const blob = await res.blob();
      if (state.visibleFlatPhotos[state.lightboxIndex]?.hash !== photo.hash) return;
      const objUrl = URL.createObjectURL(blob);
      state.lightboxBlobUrl = objUrl;
      const img = $('lbImage');
      img.src = objUrl;
      img.onload = () => {
        spinner.classList.add('hidden');
        img.classList.remove('hidden');
      };
    } catch {
      spinner.classList.add('hidden');
      showToast('Preview not available — tap Original to download.', 'amber');
    }
  }

  async function downloadLightboxOriginal() {
    const photo = state.visibleFlatPhotos[state.lightboxIndex];
    if (!photo) return;
    const dlBar = $('lbDownloadBar');
    const dlFill = $('lbDownloadFill');
    const dlText = $('lbDownloadText');
    dlBar.classList.remove('hidden');
    dlFill.style.width = '4%';
    dlText.textContent = `Fetching ${photo.originalName}…`;

    try {
      const res = await apiFetch(`/api/photo/${encodeURIComponent(photo.hash)}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const total = Number(res.headers.get('Content-Length')) || Number(photo.size) || 0;
      let blob;
      if (res.body && typeof res.body.getReader === 'function') {
        const reader = res.body.getReader();
        const chunks = [];
        let received = 0;
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          if (value) {
            chunks.push(value);
            received += value.byteLength;
            if (total > 0) {
              const pct = Math.min(100, Math.round((received / total) * 100));
              dlFill.style.width = `${pct}%`;
              dlText.textContent = `${formatBytes(received)} / ${formatBytes(total)} (${pct}%)`;
            } else {
              dlText.textContent = `Downloaded ${formatBytes(received)}…`;
            }
          }
        }
        blob = new Blob(chunks, { type: res.headers.get('Content-Type') || 'application/octet-stream' });
      } else {
        blob = await res.blob();
      }

      dlFill.style.width = '100%';
      const blobUrl = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = blobUrl;
      a.download = photo.originalName || `${photo.hash.slice(0, 12)}.bin`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(blobUrl), 5000);
      showToast(`Downloaded ${photo.originalName}`, 'mint');
    } catch (err) {
      showToast(`Download failed: ${err.message}`, 'rose');
    } finally {
      setTimeout(() => dlBar.classList.add('hidden'), 900);
    }
  }

  async function toggleLightboxProtect() {
    const photo = state.visibleFlatPhotos[state.lightboxIndex];
    if (!photo) return;
    const nextProtected = !photo.keepOriginalOnDevice;
    try {
      const res = await apiFetch(`/api/photo/${encodeURIComponent(photo.hash)}/protect-original`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ keepOriginalOnDevice: nextProtected }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Update failed');
      photo.keepOriginalOnDevice = nextProtected;
      state.photosEtag = null;
      renderLightboxItem();
      renderGallery();
      showToast(nextProtected ? 'Protected from auto re-compression' : 'Unprotected original', 'mint');
    } catch (err) {
      showToast(err.message || 'Could not update protection', 'rose');
    }
  }

  // ==================== INTERACTIVE SHOWCASE CONTROLS ====================
  function initShowcaseInteractions() {
    const platformData = {
      ios: {
        title: 'iPhone Auto Backup',
        sub: 'URLSession.background · Lock-screen safe',
        share: 'Share Original',
      },
      android: {
        title: 'Android Auto Backup',
        sub: 'WorkManager · 3× parallel uploads',
        share: 'Gallery Share + Picker',
      },
    };

    document.querySelectorAll('[data-platform]').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-platform]').forEach((b) => {
          const active = b === btn;
          b.classList.toggle('is-active', active);
          b.setAttribute('aria-selected', String(active));
        });
        const info = platformData[btn.dataset.platform] || platformData.ios;
        $('mockPlatformTitle').textContent = info.title;
        $('mockPlatformSub').textContent = info.sub;
        $('mockShareBadge').textContent = info.share;
      });
    });

    const presetStats = {
      smallest: { size: '7.6 GB', pct: 6, note: '~94% freed · Originals safe on server' },
      balance: { size: '11.5 GB', pct: 9, note: '~91% freed · Originals safe on server' },
      high: { size: '21.8 GB', pct: 17, note: '~83% freed · Crisp previews + safe originals' },
    };

    document.querySelectorAll('#savingsPresetPills .q-pill').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('#savingsPresetPills .q-pill').forEach((b) => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        const info = presetStats[btn.dataset.preset] || presetStats.balance;
        $('savingsResultText').textContent = info.size;
        $('savingsFillBar').style.width = `${info.pct}%`;
        $('savingsSavedBadge').textContent = info.note;
      });
    });

    // Scroll reveal animation
    const revealObs = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            e.target.classList.add('is-visible');
            revealObs.unobserve(e.target);
          }
        }
      },
      { threshold: 0.1 }
    );
    document.querySelectorAll('.reveal').forEach((el) => revealObs.observe(el));
  }

  // ==================== WIRE EVENTS & BOOT ====================
  function bindEvents() {
    $('themeToggleBtn').addEventListener('click', toggleTheme);
    $('brandHomeBtn').addEventListener('click', (e) => {
      e.preventDefault();
      switchView(state.session ? 'gallery' : 'landing');
    });
    $('tabGuideBtn').addEventListener('click', () => switchView('landing'));
    $('tabGalleryBtn').addEventListener('click', () => switchView('gallery'));
    $('navSignInBtn').addEventListener('click', () => openLoginModal());
    $('heroSignInBtn').addEventListener('click', () => {
      if (state.session) switchView('gallery');
      else openLoginModal();
    });
    $('navUserChip').addEventListener('click', () => switchView('gallery'));
    $('navSignOutBtn').addEventListener('click', () => signOut(true));

    // Login modal (Google Login only)
    $('closeLoginModalBtn').addEventListener('click', closeLoginModal);
    $('loginModal').addEventListener('click', (e) => {
      if (e.target === $('loginModal')) closeLoginModal();
    });
    $('googleSignInBtn').addEventListener('click', startGoogleLogin);

    // Gallery toolbar
    document.querySelectorAll('#mediaFilterPills .f-pill').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('#mediaFilterPills .f-pill').forEach((b) => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.filterMedia = btn.dataset.filter;
        renderGallery();
      });
    });

    document.querySelectorAll('#groupingControl .seg-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('#groupingControl .seg-btn').forEach((b) => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.grouping = btn.dataset.group;
        renderGallery();
      });
    });

    let searchTimer = null;
    $('gallerySearchInput').addEventListener('input', (e) => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => {
        state.searchQuery = e.target.value || '';
        renderGallery();
      }, 140);
    });

    $('selectModeBtn').addEventListener('click', () => toggleSelectionMode());
    $('cancelSelectBtn').addEventListener('click', () => toggleSelectionMode(false));
    $('selectAllVisibleBtn').addEventListener('click', () => {
      for (const p of state.visibleFlatPhotos) state.selectedHashes.add(p.hash.toLowerCase());
      updateSelectionBar();
      renderGallery();
    });
    $('deleteSelectedBtn').addEventListener('click', () => {
      const hashes = Array.from(state.selectedHashes);
      if (hashes.length === 0) return;
      openConfirmModal(
        `Delete ${hashes.length} item(s)?`,
        'This permanently deletes the originals and proxies from your server.',
        () => deletePhotosOnServer(hashes)
      );
    });
    $('refreshGalleryBtn').addEventListener('click', () => loadGallery(true));
    $('emptyRetryBtn').addEventListener('click', () => loadGallery(true));

    // Confirm modal
    $('confirmCancelBtn').addEventListener('click', closeConfirmModal);
    $('confirmModal').addEventListener('click', (e) => {
      if (e.target === $('confirmModal')) closeConfirmModal();
    });
    $('confirmOkBtn').addEventListener('click', async () => {
      const cb = state.confirmCallback;
      closeConfirmModal();
      if (cb) await cb();
    });

    // Lightbox controls + keyboard + swipe
    $('lbCloseBtn').addEventListener('click', closeLightbox);
    $('lbPrevBtn').addEventListener('click', () => {
      if (state.lightboxIndex > 0) {
        state.lightboxIndex--;
        renderLightboxItem();
      }
    });
    $('lbNextBtn').addEventListener('click', () => {
      if (state.lightboxIndex < state.visibleFlatPhotos.length - 1) {
        state.lightboxIndex++;
        renderLightboxItem();
      }
    });
    $('lbDownloadBtn').addEventListener('click', downloadLightboxOriginal);
    $('lbProtectBtn').addEventListener('click', toggleLightboxProtect);
    $('lbDeleteBtn').addEventListener('click', () => {
      const photo = state.visibleFlatPhotos[state.lightboxIndex];
      if (!photo) return;
      openConfirmModal(
        `Delete ${photo.originalName}?`,
        'This permanently deletes the original and compressed proxy from your server.',
        async () => {
          closeLightbox();
          await deletePhotosOnServer([photo.hash]);
        }
      );
    });

    document.addEventListener('keydown', (e) => {
      if ($('lightbox').classList.contains('hidden')) return;
      if (e.key === 'Escape') closeLightbox();
      else if (e.key === 'ArrowLeft' && state.lightboxIndex > 0) {
        state.lightboxIndex--;
        renderLightboxItem();
      } else if (e.key === 'ArrowRight' && state.lightboxIndex < state.visibleFlatPhotos.length - 1) {
        state.lightboxIndex++;
        renderLightboxItem();
      }
    });

    let touchStartX = 0;
    $('lbStage').addEventListener('touchstart', (e) => {
      touchStartX = e.changedTouches[0].clientX;
    }, { passive: true });
    $('lbStage').addEventListener('touchend', (e) => {
      const dx = e.changedTouches[0].clientX - touchStartX;
      if (Math.abs(dx) < 48) return;
      if (dx > 0 && state.lightboxIndex > 0) {
        state.lightboxIndex--;
        renderLightboxItem();
      } else if (dx < 0 && state.lightboxIndex < state.visibleFlatPhotos.length - 1) {
        state.lightboxIndex++;
        renderLightboxItem();
      }
    }, { passive: true });

    loadMoreObserver.observe($('loadMoreWrap'));
  }

  async function boot() {
    const bootStart = performance.now();
    initTheme();
    hydrateSunnyMascots();
    initShowcaseInteractions();
    bindEvents();

    // 1. Fetch public server capabilities (/api/auth/config)
    try {
      const cfgRes = await fetch('/api/auth/config');
      if (cfgRes.ok) {
        const cfg = await cfgRes.json();
        state.serverConfig = {
          googleEnabled: Boolean(cfg.googleEnabled),
          s3Enabled: Boolean(cfg.s3Enabled),
        };
        const pill = $('navServerPill');
        pill.classList.add('is-online');
        $('navServerLabel').textContent = state.serverConfig.s3Enabled ? 'Online · S3' : 'Online · Direct';
        $('heroStorageModePill').textContent = state.serverConfig.s3Enabled ? 'Auto · S3 Storage' : 'Auto · Direct VPS';
        $('mockUploadBadge').textContent = state.serverConfig.s3Enabled ? 'Auto · S3' : 'Auto · Direct';
      }
    } catch {
      $('navServerLabel').textContent = 'Offline';
    }

    // 2. Complete OAuth PKCE callback if returning from Google, or restore saved session
    const justLoggedIn = await handleOAuthCallbackIfPresent();
    if (!justLoggedIn) {
      state.session = loadStoredSession();
    }

    if (state.session) {
      $('splashStatusText').textContent = 'Syncing your gallery…';
      const check = await verifySession();
      if (check.unauthorized) {
        saveSession(null);
      } else if (!check.ok && check.error) {
        showToast(check.error, 'amber');
      }
    }

    updateAuthUI();

    const wantGallery =
      justLoggedIn ||
      window.location.pathname === '/gallery' ||
      (Boolean(state.session) && window.location.pathname !== '/about');
    if (wantGallery && state.session) {
      switchView('gallery');
    } else {
      switchView('landing');
    }

    // Ensure the signature Sunny loading animation plays cleanly without abrupt flicker (~480ms min)
    const elapsed = performance.now() - bootStart;
    const minSplashMs = 480;
    setTimeout(() => {
      $('splashLoader').classList.add('is-done');
    }, Math.max(0, minSplashMs - elapsed));
  }

  document.addEventListener('DOMContentLoaded', boot);
})();
