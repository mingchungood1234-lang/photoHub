(() => {
  'use strict';

  const SESSION_KEY = 'photohub_web_session_v1';
  const PKCE_KEY = 'photohub_web_pkce_v1';
  const THEME_KEY = 'photohub_web_theme_v1';
  const CHUNK_RESUME_KEY = 'photohub_chunked_resume_v1';
  const CHUNKED_THRESHOLD_BYTES = 16 * 1024 * 1024; // Files >= 16 MB use resumable chunked 4K uploads
  const CHUNK_SIZE_BYTES = 5 * 1024 * 1024; // 5 MB parts
  const VIDEO_EXTS = new Set(['mov', 'mp4', 'm4v', '3gp', 'avi']);

  // ==================== STATE ====================
  const state = {
    serverConfig: {
      googleEnabled: false,
    },
    session: null, // { token, serverUrl, authMode, user }
    whoami: null,
    activeView: 'landing', // 'landing' | 'gallery'
    photos: [],
    protectedPhotos: [],
    protectedCount: 0,
    isLoadingProtected: false,
    protectedLoadedOnce: false,
    protectedLoadSeq: 0,
    favoritePhotos: [],
    favoriteCount: 0,
    isLoadingFavorites: false,
    favoriteLoadedOnce: false,
    favoriteLoadSeq: 0,
    trashPhotos: [],
    trashCount: 0,
    isLoadingTrash: false,
    trashLoadSeq: 0,
    isMutatingProtection: false,
    lastAutoSyncMs: 0,
    years: [],
    totalPhotos: 0,
    hasMore: false,
    isLoadingPhotos: false,
    isLoadingMore: false,
    photosEtag: null,
    filterMedia: 'all', // 'all' | 'photo' | 'video' | 'favorite' | 'albums' | 'map' | 'protected' | 'trash'
    grouping: 'day', // 'day' | 'month' | 'year'
    searchQuery: '',
    selectedYear: null,
    isSelectionMode: false,
    selectedHashes: new Set(),
    lastSelectedIndex: -1,
    visibleFlatPhotos: [],
    lightboxIndex: -1,
    lightboxBlobUrl: null,
    lightboxZoom: 1,
    lightboxPanX: 0,
    lightboxPanY: 0,
    shareTargetHashes: [],
    shareAlbumId: null,
    activeShares: [],
    albums: [],
    albumCategoryFilter: 'all',
    activeAlbum: null,
    activeAlbumPhotos: [],
    editingAlbumId: null,
    albumPickerHashes: [],
    mapData: null,
    selectedMapClusterId: null,
    selectedMapFilter: null,
    mapProvider: 'leaflet', // 'leaflet' | 'google'
    mapProviderUserChosen: false,
    mapStyle: 'street', // 'street' | 'satellite' | 'osm'
    mapHasFittedOnce: false,
    cleanupReport: null,
    cleanupTab: 'similar',
    cleanupSelectedHashes: new Set(),
    confirmCallback: null,
  };

  // Bounded LRU cache for preloaded lightbox full previews (eliminates spinner flash on swipe/next)
  const MAX_LB_CACHE = 24;
  const lbPreviewCache = new Map(); // hash -> objectURL
  const lbPreviewInFlight = new Map(); // hash -> Promise<string|null>

  const MONTH_SEARCH_NAMES = [
    ['january', 'jan'],
    ['february', 'feb'],
    ['march', 'mar'],
    ['april', 'apr'],
    ['may'],
    ['june', 'jun'],
    ['july', 'jul'],
    ['august', 'aug'],
    ['september', 'sept', 'sep'],
    ['october', 'oct'],
    ['november', 'nov'],
    ['december', 'dec'],
  ];

  // Two-tier grid thumbnail cache:
  //   L1: Bounded RAM LRU ObjectURL cache (instant synchronous hits on re-renders)
  //   L2: Persistent Browser Cache Storage API (instant 1-3ms hits across reloads, zero server traffic)
  const MAX_THUMB_CACHE = 800;
  const THUMB_DISK_CACHE_NAME = 'photohub-thumbs-v1';
  const MAX_THUMB_DISK_ENTRIES = 2500;
  const thumbUrlCache = new Map(); // hash -> objectURL
  const thumbInFlight = new Map(); // hash -> Promise<string|null>
  const thumbAbortControllers = new Map(); // hash -> AbortController
  const visibleThumbTiles = new Set(); // currently-intersecting tile elements
  let thumbDiskCachePromise = null;
  let thumbDiskWriteCount = 0;
  let activeThumbFetches = 0;
  const MAX_CONCURRENT_THUMBS = 10;
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
    if (typeof syncMapTheme === 'function') syncMapTheme();
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
        (state.whoami && (state.whoami.name || state.whoami.email)) ||
        (state.session.user && (state.session.user.name || state.session.user.email)) ||
        'PhotoHub User';
      $('navUserName').textContent = displayName;
      $('navUserInitial').textContent = String(displayName).trim().charAt(0).toUpperCase() || 'P';
      $('galleryGreeting').textContent =
        state.whoami && state.whoami.name ? `Hi, ${state.whoami.name.split(' ')[0]}` : 'Your Cloud Photos';
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

  function clearLbPreviewCache() {
    for (const url of lbPreviewCache.values()) {
      URL.revokeObjectURL(url);
    }
    lbPreviewCache.clear();
    lbPreviewInFlight.clear();
  }

  function fetchLightboxPreviewCached(hash) {
    if (!hash) return Promise.resolve(null);
    if (lbPreviewCache.has(hash)) {
      const url = lbPreviewCache.get(hash);
      lbPreviewCache.delete(hash);
      lbPreviewCache.set(hash, url);
      return Promise.resolve(url);
    }
    if (lbPreviewInFlight.has(hash)) {
      return lbPreviewInFlight.get(hash);
    }
    const p = apiFetch(`/api/photo/${encodeURIComponent(hash)}/preview`)
      .then((res) => (res.ok ? res.blob() : null))
      .then((blob) => {
        if (!blob || blob.size === 0) return null;
        const objUrl = URL.createObjectURL(blob);
        lbPreviewCache.set(hash, objUrl);
        if (lbPreviewCache.size > MAX_LB_CACHE) {
          const oldest = lbPreviewCache.keys().next().value;
          const oldUrl = lbPreviewCache.get(oldest);
          lbPreviewCache.delete(oldest);
          if (oldUrl) URL.revokeObjectURL(oldUrl);
        }
        return objUrl;
      })
      .catch(() => null)
      .finally(() => {
        lbPreviewInFlight.delete(hash);
      });
    lbPreviewInFlight.set(hash, p);
    return p;
  }

  function preloadAdjacentLightboxItems(index) {
    for (const delta of [1, -1, 2, -2]) {
      const neighbor = state.visibleFlatPhotos[index + delta];
      if (neighbor && !isVideoPhoto(neighbor)) {
        fetchLightboxPreviewCached(neighbor.hash);
      }
    }
  }

  function signOut(notify = true) {
    saveSession(null);
    state.whoami = null;
    state.photos = [];
    state.protectedPhotos = [];
    state.protectedCount = 0;
    state.protectedLoadedOnce = false;
    state.trashPhotos = [];
    state.trashCount = 0;
    state.years = [];
    state.albums = [];
    state.activeAlbum = null;
    state.activeAlbumPhotos = [];
    state.mapData = null;
    state.selectedMapClusterId = null;
    state.selectedMapFilter = null;
    state.mapHasFittedOnce = false;
    clearActiveMapMarkers();
    state.activeShares = [];
    state.cleanupReport = null;
    state.photosEtag = null;
    state.protectedPhotos = [];
    state.protectedCount = 0;
    state.protectedLoadedOnce = false;
    state.favoritePhotos = [];
    state.favoriteCount = 0;
    state.favoriteLoadedOnce = false;
    state.trashPhotos = [];
    state.trashCount = 0;
    state.isMutatingProtection = false;
    state.selectedHashes.clear();
    state.lastSelectedIndex = -1;
    state.isSelectionMode = false;
    clearThumbCache({ clearDisk: true });
    clearLbPreviewCache();
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
  async function loadGallery(forceSync = false, { silent = false } = {}) {
    if (!state.session || state.isLoadingPhotos) return false;
    state.isLoadingPhotos = true;
    const refreshSvg = $('refreshGalleryBtn')?.querySelector('.refresh-svg');
    if (!silent && refreshSvg) refreshSvg.classList.add('is-spinning');
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
      state.lastAutoSyncMs = Date.now();
      if (res.status === 304) {
        if (!silent) renderGallery();
        return false;
      }
      if (!res.ok) throw new Error(`Server returned HTTP ${res.status}`);
      const etag = res.headers.get('ETag');
      if (etag && !state.selectedYear) state.photosEtag = etag;

      const data = await res.json();
      state.photos = Array.isArray(data.photos) ? data.photos : [];
      state.totalPhotos = Number(data.total) || state.photos.length;
      state.trashCount = Number(data.trashCount) || 0;
      state.protectedCount =
        typeof data.protectedCount === 'number'
          ? data.protectedCount
          : state.photos.filter((p) => Boolean(p.keepOriginalOnDevice)).length;
      state.favoriteCount =
        typeof data.favoriteCount === 'number'
          ? data.favoriteCount
          : state.photos.filter((p) => Boolean(p.isFavorite)).length;
      state.hasMore = Boolean(data.hasMore);
      updateTrashBadge();
      updateProtectedBadge();
      updateFavoriteBadge();
      if (Array.isArray(data.years)) {
        state.years = data.years;
        renderYearPills();
      }

      // Server index changed (e.g. from phone client): refresh whichever category view is open!
      if (state.filterMedia === 'protected' && !state.isMutatingProtection) {
        loadProtectedPhotos({ silent: true });
      } else if (state.filterMedia === 'favorite') {
        loadFavoritePhotos({ silent: true });
      } else if (state.filterMedia === 'trash') {
        loadTrash({ silent: true });
      } else if (state.filterMedia === 'albums') {
        loadAlbums();
        if (state.activeAlbum) openAlbumDetail(state.activeAlbum.id);
      } else if (state.filterMedia === 'map') {
        loadPhotoMap();
      } else {
        // Mark category caches dirty so switching to them fetches fresh server data
        state.protectedLoadedOnce = false;
        state.favoriteLoadedOnce = false;
      }

      renderGallery();
      if (!silent) {
        verifySession();
      }
      return true;
    } catch (err) {
      if (silent) return false;
      if (state.photos.length === 0) {
        $('galleryEmptyState').classList.remove('hidden');
        setMascotMood($('emptyStateMascot'), 'alert');
        $('emptyStateTitle').textContent = 'Could Not Load Photos';
        $('emptyStateText').textContent = err.message || 'Check your connection and retry.';
      } else {
        showToast(err.message || 'Refresh failed', 'rose');
      }
      return false;
    } finally {
      state.isLoadingPhotos = false;
      $('gallerySkeleton').classList.add('hidden');
      if (refreshSvg) refreshSvg.classList.remove('is-spinning');
    }
  }

  async function syncGalleryFromServerIfChanged({ force = false } = {}) {
    if (!state.session || state.activeView !== 'gallery') return;
    if (state.isLoadingPhotos || state.isMutatingProtection || uploadState.isRunning) return;
    const now = Date.now();
    if (!force && now - state.lastAutoSyncMs < 5000) return;
    await loadGallery(false, { silent: true });
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

  function updateTrashBadge() {
    const badge = $('trashCountBadge');
    if (!badge) return;
    if (state.trashCount > 0) {
      badge.textContent = String(state.trashCount);
      badge.classList.remove('hidden');
    } else {
      badge.classList.add('hidden');
    }
  }

  function updateProtectedBadge() {
    const badge = $('protectedCountBadge');
    if (!badge) return;
    if (state.protectedCount > 0) {
      badge.textContent = String(state.protectedCount);
      badge.classList.remove('hidden');
    } else {
      badge.classList.add('hidden');
    }
  }

  function updateFavoriteBadge() {
    const badge = $('favoriteCountBadge');
    if (!badge) return;
    if (state.favoriteCount > 0) {
      badge.textContent = String(state.favoriteCount);
      badge.classList.remove('hidden');
    } else {
      badge.classList.add('hidden');
    }
  }

  function applyServerCategoryCounts(data) {
    if (!data || typeof data !== 'object') return;
    if (typeof data.protectedCount === 'number') {
      state.protectedCount = Math.max(0, data.protectedCount);
      updateProtectedBadge();
    }
    if (typeof data.favoriteCount === 'number') {
      state.favoriteCount = Math.max(0, data.favoriteCount);
      updateFavoriteBadge();
    }
    if (typeof data.trashCount === 'number') {
      state.trashCount = Math.max(0, data.trashCount);
      updateTrashBadge();
    }
  }

  function updateProtectedBannerUI(progressMessage = null) {
    const list = state.protectedLoadedOnce
      ? state.protectedPhotos
      : state.photos.filter((p) => Boolean(p.keepOriginalOnDevice));
    const totalBytes = list.reduce((sum, p) => sum + (Number(p.size) || 0), 0);
    const sub = $('protectedBannerSub');
    if (sub) {
      if (progressMessage) {
        sub.textContent = progressMessage;
      } else {
        sub.textContent =
          list.length > 0
            ? `${list.length} protected original(s) (${formatBytes(totalBytes)}) · Won't be auto-compressed into proxies on your phone.`
            : 'No protected originals yet. Restored or protected photos appear here so they stay full-resolution on your phone.';
      }
    }
    const busy = Boolean(state.isMutatingProtection);
    const selAllBtn = $('selectAllProtectedBtn');
    const unlockAllBtn = $('allowReproxyAllProtectedBtn');
    if (selAllBtn) selAllBtn.disabled = busy || list.length === 0;
    if (unlockAllBtn) {
      unlockAllBtn.disabled = busy || list.length === 0;
      if (!busy) unlockAllBtn.textContent = 'Allow Re-Proxy All';
    }
  }

  async function loadProtectedPhotos({ silent = false } = {}) {
    if (!state.session) return;
    const mySeq = ++state.protectedLoadSeq;
    state.isLoadingProtected = true;
    const sub = $('protectedBannerSub');
    if (!silent && sub && !state.protectedLoadedOnce) {
      sub.textContent = 'Loading all protected originals from server…';
    }
    try {
      const collected = [];
      const seen = new Set();
      let offset = 0;
      const limit = 1000;
      let serverMeta = null;
      while (true) {
        const res = await apiFetch(`/api/photos?protected=1&limit=${limit}&offset=${offset}`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        if (mySeq !== state.protectedLoadSeq) return;
        serverMeta = data;
        const page = Array.isArray(data.photos) ? data.photos : [];
        for (const p of page) {
          if (!p || !p.keepOriginalOnDevice) continue;
          const k = String(p.hash || '').toLowerCase();
          if (k && !seen.has(k)) {
            seen.add(k);
            collected.push(p);
          }
        }
        offset += page.length;
        if (!data.hasMore || page.length === 0) break;
      }
      if (mySeq !== state.protectedLoadSeq) return;
      state.protectedPhotos = collected;
      state.protectedLoadedOnce = true;
      // Reconcile keepOriginalOnDevice across already-loaded main/favorite/album arrays too
      const protectedSet = seen;
      for (const list of [state.photos, state.favoritePhotos, state.activeAlbumPhotos]) {
        for (const p of list) {
          const k = String(p.hash || '').toLowerCase();
          p.keepOriginalOnDevice = protectedSet.has(k);
        }
      }
      state.protectedCount =
        serverMeta && typeof serverMeta.protectedCount === 'number'
          ? serverMeta.protectedCount
          : collected.length;
      if (serverMeta) applyServerCategoryCounts(serverMeta);
      updateProtectedBadge();
      updateProtectedBannerUI();
      renderGallery();
    } catch (err) {
      if (!silent && mySeq === state.protectedLoadSeq) {
        showToast(err.message || 'Could not load Protected photos', 'rose');
      }
    } finally {
      if (mySeq === state.protectedLoadSeq) {
        state.isLoadingProtected = false;
        if (state.filterMedia === 'protected') renderGallery();
      }
    }
  }

  async function loadFavoritePhotos({ silent = false } = {}) {
    if (!state.session) return;
    const mySeq = ++state.favoriteLoadSeq;
    state.isLoadingFavorites = true;
    try {
      const collected = [];
      const seen = new Set();
      let offset = 0;
      const limit = 1000;
      let serverMeta = null;
      while (true) {
        const res = await apiFetch(`/api/photos?favorite=1&limit=${limit}&offset=${offset}`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        if (mySeq !== state.favoriteLoadSeq) return;
        serverMeta = data;
        const page = Array.isArray(data.photos) ? data.photos : [];
        for (const p of page) {
          if (!p || !p.isFavorite) continue;
          const k = String(p.hash || '').toLowerCase();
          if (k && !seen.has(k)) {
            seen.add(k);
            collected.push(p);
          }
        }
        offset += page.length;
        if (!data.hasMore || page.length === 0) break;
      }
      if (mySeq !== state.favoriteLoadSeq) return;
      state.favoritePhotos = collected;
      state.favoriteLoadedOnce = true;
      for (const list of [state.photos, state.protectedPhotos, state.activeAlbumPhotos]) {
        for (const p of list) {
          const k = String(p.hash || '').toLowerCase();
          p.isFavorite = seen.has(k);
        }
      }
      state.favoriteCount =
        serverMeta && typeof serverMeta.favoriteCount === 'number'
          ? serverMeta.favoriteCount
          : collected.length;
      if (serverMeta) applyServerCategoryCounts(serverMeta);
      updateFavoriteBadge();
      renderGallery();
    } catch (err) {
      if (!silent && mySeq === state.favoriteLoadSeq) {
        showToast(err.message || 'Could not load Favorites', 'rose');
      }
    } finally {
      if (mySeq === state.favoriteLoadSeq) {
        state.isLoadingFavorites = false;
        if (state.filterMedia === 'favorite') renderGallery();
      }
    }
  }

  async function loadTrash({ silent = false } = {}) {
    if (!state.session) return;
    const mySeq = ++state.trashLoadSeq;
    state.isLoadingTrash = true;
    try {
      const res = await apiFetch('/api/photos/trash');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (mySeq !== state.trashLoadSeq) return;
      state.trashPhotos = Array.isArray(data.photos) ? data.photos : [];
      state.trashCount = Number(data.total) || state.trashPhotos.length;
      updateTrashBadge();
      $('trashBannerSub').textContent =
        state.trashPhotos.length > 0
          ? `${state.trashPhotos.length} item(s) (${formatBytes(data.trashBytes || 0)}) · Auto-deleted after ${data.retentionDays || 30} days.`
          : 'Trash is empty. Deleted items stay here for 30 days before permanent removal.';
      $('emptyTrashBtn').disabled = state.trashPhotos.length === 0;
      renderGallery();
    } catch (err) {
      if (!silent && mySeq === state.trashLoadSeq) {
        showToast(err.message || 'Could not load Trash', 'rose');
      }
    } finally {
      if (mySeq === state.trashLoadSeq) {
        state.isLoadingTrash = false;
      }
    }
  }

  function matchesSmartSearch(p, rawQuery) {
    const q = String(rawQuery || '').trim().toLowerCase();
    if (!q) return true;
    const tokens = q.split(/\s+/).filter(Boolean);
    if (tokens.length === 0) return true;
    const isVid = isVideoPhoto(p);
    const dateStr = String(p.photoDate || (p.takenAt || '').slice(0, 10) || (p.uploadedAt || '').slice(0, 10));
    const mo = /^\d{4}-(\d{2})/.test(dateStr) ? Number(dateStr.slice(5, 7)) : 0;
    const moNames = mo >= 1 && mo <= 12 ? MONTH_SEARCH_NAMES[mo - 1] : [];
    const hay = [
      p.originalName || '',
      p.photoDate || '',
      p.takenAt || '',
      p.savedPath || '',
      p.cameraModel || '',
      p.locationLabel || '',
      typeof p.gpsLat === 'number' && typeof p.gpsLng === 'number'
        ? `${p.gpsLat.toFixed(2)},${p.gpsLng.toFixed(2)} gps map location`
        : '',
      ...moNames,
      isVid ? 'video videos movie clip' : 'photo photos image picture',
      p.isFavorite ? 'favorite favorites fav starred heart' : '',
      p.keepOriginalOnDevice ? 'protected restored original' : '',
    ]
      .join(' ')
      .toLowerCase();
    return tokens.every((tok) => hay.includes(tok));
  }

  function filteredPhotos() {
    if (state.filterMedia === 'albums') {
      if (!state.activeAlbum) return [];
      return state.activeAlbumPhotos.filter(
        (p) => !state.searchQuery || matchesSmartSearch(p, state.searchQuery)
      );
    }
    if (state.filterMedia === 'map') {
      let list = (state.mapData && Array.isArray(state.mapData.photos) ? state.mapData.photos : []).slice();
      if (state.selectedMapFilter && state.selectedMapFilter.hashes && state.selectedMapFilter.hashes.size > 0) {
        const allowed = state.selectedMapFilter.hashes;
        list = list.filter((p) => allowed.has(String(p.hash).toLowerCase()));
      } else if (state.selectedMapClusterId && state.mapData && Array.isArray(state.mapData.clusters)) {
        const cl = state.mapData.clusters.find((c) => c.id === state.selectedMapClusterId);
        if (cl) {
          const allowed = new Set(cl.hashes.map((h) => String(h).toLowerCase()));
          list = list.filter((p) => allowed.has(String(p.hash).toLowerCase()));
        }
      }
      return list.filter((p) => !state.searchQuery || matchesSmartSearch(p, state.searchQuery));
    }
    if (state.filterMedia === 'protected') {
      const base = state.protectedLoadedOnce
        ? state.protectedPhotos
        : state.photos.filter((p) => Boolean(p.keepOriginalOnDevice));
      return base.filter((p) => {
        if (!p.keepOriginalOnDevice) return false;
        if (state.selectedYear) {
          const rawDate = String(p.photoDate || p.takenAt || p.uploadedAt || '');
          const match = /^(\d{4})/.exec(rawDate);
          const itemYear = match ? Number(match[1]) : null;
          if (itemYear !== Number(state.selectedYear)) return false;
        }
        if (state.searchQuery && !matchesSmartSearch(p, state.searchQuery)) return false;
        return true;
      });
    }
    if (state.filterMedia === 'favorite') {
      const base = state.favoriteLoadedOnce
        ? state.favoritePhotos
        : state.photos.filter((p) => Boolean(p.isFavorite));
      return base.filter((p) => {
        if (!p.isFavorite) return false;
        if (state.selectedYear) {
          const rawDate = String(p.photoDate || p.takenAt || p.uploadedAt || '');
          const match = /^(\d{4})/.exec(rawDate);
          const itemYear = match ? Number(match[1]) : null;
          if (itemYear !== Number(state.selectedYear)) return false;
        }
        if (state.searchQuery && !matchesSmartSearch(p, state.searchQuery)) return false;
        return true;
      });
    }
    const isTrash = state.filterMedia === 'trash';
    const source = isTrash ? state.trashPhotos : state.photos;
    return source.filter((p) => {
      const isVid = isVideoPhoto(p);
      if (state.filterMedia === 'photo' && isVid) return false;
      if (state.filterMedia === 'video' && !isVid) return false;
      if (state.searchQuery && !matchesSmartSearch(p, state.searchQuery)) return false;
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

  // ==================== TWO-TIER THUMBNAIL CACHE & VIEWPORT-FIRST QUEUE ====================
  function getThumbSessionScope() {
    const email = (state.whoami && state.whoami.email) || (state.session && state.session.user && state.session.user.email) || '';
    const node = (state.session && state.session.nodeId) || 'primary';
    const raw = `${email || 'user'}_${node}`.toLowerCase().replace(/[^a-z0-9_-]/g, '_');
    return raw || 'default';
  }

  function getThumbDiskCacheRequest(hash) {
    return `${window.location.origin}/__photohub_thumb__/${getThumbSessionScope()}/${encodeURIComponent(hash)}?size=thumb`;
  }

  function openThumbDiskCache() {
    if (typeof window === 'undefined' || !('caches' in window)) {
      return Promise.resolve(null);
    }
    if (!thumbDiskCachePromise) {
      thumbDiskCachePromise = window.caches
        .open(THUMB_DISK_CACHE_NAME)
        .catch(() => null);
    }
    return thumbDiskCachePromise;
  }

  async function readThumbFromDiskCache(hash) {
    try {
      const cache = await openThumbDiskCache();
      if (!cache) return null;
      const res = await cache.match(getThumbDiskCacheRequest(hash));
      if (!res || !res.ok) return null;
      const blob = await res.blob();
      if (!blob || blob.size === 0) return null;
      const objUrl = URL.createObjectURL(blob);
      rememberThumbUrl(hash, objUrl);
      return objUrl;
    } catch {
      return null;
    }
  }

  function writeThumbToDiskCache(hash, responseClone) {
    if (!responseClone) return;
    openThumbDiskCache()
      .then(async (cache) => {
        if (!cache) return;
        await cache.put(getThumbDiskCacheRequest(hash), responseClone);
        thumbDiskWriteCount += 1;
        if (thumbDiskWriteCount % 120 === 0) {
          const keys = await cache.keys();
          if (keys.length > MAX_THUMB_DISK_ENTRIES) {
            const toDelete = keys.slice(0, keys.length - MAX_THUMB_DISK_ENTRIES);
            await Promise.all(toDelete.map((k) => cache.delete(k).catch(() => {})));
          }
        }
      })
      .catch(() => {});
  }

  // Lazy Thumbnail IntersectionObserver (tracks viewport visibility for LIFO visible-first priority)
  const thumbObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const tile = entry.target;
        if (entry.isIntersecting) {
          visibleThumbTiles.add(tile);
          if (tile.dataset.thumbLoaded === '1') {
            thumbObserver.unobserve(tile);
            visibleThumbTiles.delete(tile);
            continue;
          }
          const hash = tile.dataset.hash;
          const isVid = tile.dataset.video === '1';
          const needsProxy = tile.dataset.needsProxy === '1';
          if (hash) {
            queueThumbnailLoad(tile, hash, isVid, needsProxy);
          }
        } else {
          visibleThumbTiles.delete(tile);
        }
      }
    },
    { rootMargin: '420px 0px' }
  );

  function cancelStaleThumbFetches() {
    // Drop queued tiles that were detached from DOM during view/filter switches
    for (let i = thumbFetchQueue.length - 1; i >= 0; i--) {
      if (!thumbFetchQueue[i] || !thumbFetchQueue[i].tile || !thumbFetchQueue[i].tile.isConnected) {
        thumbFetchQueue.splice(i, 1);
      }
    }
    for (const tile of Array.from(visibleThumbTiles)) {
      if (!tile.isConnected) visibleThumbTiles.delete(tile);
    }
    // Abort in-flight grid fetches whose hashes are no longer mounted in the current view
    for (const [hash, ctrl] of Array.from(thumbAbortControllers.entries())) {
      const stillMounted = Boolean(
        document.querySelector(`.photo-tile[data-hash="${CSS.escape(hash)}"]`)
      );
      if (!stillMounted) {
        try {
          ctrl.abort();
        } catch {
          // ignore
        }
        thumbAbortControllers.delete(hash);
      }
    }
  }

  function clearThumbCache({ clearDisk = false } = {}) {
    for (const ctrl of thumbAbortControllers.values()) {
      try {
        ctrl.abort();
      } catch {
        // ignore
      }
    }
    thumbAbortControllers.clear();
    for (const url of thumbUrlCache.values()) {
      URL.revokeObjectURL(url);
    }
    thumbUrlCache.clear();
    thumbInFlight.clear();
    visibleThumbTiles.clear();
    thumbFetchQueue.length = 0;
    if (clearDisk && typeof window !== 'undefined' && 'caches' in window) {
      thumbDiskCachePromise = null;
      window.caches.delete(THUMB_DISK_CACHE_NAME).catch(() => {});
    }
  }

  function rememberThumbUrl(hash, objectUrl) {
    if (thumbUrlCache.has(hash)) {
      const prev = thumbUrlCache.get(hash);
      thumbUrlCache.delete(hash);
      if (prev && prev !== objectUrl) {
        URL.revokeObjectURL(prev);
      }
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
    if (!tile || !url) return;
    tile.dataset.thumbLoaded = '1';
    visibleThumbTiles.delete(tile);
    thumbObserver.unobserve(tile);
    const img = tile.querySelector('img');
    const shimmer = tile.querySelector('.photo-tile-shimmer');
    if (img) {
      if (img.src !== url) img.src = url;
      if (img.complete && img.naturalWidth > 0) {
        img.classList.add('is-loaded');
        if (shimmer) shimmer.remove();
      } else {
        img.onload = () => {
          img.classList.add('is-loaded');
          if (shimmer) shimmer.remove();
        };
      }
    }
  }

  function showTileFallback(tile, isVid) {
    if (!tile) return;
    tile.dataset.thumbLoaded = '1';
    visibleThumbTiles.delete(tile);
    thumbObserver.unobserve(tile);
    const shimmer = tile.querySelector('.photo-tile-shimmer');
    if (shimmer) shimmer.remove();
    if (tile.querySelector('.tile-placeholder')) return;
    const ph = document.createElement('div');
    ph.className = 'tile-placeholder';
    ph.innerHTML = isVid
      ? `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="24" height="24"><polygon points="5 3 19 12 5 21 5 3"/></svg><span>Video</span>`
      : `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="24" height="24"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg><span>Photo</span>`;
    tile.appendChild(ph);
  }

  /**
   * Shared deduplicated micro-thumbnail loader (L1 RAM -> L2 Browser Cache Storage -> Server `?size=thumb` WebP/JPEG).
   */
  function fetchThumbUrl(hash, { abortable = false } = {}) {
    if (!hash) return Promise.resolve(null);
    if (thumbUrlCache.has(hash)) {
      // Refresh LRU recency
      const hit = thumbUrlCache.get(hash);
      thumbUrlCache.delete(hash);
      thumbUrlCache.set(hash, hit);
      return Promise.resolve(hit);
    }
    if (thumbInFlight.has(hash)) {
      return thumbInFlight.get(hash);
    }

    const p = (async () => {
      // Check L2 persistent browser Cache Storage first (0 network latency on reload!)
      const diskHit = await readThumbFromDiskCache(hash);
      if (diskHit) return diskHit;

      const controller = abortable && typeof AbortController !== 'undefined' ? new AbortController() : null;
      if (controller) thumbAbortControllers.set(hash, controller);
      try {
        const res = await apiFetch(`/api/photo/${encodeURIComponent(hash)}/preview?size=thumb`, {
          headers: { Accept: 'image/webp,image/*,*/*;q=0.8' },
          ...(controller ? { signal: controller.signal } : {}),
        });
        if (!res.ok) return null;
        const cloneForDisk = res.clone();
        const blob = await res.blob();
        if (!blob || blob.size === 0) return null;
        writeThumbToDiskCache(hash, cloneForDisk);
        const objUrl = URL.createObjectURL(blob);
        rememberThumbUrl(hash, objUrl);
        return objUrl;
      } catch {
        return null;
      } finally {
        if (controller && thumbAbortControllers.get(hash) === controller) {
          thumbAbortControllers.delete(hash);
        }
      }
    })().finally(() => {
      thumbInFlight.delete(hash);
    });

    thumbInFlight.set(hash, p);
    return p;
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
    if (thumbInFlight.has(hash)) {
      thumbInFlight.get(hash).then((url) => {
        if (!tile.isConnected) return;
        if (url) applyThumbToTile(tile, url);
        else showTileFallback(tile, isVid);
      });
      return;
    }
    // Check L2 persistent Cache Storage without consuming a network concurrency slot
    if (typeof window !== 'undefined' && 'caches' in window) {
      readThumbFromDiskCache(hash).then((diskHit) => {
        if (!tile.isConnected) return;
        if (diskHit) {
          applyThumbToTile(tile, diskHit);
          return;
        }
        if (tile.dataset.thumbLoaded === '1') return;
        thumbFetchQueue.push({ tile, hash, isVid });
        drainThumbQueue();
      });
      return;
    }
    thumbFetchQueue.push({ tile, hash, isVid });
    drainThumbQueue();
  }

  function pickNextPriorityThumbJob() {
    // Prefer the most recently entered currently-visible tile (LIFO visible-first),
    // discarding detached tiles so fast scrolling loads what's on-screen NOW!
    for (let i = thumbFetchQueue.length - 1; i >= 0; i--) {
      const job = thumbFetchQueue[i];
      if (!job || !job.tile || !job.tile.isConnected || job.tile.dataset.thumbLoaded === '1') {
        thumbFetchQueue.splice(i, 1);
        continue;
      }
      if (visibleThumbTiles.has(job.tile)) {
        thumbFetchQueue.splice(i, 1);
        return job;
      }
    }
    while (thumbFetchQueue.length > 0) {
      const job = thumbFetchQueue.pop();
      if (job && job.tile && job.tile.isConnected && job.tile.dataset.thumbLoaded !== '1') {
        return job;
      }
    }
    return null;
  }

  function drainThumbQueue() {
    while (activeThumbFetches < MAX_CONCURRENT_THUMBS && thumbFetchQueue.length > 0) {
      const job = pickNextPriorityThumbJob();
      if (!job) break;
      if (thumbUrlCache.has(job.hash)) {
        applyThumbToTile(job.tile, thumbUrlCache.get(job.hash));
        continue;
      }
      if (thumbInFlight.has(job.hash)) {
        thumbInFlight.get(job.hash).then((url) => {
          if (!job.tile.isConnected) return;
          if (url) applyThumbToTile(job.tile, url);
          else showTileFallback(job.tile, job.isVid);
        });
        continue;
      }

      activeThumbFetches++;
      fetchThumbUrl(job.hash, { abortable: true })
        .then((objUrl) => {
          if (objUrl) {
            document
              .querySelectorAll(`.photo-tile[data-hash="${CSS.escape(job.hash)}"]`)
              .forEach((t) => applyThumbToTile(t, objUrl));
          } else if (job.tile.isConnected) {
            showTileFallback(job.tile, job.isVid);
          }
        })
        .catch(() => {
          if (job.tile.isConnected) showTileFallback(job.tile, job.isVid);
        })
        .finally(() => {
          activeThumbFetches--;
          drainThumbQueue();
        });
    }
  }

  function renderGallery() {
    const isTrashView = state.filterMedia === 'trash';
    const isProtectedView = state.filterMedia === 'protected';
    const isFavoriteView = state.filterMedia === 'favorite';
    const isAlbumsView = state.filterMedia === 'albums';
    const isMapView = state.filterMedia === 'map';

    $('trashBanner').classList.toggle('hidden', !isTrashView);
    $('protectedBanner').classList.toggle('hidden', !isProtectedView);
    $('albumsViewSection').classList.toggle('hidden', !isAlbumsView);
    $('mapViewSection').classList.toggle('hidden', !isMapView);
    if (isProtectedView && !state.isMutatingProtection) {
      updateProtectedBannerUI();
    }

    if (isAlbumsView) {
      $('albumsOverviewPane').classList.toggle('hidden', Boolean(state.activeAlbum));
      $('activeAlbumBanner').classList.toggle('hidden', !state.activeAlbum);
      if (!state.activeAlbum) {
        $('galleryTimeline').innerHTML = '';
        $('galleryEmptyState').classList.add('hidden');
        $('loadMoreWrap').classList.add('hidden');
        renderAlbumsGrid();
        return;
      }
    }

    const items = filteredPhotos();
    state.visibleFlatPhotos = items;

    const vidCount = state.photos.filter(isVideoPhoto).length;
    const photoCount = state.photos.length - vidCount;
    $('galleryCountsText').textContent = isTrashView
      ? `${state.trashPhotos.length} item(s) in Trash`
      : isProtectedView
        ? `${items.length} protected original(s)`
        : isFavoriteView
          ? `${items.length} favorite(s)`
          : isAlbumsView && state.activeAlbum
            ? `${state.activeAlbum.name} · ${items.length} item(s)`
            : isMapView
              ? `${items.length} mapped photo(s)`
              : `${state.totalPhotos} total · ${photoCount} photos · ${vidCount} videos${state.protectedCount > 0 ? ` · ${state.protectedCount} protected` : ''}`;

    const container = $('galleryTimeline');
    container.innerHTML = '';

    if (items.length === 0) {
      $('galleryEmptyState').classList.remove('hidden');
      setMascotMood($('emptyStateMascot'), 'sleeping');
      if (isTrashView) {
        $('emptyStateTitle').textContent = 'Trash is Empty';
        $('emptyStateText').textContent = 'Deleted photos appear here for 30 days before permanent removal.';
      } else if (isProtectedView) {
        $('emptyStateTitle').textContent = state.isLoadingProtected ? 'Loading Protected Originals…' : 'No Protected Originals';
        $('emptyStateText').textContent = state.isLoadingProtected
          ? 'Fetching all protected items across your cloud library…'
          : 'Restored or protected originals appear here so they stay full-resolution on your phone.';
      } else if (isFavoriteView) {
        $('emptyStateTitle').textContent = state.isLoadingFavorites ? 'Loading Favorites…' : 'No Favorites Yet';
        $('emptyStateText').textContent = state.isLoadingFavorites
          ? 'Fetching your favorited photos across your cloud library…'
          : 'Tap the ♥ heart on any photo in the webpage or phone app to add it here.';
      } else if (isAlbumsView && state.activeAlbum) {
        $('emptyStateTitle').textContent = 'Empty Album';
        $('emptyStateText').textContent = 'Select photos from All Photos and tap "+ Album" to add them here.';
      } else if (isMapView) {
        $('emptyStateTitle').textContent = 'No Geo-Tagged Photos Yet';
        $('emptyStateText').textContent = 'Photos with camera GPS coordinates appear here automatically.';
      } else {
        $('emptyStateTitle').textContent = state.photos.length === 0 ? 'No Backups Yet' : 'No Matching Items';
        $('emptyStateText').textContent =
          state.photos.length === 0
            ? 'Drop photos onto this page or open PhotoHub on iOS / Android to back up.'
            : 'Try clearing your search or switching filters.';
      }
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
        tile.className = `photo-tile${isSelected ? ' is-selected' : ''}${isProtectedView && photo.keepOriginalOnDevice ? ' is-protected-view' : ''}`;
        tile.dataset.hash = photo.hash;
        tile.dataset.video = isVid ? '1' : '0';
        tile.dataset.needsProxy = needsProxy ? '1' : '0';
        tile.tabIndex = 0;
        tile.setAttribute('role', 'button');
        tile.setAttribute('aria-label', photo.originalName || 'Photo');

        const cachedThumbUrl = thumbUrlCache.get(photo.hash) || null;
        if (cachedThumbUrl) {
          tile.dataset.thumbLoaded = '1';
          tile.innerHTML = `<img alt="" decoding="async" class="is-loaded" />`;
          const imgEl = tile.querySelector('img');
          imgEl.alt = photo.originalName || '';
          imgEl.src = cachedThumbUrl;
        } else {
          tile.innerHTML = `<div class="photo-tile-shimmer"></div><img alt="" loading="lazy" decoding="async" />`;
          tile.querySelector('img').alt = photo.originalName || '';
        }

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

        if (photo.keepOriginalOnDevice || photo.isFavorite) {
          const badges = document.createElement('div');
          badges.className = 'tile-badges';
          if (photo.isFavorite) {
            badges.innerHTML += `<span class="tile-badge tile-badge--fav" title="Favorite">♥</span>`;
          }
          if (photo.keepOriginalOnDevice) {
            badges.innerHTML += `<span class="tile-badge tile-badge--protected" title="Protected Original · Won't auto re-proxy"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" width="13" height="13"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/></svg></span>`;
          }
          tile.appendChild(badges);
        }

        if (isTrashView && typeof photo.daysRemaining === 'number') {
          const tp = document.createElement('div');
          tp.className = 'tile-trash-pill';
          tp.textContent = `${photo.daysRemaining}d left`;
          tile.appendChild(tp);
        }

        tile.addEventListener('click', (e) => {
          if (state.isSelectionMode || e.shiftKey) {
            if (!state.isSelectionMode) {
              state.isSelectionMode = true;
              $('selectModeBtn').textContent = 'Done';
            }
            if (e.shiftKey && state.lastSelectedIndex >= 0 && state.lastSelectedIndex < state.visibleFlatPhotos.length) {
              const start = Math.min(state.lastSelectedIndex, idx);
              const end = Math.max(state.lastSelectedIndex, idx);
              for (let r = start; r <= end; r++) {
                state.selectedHashes.add(state.visibleFlatPhotos[r].hash.toLowerCase());
              }
              state.lastSelectedIndex = idx;
              updateSelectionBar();
              renderGallery();
            } else {
              state.lastSelectedIndex = idx;
              togglePhotoSelect(photo.hash, tile);
            }
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
        if (!cachedThumbUrl) {
          thumbObserver.observe(tile);
        }
      }

      secEl.appendChild(grid);
      frag.appendChild(secEl);
    }

    container.appendChild(frag);
    cancelStaleThumbFetches();
    const canPaginateMain = !isTrashView && !isProtectedView && !isFavoriteView && !isAlbumsView && !isMapView && state.hasMore;
    $('loadMoreWrap').classList.toggle('hidden', !canPaginateMain);
    if (canPaginateMain) {
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

  // ==================== MULTI-SELECT, TRASH, ZIP & SHARE ====================
  function toggleSelectionMode(force) {
    state.isSelectionMode = typeof force === 'boolean' ? force : !state.isSelectionMode;
    if (!state.isSelectionMode) {
      state.selectedHashes.clear();
      state.lastSelectedIndex = -1;
    }
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

  function getActiveSelectionSource() {
    if (state.filterMedia === 'trash') return state.trashPhotos;
    if (state.filterMedia === 'protected') {
      return state.protectedLoadedOnce
        ? state.protectedPhotos
        : state.photos.filter((p) => Boolean(p.keepOriginalOnDevice));
    }
    if (state.filterMedia === 'favorite') {
      return state.favoriteLoadedOnce
        ? state.favoritePhotos
        : state.photos.filter((p) => Boolean(p.isFavorite));
    }
    if (state.filterMedia === 'albums' && state.activeAlbum) return state.activeAlbumPhotos;
    if (state.filterMedia === 'map' && state.mapData && Array.isArray(state.mapData.photos)) {
      return state.mapData.photos;
    }
    return state.photos;
  }

  function updateSelectionBar() {
    const bar = $('selectionBar');
    bar.classList.toggle('hidden', !state.isSelectionMode);
    if (!state.isSelectionMode) return;
    const isTrash = state.filterMedia === 'trash';
    const isProtectedView = state.filterMedia === 'protected';
    const inCustomAlbum = state.filterMedia === 'albums' && Boolean(state.activeAlbum);
    const source = getActiveSelectionSource();
    const count = state.selectedHashes.size;
    let totalBytes = 0;
    let protectedSelectedCount = 0;
    let unprotectedSelectedCount = 0;
    for (const p of source) {
      if (state.selectedHashes.has(p.hash.toLowerCase())) {
        totalBytes += Number(p.size) || 0;
        if (p.keepOriginalOnDevice) protectedSelectedCount += 1;
        else unprotectedSelectedCount += 1;
      }
    }
    $('selectionCountText').textContent = `${count} selected`;
    $('selectionSizeText').textContent =
      protectedSelectedCount > 0 && !isTrash
        ? `${formatBytes(totalBytes)} · ${protectedSelectedCount} protected · Shift+Click for range`
        : `${formatBytes(totalBytes)} · Shift+Click for range`;

    const allowReproxyBtn = $('allowReproxySelectedBtn');
    const protectBtn = $('protectSelectedBtn');
    const showAllowReproxy = !isTrash && (protectedSelectedCount > 0 || isProtectedView);
    const showProtect = !isTrash && protectedSelectedCount === 0 && unprotectedSelectedCount > 0 && !isProtectedView;

    if (allowReproxyBtn) {
      allowReproxyBtn.classList.toggle('hidden', !showAllowReproxy);
      allowReproxyBtn.disabled = state.isMutatingProtection || protectedSelectedCount === 0;
      if (!state.isMutatingProtection) {
        allowReproxyBtn.textContent =
          protectedSelectedCount > 0 && protectedSelectedCount < count
            ? `Allow Re-Proxy (${protectedSelectedCount})`
            : 'Allow Re-Proxy';
      }
    }
    if (protectBtn) {
      protectBtn.classList.toggle('hidden', !showProtect);
      protectBtn.disabled = state.isMutatingProtection || unprotectedSelectedCount === 0;
      if (!state.isMutatingProtection) {
        protectBtn.textContent = 'Protect';
      }
    }

    $('deleteSelectedBtn').disabled = count === 0;
    $('deleteSelectedBtn').textContent = isTrash ? 'Delete Forever' : 'Trash';
    $('downloadZipBtn').classList.toggle('hidden', isTrash);
    $('downloadZipBtn').disabled = count === 0;
    $('addToAlbumSelectedBtn').classList.toggle('hidden', isTrash);
    $('addToAlbumSelectedBtn').disabled = count === 0;
    $('removeFromAlbumSelectedBtn').classList.toggle('hidden', !inCustomAlbum);
    $('removeFromAlbumSelectedBtn').disabled = count === 0;
    $('shareSelectedBtn').classList.toggle('hidden', isTrash);
    $('shareSelectedBtn').disabled = count === 0;
    $('restoreSelectedBtn').classList.toggle('hidden', !isTrash);
    $('restoreSelectedBtn').disabled = count === 0;
  }

  function applyProtectedDeltaLocally(appliedHashes, updatedPhotosList, keepOriginal, serverCounts = null) {
    const flag = Boolean(keepOriginal);
    const targetSet = new Set(appliedHashes);
    const updatedMap = new Map(
      (updatedPhotosList || []).map((p) => [String(p.hash || '').toLowerCase(), p])
    );

    let delta = 0;
    for (const list of [state.photos, state.favoritePhotos, state.activeAlbumPhotos]) {
      for (const p of list) {
        const k = String(p.hash || '').toLowerCase();
        if (!targetSet.has(k)) continue;
        const prev = Boolean(p.keepOriginalOnDevice);
        const srv = updatedMap.get(k);
        p.keepOriginalOnDevice = srv ? Boolean(srv.keepOriginalOnDevice) : flag;
        if (list === state.photos && prev !== p.keepOriginalOnDevice) {
          delta += p.keepOriginalOnDevice ? 1 : -1;
        }
      }
    }

    if (flag) {
      const existingProtected = new Set(state.protectedPhotos.map((p) => String(p.hash || '').toLowerCase()));
      for (const h of appliedHashes) {
        if (existingProtected.has(h)) continue;
        const item =
          updatedMap.get(h) ||
          state.photos.find((p) => String(p.hash || '').toLowerCase() === h) ||
          state.favoritePhotos.find((p) => String(p.hash || '').toLowerCase() === h);
        if (item) {
          state.protectedPhotos.unshift({ ...item, keepOriginalOnDevice: true });
          existingProtected.add(h);
        }
      }
    } else {
      const beforeLen = state.protectedPhotos.length;
      state.protectedPhotos = state.protectedPhotos.filter(
        (p) => !targetSet.has(String(p.hash || '').toLowerCase())
      );
      if (state.protectedLoadedOnce) {
        delta = state.protectedPhotos.length - beforeLen;
      }
      for (const h of appliedHashes) {
        state.selectedHashes.delete(h);
      }
    }

    if (serverCounts && typeof serverCounts.protectedCount === 'number') {
      applyServerCategoryCounts(serverCounts);
    } else if (state.protectedLoadedOnce) {
      state.protectedCount = state.protectedPhotos.length;
    } else {
      state.protectedCount = Math.max(
        0,
        state.protectedCount + (delta !== 0 ? delta : flag ? appliedHashes.length : -appliedHashes.length)
      );
    }
    state.photosEtag = null;
    updateProtectedBadge();
  }

  async function batchSetProtectOriginals(rawHashes, keepOriginal) {
    if (state.isMutatingProtection) return;
    const cleaned = Array.from(
      new Set((rawHashes || []).map((h) => String(h || '').trim().toLowerCase()).filter(Boolean))
    );
    if (cleaned.length === 0) return;

    const flag = Boolean(keepOriginal);
    const total = cleaned.length;
    const verb = flag ? 'Protecting' : 'Allowing re-proxy';
    const allowBtn = $('allowReproxySelectedBtn');
    const protectBtn = $('protectSelectedBtn');
    const unlockAllBtn = $('allowReproxyAllProtectedBtn');

    state.isMutatingProtection = true;
    // Invalidate any stale in-flight loadProtectedPhotos so it cannot overwrite our live progress
    state.protectedLoadSeq += 1;

    const setLiveProgressUI = (done) => {
      const msg = `${verb} (${done}/${total})…`;
      updateProtectedBannerUI(msg);
      if (allowBtn) {
        allowBtn.disabled = true;
        if (!flag) allowBtn.textContent = `Unlocking ${done}/${total}…`;
      }
      if (protectBtn) {
        protectBtn.disabled = true;
        if (flag) protectBtn.textContent = `Protecting ${done}/${total}…`;
      }
      if (unlockAllBtn) {
        unlockAllBtn.disabled = true;
        if (!flag) unlockAllBtn.textContent = `Unlocking ${done}/${total}…`;
      }
    };

    setLiveProgressUI(0);
    let completedCount = 0;
    let lastServerCounts = null;
    let failureError = null;

    try {
      const chunkSize = total > 60 ? 50 : 200;
      for (let i = 0; i < total; i += chunkSize) {
        const chunk = cleaned.slice(i, i + chunkSize);
        const res = await apiFetch('/api/photos/protect-original', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ hashes: chunk, keepOriginalOnDevice: flag }),
        });

        if (res.status === 404) {
          // Graceful fallback for older servers: update item-by-item and stream live UI progress!
          for (const h of chunk) {
            const singleRes = await apiFetch(`/api/photo/${encodeURIComponent(h)}/protect-original`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ keepOriginalOnDevice: flag }),
            });
            const singleData = await singleRes.json().catch(() => ({}));
            if (!singleRes.ok) {
              throw new Error(singleData.error || `Could not update protection (HTTP ${singleRes.status})`);
            }
            if (typeof singleData.protectedCount === 'number') {
              lastServerCounts = singleData;
            }
            completedCount += 1;
            applyProtectedDeltaLocally(
              [h],
              singleData.photo ? [singleData.photo] : [],
              flag,
              lastServerCounts
            );
            setLiveProgressUI(completedCount);
            if (completedCount % 3 === 0 || completedCount === total) {
              renderGallery();
            }
          }
          continue;
        }

        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || 'Could not update protection');
        if (typeof data.protectedCount === 'number') {
          lastServerCounts = data;
        }
        const chunkPhotos = Array.isArray(data.photos) ? data.photos : [];
        completedCount += chunk.length;
        applyProtectedDeltaLocally(chunk, chunkPhotos, flag, lastServerCounts);
        setLiveProgressUI(completedCount);
        renderGallery();
      }
    } catch (err) {
      failureError = err;
    } finally {
      state.isMutatingProtection = false;
      updateProtectedBannerUI();
      toggleSelectionMode(false);
    }

    // Re-sync authoritative server state for Protected view so the page matches phone clients 100%
    if (state.filterMedia === 'protected') {
      loadProtectedPhotos({ silent: true });
    }

    if (failureError) {
      showToast(
        completedCount > 0
          ? `Updated ${completedCount}/${total}, then failed: ${failureError.message}`
          : failureError.message || 'Could not update protection',
        'rose'
      );
    } else {
      showToast(
        flag
          ? `Protected ${completedCount} original(s) from auto re-compression.`
          : `Unlocked ${completedCount} photo(s) — synced with phone to allow re-proxy.`,
        'mint'
      );
    }
  }

  function openConfirmModal(title, text, onConfirm, okLabel = 'Confirm') {
    $('confirmTitle').textContent = title;
    $('confirmText').textContent = text;
    $('confirmOkBtn').textContent = okLabel;
    state.confirmCallback = onConfirm;
    $('confirmModal').classList.remove('hidden');
  }

  function closeConfirmModal() {
    $('confirmModal').classList.add('hidden');
    state.confirmCallback = null;
  }

  async function movePhotosToTrash(hashes) {
    if (!hashes || hashes.length === 0) return;
    try {
      const res = await apiFetch('/api/photos/trash', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ hashes }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Move to Trash failed');
      const moved = new Set((data.trashed || []).map((h) => String(h).toLowerCase()));
      let removedProtected = 0;
      let removedFavorites = 0;
      for (const p of state.photos) {
        if (moved.has(p.hash.toLowerCase())) {
          if (p.keepOriginalOnDevice) removedProtected += 1;
          if (p.isFavorite) removedFavorites += 1;
        }
      }
      state.photos = state.photos.filter((p) => !moved.has(p.hash.toLowerCase()));
      const prevProtectedLen = state.protectedPhotos.length;
      state.protectedPhotos = state.protectedPhotos.filter((p) => !moved.has(p.hash.toLowerCase()));
      const prevFavLen = state.favoritePhotos.length;
      state.favoritePhotos = state.favoritePhotos.filter((p) => !moved.has(p.hash.toLowerCase()));
      state.activeAlbumPhotos = state.activeAlbumPhotos.filter((p) => !moved.has(p.hash.toLowerCase()));
      if (typeof data.protectedCount === 'number') {
        applyServerCategoryCounts(data);
      } else {
        if (state.protectedLoadedOnce) {
          state.protectedCount = state.protectedPhotos.length;
        } else {
          const protDelta = Math.max(removedProtected, prevProtectedLen - state.protectedPhotos.length);
          state.protectedCount = Math.max(0, state.protectedCount - protDelta);
        }
        if (state.favoriteLoadedOnce) {
          state.favoriteCount = state.favoritePhotos.length;
        } else {
          const favDelta = Math.max(removedFavorites, prevFavLen - state.favoritePhotos.length);
          state.favoriteCount = Math.max(0, state.favoriteCount - favDelta);
        }
        state.trashCount += moved.size;
      }
      state.totalPhotos = Math.max(0, state.totalPhotos - moved.size);
      state.photosEtag = null;
      for (const h of moved) state.selectedHashes.delete(h);
      updateTrashBadge();
      updateProtectedBadge();
      updateFavoriteBadge();
      updateProtectedBannerUI();
      showToast(`Moved ${moved.size} item(s) to Trash (kept 30 days)`, 'amber');
      toggleSelectionMode(false);
    } catch (err) {
      showToast(err.message || 'Could not move to Trash', 'rose');
    }
  }

  async function restorePhotosFromTrash(hashes) {
    if (!hashes || hashes.length === 0) return;
    try {
      const res = await apiFetch('/api/photos/trash/restore', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ hashes }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Restore failed');
      const restored = new Set((data.restored || []).map((h) => String(h).toLowerCase()));
      state.trashPhotos = state.trashPhotos.filter((p) => !restored.has(p.hash.toLowerCase()));
      state.trashCount = state.trashPhotos.length;
      applyServerCategoryCounts(data);
      state.photosEtag = null;
      state.protectedLoadedOnce = false;
      state.favoriteLoadedOnce = false;
      for (const h of restored) state.selectedHashes.delete(h);
      updateTrashBadge();
      updateProtectedBadge();
      updateFavoriteBadge();
      showToast(`Restored ${restored.size} item(s) to library`, 'mint');
      toggleSelectionMode(false);
      loadGallery(false);
    } catch (err) {
      showToast(err.message || 'Restore failed', 'rose');
    }
  }

  async function emptyTrashOnServer(hashes = null) {
    try {
      const res = await apiFetch('/api/photos/trash/empty', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(hashes && hashes.length ? { hashes } : {}),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Empty Trash failed');
      const removed = new Set((data.deleted || []).map((h) => String(h).toLowerCase()));
      state.trashPhotos = hashes && hashes.length
        ? state.trashPhotos.filter((p) => !removed.has(p.hash.toLowerCase()))
        : [];
      state.trashCount = state.trashPhotos.length;
      for (const h of removed) state.selectedHashes.delete(h);
      if (data.storage && state.whoami) {
        state.whoami.storage = { ...(state.whoami.storage || {}), ...data.storage };
        updateStorageBanner(state.whoami.storage);
      }
      updateTrashBadge();
      showToast(`Permanently deleted ${removed.size} item(s) · Freed ${formatBytes(data.freedBytes || 0)}`, 'mint');
      toggleSelectionMode(false);
    } catch (err) {
      showToast(err.message || 'Could not empty Trash', 'rose');
    }
  }

  async function downloadSelectedAsZip(hashes) {
    if (!hashes || hashes.length === 0) return;
    showToast(`Preparing ZIP for ${hashes.length} item(s)…`, 'orange');
    try {
      const res = await apiFetch('/api/photos/download-zip', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ hashes }),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data.error || `HTTP ${res.status}`);
      }
      const blob = await res.blob();
      const blobUrl = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = blobUrl;
      a.download = `PhotoHub-${new Date().toISOString().slice(0, 10)}.zip`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(blobUrl), 8000);
      showToast(`Downloaded ZIP (${formatBytes(blob.size)})`, 'mint');
    } catch (err) {
      showToast(`ZIP download failed: ${err.message}`, 'rose');
    }
  }

  function openShareModal(hashes, defaultTitle = '', albumId = null) {
    state.shareTargetHashes = Array.from(hashes || []);
    state.shareAlbumId = albumId || null;
    if (state.shareTargetHashes.length === 0) return;
    $('shareModalTitle').textContent =
      state.shareTargetHashes.length === 1
        ? 'Share Photo Link'
        : `Share ${state.shareTargetHashes.length} Photos`;
    $('shareTitleInput').value = defaultTitle || '';
    $('sharePasscodeInput').value = '';
    $('shareExpirySelect').value = '168';
    $('shareAllowDownloadCheck').checked = true;
    $('shareMaxViewsInput').value = '';
    $('shareResultBox').classList.add('hidden');
    $('shareUrlOutput').value = '';
    $('shareGenerateBtn').disabled = false;
    $('shareGenerateBtn').textContent = 'Create Link';
    $('shareModal').classList.remove('hidden');
  }

  function closeShareModal() {
    $('shareModal').classList.add('hidden');
  }

  async function handleCreateShareLink(e) {
    e.preventDefault();
    if (!state.shareTargetHashes.length) return;
    const btn = $('shareGenerateBtn');
    btn.disabled = true;
    btn.textContent = 'Creating…';
    try {
      const maxViewsVal = Number($('shareMaxViewsInput').value);
      const res = await apiFetch('/api/shares', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          hashes: state.shareTargetHashes,
          title: $('shareTitleInput').value.trim(),
          expiresInHours: Number($('shareExpirySelect').value) || 168,
          passcode: $('sharePasscodeInput').value.trim(),
          allowDownload: Boolean($('shareAllowDownloadCheck').checked),
          maxViews: Number.isFinite(maxViewsVal) && maxViewsVal > 0 ? Math.round(maxViewsVal) : null,
          albumId: state.shareAlbumId || null,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.success || !data.share) {
        throw new Error(data.error || 'Could not create share link.');
      }
      const shareUrl = data.share.sharePath
        ? `${window.location.origin}${data.share.sharePath}`
        : data.share.shareUrl;
      $('shareUrlOutput').value = shareUrl;
      $('shareResultBox').classList.remove('hidden');
      showToast('Share link ready!', 'mint');
    } catch (err) {
      showToast(err.message || 'Share link creation failed', 'rose');
    } finally {
      btn.disabled = false;
      btn.textContent = 'Create Another Link';
    }
  }

  // ==================== MANAGE SHARE LINKS ====================
  async function openManageSharesModal() {
    $('manageSharesModal').classList.remove('hidden');
    const list = $('manageSharesList');
    list.innerHTML = '<div class="muted-text" style="padding:14px;text-align:center;">Loading active links…</div>';
    try {
      const res = await apiFetch('/api/shares');
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Could not load share links');
      state.activeShares = Array.isArray(data.shares) ? data.shares : [];
      renderManageSharesList();
    } catch (err) {
      list.innerHTML = `<div class="error-banner">${err.message || 'Failed to load links'}</div>`;
    }
  }

  function closeManageSharesModal() {
    $('manageSharesModal').classList.add('hidden');
  }

  function renderManageSharesList() {
    const list = $('manageSharesList');
    list.innerHTML = '';
    if (!state.activeShares.length) {
      list.innerHTML = '<div class="muted-text" style="padding:18px;text-align:center;">No active share links right now.</div>';
      return;
    }
    for (const s of state.activeShares) {
      const url = s.sharePath ? `${window.location.origin}${s.sharePath}` : s.shareUrl;
      const row = document.createElement('div');
      row.className = 'manage-row';
      const info = document.createElement('div');
      info.className = 'manage-row-info';
      const expStr = new Date(s.expiresAt).toLocaleDateString();
      const viewsStr = s.maxViews ? `${s.viewCount || 0}/${s.maxViews} views` : `${s.viewCount || 0} views`;
      const flags = [
        `${s.itemCount} item(s)`,
        viewsStr,
        s.hasPasscode ? '🔒 Passcode' : null,
        s.allowDownload === false ? '👁 View Only' : '↓ Downloads OK',
        `Exp ${expStr}`,
      ].filter(Boolean).join(' · ');
      const titleEl = document.createElement('strong');
      titleEl.textContent = s.title || 'Shared Photos';
      const metaEl = document.createElement('span');
      metaEl.textContent = flags;
      info.appendChild(titleEl);
      info.appendChild(metaEl);

      const actions = document.createElement('div');
      actions.className = 'manage-row-actions';

      const copyBtn = document.createElement('button');
      copyBtn.type = 'button';
      copyBtn.className = 'btn-soft btn-xs';
      copyBtn.textContent = 'Copy';
      copyBtn.addEventListener('click', async () => {
        try {
          await navigator.clipboard.writeText(url);
          showToast('Share link copied!', 'mint');
        } catch {
          showToast(url, 'orange');
        }
      });

      const toggleDlBtn = document.createElement('button');
      toggleDlBtn.type = 'button';
      toggleDlBtn.className = 'btn-soft btn-xs';
      toggleDlBtn.textContent = s.allowDownload === false ? 'Enable DL' : 'View-Only';
      toggleDlBtn.addEventListener('click', async () => {
        try {
          const res = await apiFetch(`/api/shares/${encodeURIComponent(s.token)}`, {
            method: 'PATCH',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ allowDownload: s.allowDownload === false }),
          });
          if (!res.ok) throw new Error('Update failed');
          s.allowDownload = s.allowDownload === false;
          renderManageSharesList();
          showToast(s.allowDownload ? 'Downloads enabled' : 'Switched to View-Only', 'mint');
        } catch (err) {
          showToast(err.message || 'Could not update share', 'rose');
        }
      });

      const revBtn = document.createElement('button');
      revBtn.type = 'button';
      revBtn.className = 'btn-danger btn-xs';
      revBtn.textContent = 'Revoke';
      revBtn.addEventListener('click', async () => {
        try {
          const res = await apiFetch(`/api/shares/${encodeURIComponent(s.token)}`, { method: 'DELETE' });
          if (!res.ok) throw new Error('Revoke failed');
          state.activeShares = state.activeShares.filter((x) => x.token !== s.token);
          renderManageSharesList();
          showToast('Share link revoked', 'amber');
        } catch (err) {
          showToast(err.message || 'Could not revoke link', 'rose');
        }
      });

      actions.append(copyBtn, toggleDlBtn, revBtn);
      row.append(info, actions);
      list.appendChild(row);
    }
  }

  // ==================== PREVIEW IMAGE HELPER ====================
  function attachPreviewToImg(imgEl, hash) {
    if (!imgEl || !hash) return;
    imgEl.decoding = 'async';
    if (thumbUrlCache.has(hash)) {
      imgEl.src = thumbUrlCache.get(hash);
      return;
    }
    fetchThumbUrl(hash, { abortable: false })
      .then((url) => {
        if (url && imgEl.isConnected) imgEl.src = url;
      })
      .catch(() => {});
  }

  // ==================== CUSTOM ALBUMS (TRIPS, EVENTS, FAMILY & CUSTOM CATEGORIES) ====================
  const ALBUM_PRESET_CATEGORIES = new Set(['trip', 'event', 'family']);
  const ALBUM_CAT_LABELS = {
    trip: '✈️ Trip',
    event: '🎉 Event',
    family: '👨‍👩‍👧 Family',
    custom: '📁 Album',
  };

  function formatAlbumCategory(rawCategory) {
    const clean = String(rawCategory || '').trim();
    if (!clean) return ALBUM_CAT_LABELS.custom;
    const lower = clean.toLowerCase();
    if (ALBUM_CAT_LABELS[lower]) return ALBUM_CAT_LABELS[lower];
    return `🏷️ ${clean}`;
  }

  function renderAlbumCategoryPills() {
    const container = $('albumCategoryPills');
    if (!container) return;

    const pills = [
      { key: 'all', label: 'All Albums' },
      { key: 'trip', label: '✈️ Trips' },
      { key: 'event', label: '🎉 Events' },
      { key: 'family', label: '👨‍👩‍👧 Family' },
    ];

    // Dynamically include any user-defined custom categories present on albums (never showing literal "Custom")
    const seenCustom = new Set();
    for (const alb of state.albums || []) {
      const cat = String(alb.category || '').trim();
      const lower = cat.toLowerCase();
      if (!cat || lower === 'custom' || ALBUM_PRESET_CATEGORIES.has(lower) || seenCustom.has(lower)) {
        continue;
      }
      seenCustom.add(lower);
      pills.push({ key: lower, label: `🏷️ ${cat}` });
    }

    const activeKey = String(state.albumCategoryFilter || 'all').toLowerCase();
    if (!pills.some((p) => p.key === activeKey)) {
      state.albumCategoryFilter = 'all';
    }

    container.innerHTML = '';
    for (const p of pills) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = `f-pill${state.albumCategoryFilter === p.key ? ' is-active' : ''}`;
      btn.dataset.albCat = p.key;
      btn.textContent = p.label;
      btn.addEventListener('click', () => {
        state.albumCategoryFilter = p.key;
        renderAlbumsGrid();
      });
      container.appendChild(btn);
    }
  }

  function syncAlbumCustomCategoryField({ focus = false } = {}) {
    const sel = $('albumCategorySelect');
    const field = $('albumCustomCategoryField');
    const input = $('albumCustomCategoryInput');
    if (!sel || !field || !input) return;
    const isCustom = sel.value === 'custom';
    field.classList.toggle('hidden', !isCustom);
    input.required = isCustom;
    if (isCustom && focus) {
      requestAnimationFrame(() => input.focus());
    }
  }

  async function loadAlbums() {
    if (!state.session) return;
    try {
      const res = await apiFetch('/api/albums');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      state.albums = Array.isArray(data.albums) ? data.albums : [];
      renderAlbumsGrid();
    } catch (err) {
      showToast(err.message || 'Could not load albums', 'rose');
    }
  }

  function renderAlbumsGrid() {
    renderAlbumCategoryPills();
    const grid = $('albumsGrid');
    if (!grid) return;
    grid.innerHTML = '';
    const activeFilter = String(state.albumCategoryFilter || 'all').toLowerCase();
    const list = state.albums.filter(
      (a) => activeFilter === 'all' || String(a.category || '').trim().toLowerCase() === activeFilter
    );
    if (list.length === 0) {
      grid.innerHTML =
        '<div class="empty-state" style="grid-column:1/-1;padding:36px 12px;"><h3>No Albums Yet</h3><p>Create Trips, Events, Family, or your own custom category albums to organize and share collections.</p></div>';
      return;
    }

    for (const alb of list) {
      const card = document.createElement('div');
      card.className = 'album-card';

      const cov = document.createElement('div');
      cov.className = 'album-cover';
      if (alb.coverHash) {
        const img = document.createElement('img');
        img.alt = alb.name;
        cov.appendChild(img);
        attachPreviewToImg(img, alb.coverHash);
      } else {
        cov.innerHTML = '<span class="album-cover-placeholder">📸</span>';
      }
      const badge = document.createElement('span');
      badge.className = 'album-cat-badge';
      badge.textContent = formatAlbumCategory(alb.category);
      cov.appendChild(badge);

      const body = document.createElement('div');
      body.className = 'album-card-body';
      const h4 = document.createElement('h4');
      h4.textContent = alb.name;
      const span = document.createElement('span');
      span.textContent = `${alb.itemCount || 0} item(s)${alb.dateRange ? ' · ' + alb.dateRange : ''}`;
      body.append(h4, span);

      card.append(cov, body);
      card.addEventListener('click', () => openAlbumDetail(alb.id));
      grid.appendChild(card);
    }
  }

  async function openAlbumDetail(albumId) {
    try {
      const res = await apiFetch(`/api/albums/${encodeURIComponent(albumId)}`);
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.album) throw new Error(data.error || 'Album not found');
      state.activeAlbum = data.album;
      state.activeAlbumPhotos = Array.isArray(data.photos) ? data.photos : [];
      $('activeAlbumTitle').textContent = `${formatAlbumCategory(data.album.category)} · ${data.album.name}`;
      $('activeAlbumMeta').textContent = [
        `${state.activeAlbumPhotos.length} item(s)`,
        data.album.dateRange || null,
        data.album.description || null,
      ].filter(Boolean).join(' · ');
      renderGallery();
    } catch (err) {
      showToast(err.message || 'Could not open album', 'rose');
    }
  }

  function closeAlbumDetail() {
    state.activeAlbum = null;
    state.activeAlbumPhotos = [];
    toggleSelectionMode(false);
    renderGallery();
  }

  function openAlbumModal(editAlbum = null, initialHashes = []) {
    state.editingAlbumId = editAlbum ? editAlbum.id : null;
    state.albumPickerHashes = Array.isArray(initialHashes) ? initialHashes : [];
    $('albumModalTitle').textContent = editAlbum ? 'Edit Album' : 'New Album';
    $('albumNameInput').value = editAlbum ? editAlbum.name : '';

    const rawCat = editAlbum ? String(editAlbum.category || '').trim() : 'trip';
    const lowerCat = rawCat.toLowerCase();
    if (ALBUM_PRESET_CATEGORIES.has(lowerCat)) {
      $('albumCategorySelect').value = lowerCat;
      $('albumCustomCategoryInput').value = '';
    } else {
      $('albumCategorySelect').value = 'custom';
      $('albumCustomCategoryInput').value = lowerCat && lowerCat !== 'custom' ? rawCat : '';
    }
    syncAlbumCustomCategoryField({ focus: false });

    $('albumDescInput').value = editAlbum ? editAlbum.description || '' : '';
    $('albumModal').classList.remove('hidden');
  }

  function closeAlbumModal() {
    $('albumModal').classList.add('hidden');
    state.editingAlbumId = null;
  }

  async function handleSaveAlbum(e) {
    e.preventDefault();
    const name = $('albumNameInput').value.trim();
    if (!name) return;
    const selectedCategory = $('albumCategorySelect').value;
    let category = selectedCategory;
    if (selectedCategory === 'custom') {
      const customCategory = $('albumCustomCategoryInput').value.trim();
      if (!customCategory) {
        showToast('Please enter a custom category name.', 'amber');
        $('albumCustomCategoryInput').focus();
        return;
      }
      category = customCategory;
    }
    const description = $('albumDescInput').value.trim();
    try {
      if (state.editingAlbumId) {
        const res = await apiFetch(`/api/albums/${encodeURIComponent(state.editingAlbumId)}`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name, category, description }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || 'Could not update album');
        showToast('Album updated!', 'mint');
        closeAlbumModal();
        await loadAlbums();
        if (state.activeAlbum && state.activeAlbum.id === data.album.id) {
          await openAlbumDetail(data.album.id);
        }
      } else {
        const res = await apiFetch('/api/albums', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name, category, description, hashes: state.albumPickerHashes }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || 'Could not create album');
        showToast(
          state.albumPickerHashes.length
            ? `Created "${name}" with ${state.albumPickerHashes.length} item(s)!`
            : `Created album "${name}"!`,
          'mint'
        );
        state.albumPickerHashes = [];
        closeAlbumModal();
        await loadAlbums();
        if (state.isSelectionMode) toggleSelectionMode(false);
      }
    } catch (err) {
      showToast(err.message || 'Album save failed', 'rose');
    }
  }

  async function openAlbumPickerModal(hashes) {
    state.albumPickerHashes = Array.from(hashes || []);
    if (state.albumPickerHashes.length === 0) return;
    $('albumPickerSub').textContent = `Add ${state.albumPickerHashes.length} selected item(s) to an album:`;
    $('albumPickerModal').classList.remove('hidden');
    const list = $('albumPickerList');
    list.innerHTML = '<div class="muted-text" style="padding:12px;text-align:center;">Loading albums…</div>';
    await loadAlbums();
    list.innerHTML = '';
    if (state.albums.length === 0) {
      list.innerHTML = '<div class="muted-text" style="padding:12px;text-align:center;">No albums yet — create your first one below!</div>';
      return;
    }
    for (const alb of state.albums) {
      const row = document.createElement('div');
      row.className = 'manage-row';
      const info = document.createElement('div');
      info.className = 'manage-row-info';
      const title = document.createElement('strong');
      title.textContent = `${formatAlbumCategory(alb.category)} · ${alb.name}`;
      const sub = document.createElement('span');
      sub.textContent = `${alb.itemCount || 0} item(s)`;
      info.append(title, sub);

      const addBtn = document.createElement('button');
      addBtn.type = 'button';
      addBtn.className = 'btn-soft btn-xs';
      addBtn.textContent = 'Add Here';
      addBtn.addEventListener('click', async () => {
        try {
          const res = await apiFetch(`/api/albums/${encodeURIComponent(alb.id)}/photos`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ hashes: state.albumPickerHashes }),
          });
          const data = await res.json().catch(() => ({}));
          if (!res.ok) throw new Error(data.error || 'Could not add photos');
          showToast(`Added ${data.addedCount || 0} photo(s) to "${alb.name}"`, 'mint');
          closeAlbumPickerModal();
          await loadAlbums();
          if (state.isSelectionMode) toggleSelectionMode(false);
        } catch (err) {
          showToast(err.message || 'Add failed', 'rose');
        }
      });
      row.append(info, addBtn);
      list.appendChild(row);
    }
  }

  function closeAlbumPickerModal() {
    $('albumPickerModal').classList.add('hidden');
  }

  async function removeSelectedFromActiveAlbum(hashes) {
    if (!state.activeAlbum || !hashes.length) return;
    try {
      const res = await apiFetch(`/api/albums/${encodeURIComponent(state.activeAlbum.id)}/photos/remove`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ hashes }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Could not remove from album');
      showToast(`Removed ${data.removedCount || 0} item(s) from album`, 'amber');
      toggleSelectionMode(false);
      await openAlbumDetail(state.activeAlbum.id);
    } catch (err) {
      showToast(err.message || 'Remove failed', 'rose');
    }
  }

  // ==================== PHOTO MAP & LOCATION SEARCH (LEAFLET + OPTIONAL GOOGLE MAPS) ====================
  const mapRuntime = {
    leafletLoadPromise: null,
    leafletMap: null,
    leafletBaseLayer: null,
    leafletMarkersLayer: null,
    googleLoadPromise: null,
    googleLoadedKey: null,
    googleMap: null,
    googleOverlays: [],
  };

  function getGoogleMapsLink(lat, lng) {
    return `https://www.google.com/maps?q=${encodeURIComponent(`${Number(lat).toFixed(6)},${Number(lng).toFixed(6)}`)}`;
  }

  function setMapLoading(visible, message = 'Loading interactive map…') {
    const overlay = $('mapLoadingOverlay');
    if (!overlay) return;
    overlay.classList.toggle('hidden', !visible);
    const label = $('mapLoadingText');
    if (label && message) label.textContent = message;
  }

  function injectCssOnce(id, href) {
    return new Promise((resolve, reject) => {
      const existing = document.getElementById(id);
      if (existing) return resolve();
      const link = document.createElement('link');
      link.id = id;
      link.rel = 'stylesheet';
      link.href = href;
      link.onload = () => resolve();
      link.onerror = () => {
        link.remove();
        reject(new Error(`Failed to load CSS ${href}`));
      };
      document.head.appendChild(link);
    });
  }

  function injectScriptOnce(id, src, timeoutMs = 12000) {
    return new Promise((resolve, reject) => {
      const existing = document.getElementById(id);
      if (existing && existing.dataset.loaded === '1') return resolve();
      if (existing) existing.remove();
      const script = document.createElement('script');
      script.id = id;
      script.src = src;
      script.async = true;
      const timer = setTimeout(() => {
        script.remove();
        reject(new Error(`Timed out loading ${src}`));
      }, timeoutMs);
      script.onload = () => {
        clearTimeout(timer);
        script.dataset.loaded = '1';
        resolve();
      };
      script.onerror = () => {
        clearTimeout(timer);
        script.remove();
        reject(new Error(`Failed to load ${src}`));
      };
      document.head.appendChild(script);
    });
  }

  async function ensureLeafletLoaded() {
    if (window.L && typeof window.L.map === 'function') return window.L;
    if (mapRuntime.leafletLoadPromise) return mapRuntime.leafletLoadPromise;

    mapRuntime.leafletLoadPromise = (async () => {
      const cdns = [
        {
          css: 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
          js: 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js',
        },
        {
          css: 'https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css',
          js: 'https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js',
        },
      ];
      let lastErr = null;
      for (const cdn of cdns) {
        try {
          await injectCssOnce('photohub-leaflet-css', cdn.css);
          await injectScriptOnce('photohub-leaflet-js', cdn.js);
          if (window.L && typeof window.L.map === 'function') {
            return window.L;
          }
        } catch (err) {
          lastErr = err;
        }
      }
      mapRuntime.leafletLoadPromise = null;
      throw lastErr || new Error('Could not load map library');
    })();
    return mapRuntime.leafletLoadPromise;
  }

  async function ensureGoogleMapsLoaded(apiKey) {
    if (window.google && window.google.maps && typeof window.google.maps.Map === 'function') {
      return window.google.maps;
    }
    if (!apiKey) throw new Error('Google Maps API key not configured');
    if (mapRuntime.googleLoadPromise && mapRuntime.googleLoadedKey === apiKey) {
      return mapRuntime.googleLoadPromise;
    }
    mapRuntime.googleLoadedKey = apiKey;
    mapRuntime.googleLoadPromise = (async () => {
      try {
        await injectScriptOnce(
          'photohub-google-maps-js',
          `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(apiKey)}&v=weekly`,
          12000
        );
        if (window.google && window.google.maps && typeof window.google.maps.Map === 'function') {
          return window.google.maps;
        }
        throw new Error('Google Maps SDK unavailable');
      } catch (err) {
        mapRuntime.googleLoadPromise = null;
        throw err;
      }
    })();
    return mapRuntime.googleLoadPromise;
  }

  function clearActiveMapMarkers() {
    if (mapRuntime.leafletMarkersLayer) {
      mapRuntime.leafletMarkersLayer.clearLayers();
    }
    if (Array.isArray(mapRuntime.googleOverlays)) {
      for (const ov of mapRuntime.googleOverlays) {
        try {
          ov.setMap(null);
        } catch {
          // ignore
        }
      }
      mapRuntime.googleOverlays = [];
    }
  }

  function applyLeafletBaseLayer() {
    const L = window.L;
    const map = mapRuntime.leafletMap;
    if (!L || !map) return;
    if (mapRuntime.leafletBaseLayer) {
      map.removeLayer(mapRuntime.leafletBaseLayer);
      mapRuntime.leafletBaseLayer = null;
    }

    const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
    let nextLayer;
    if (state.mapStyle === 'satellite') {
      const imagery = L.tileLayer(
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        { maxZoom: 19, attribution: 'Imagery © Esri' }
      );
      const labels = L.tileLayer(
        'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
        { maxZoom: 19, opacity: 0.9 }
      );
      nextLayer = L.layerGroup([imagery, labels]);
    } else if (state.mapStyle === 'osm') {
      nextLayer = L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 19,
        attribution: '© OpenStreetMap contributors',
      });
    } else {
      const tileUrl = isDark
        ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
        : 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';
      nextLayer = L.tileLayer(tileUrl, {
        subdomains: 'abcd',
        maxZoom: 19,
        attribution: '© OpenStreetMap · © CARTO',
      });
    }
    nextLayer.addTo(map);
    mapRuntime.leafletBaseLayer = nextLayer;
  }

  function applyGoogleMapStyle() {
    const gmap = mapRuntime.googleMap;
    if (!gmap) return;
    const typeId =
      state.mapStyle === 'satellite'
        ? 'hybrid'
        : state.mapStyle === 'osm'
          ? 'terrain'
          : 'roadmap';
    gmap.setMapTypeId(typeId);
  }

  function syncMapTheme() {
    if (mapRuntime.leafletMap && state.mapStyle === 'street') {
      applyLeafletBaseLayer();
    }
  }

  function getActiveMapPhotos() {
    const all = state.mapData && Array.isArray(state.mapData.photos) ? state.mapData.photos : [];
    if (!state.searchQuery) return all;
    return all.filter((p) => matchesSmartSearch(p, state.searchQuery));
  }

  function buildZoomClusters(photos, zoom) {
    if (!Array.isArray(photos) || photos.length === 0) return [];
    const safeZoom = Math.max(1, Math.min(19, Math.round(Number(zoom) || 2)));
    const worldSize = 256 * Math.pow(2, safeZoom);
    const cellPx = safeZoom >= 16 ? 42 : safeZoom >= 12 ? 54 : 62;
    const buckets = new Map();

    for (const p of photos) {
      if (typeof p.gpsLat !== 'number' || typeof p.gpsLng !== 'number') continue;
      const clampedLat = Math.max(-85.0511, Math.min(85.0511, p.gpsLat));
      const latRad = (clampedLat * Math.PI) / 180;
      const x = ((p.gpsLng + 180) / 360) * worldSize;
      const y = ((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * worldSize;
      const bx = Math.floor(x / cellPx);
      const by = Math.floor(y / cellPx);
      const key = `${safeZoom}:${bx}:${by}`;
      if (!buckets.has(key)) {
        buckets.set(key, {
          id: key,
          latSum: 0,
          lngSum: 0,
          minLat: p.gpsLat,
          maxLat: p.gpsLat,
          minLng: p.gpsLng,
          maxLng: p.gpsLng,
          coverHash: p.hash,
          label: p.locationLabel || `${p.gpsLat.toFixed(3)}, ${p.gpsLng.toFixed(3)}`,
          photos: [],
        });
      }
      const b = buckets.get(key);
      b.latSum += p.gpsLat;
      b.lngSum += p.gpsLng;
      if (p.gpsLat < b.minLat) b.minLat = p.gpsLat;
      if (p.gpsLat > b.maxLat) b.maxLat = p.gpsLat;
      if (p.gpsLng < b.minLng) b.minLng = p.gpsLng;
      if (p.gpsLng > b.maxLng) b.maxLng = p.gpsLng;
      b.photos.push(p);
    }

    return Array.from(buckets.values()).map((b) => ({
      id: b.id,
      lat: b.latSum / b.photos.length,
      lng: b.lngSum / b.photos.length,
      minLat: b.minLat,
      maxLat: b.maxLat,
      minLng: b.minLng,
      maxLng: b.maxLng,
      count: b.photos.length,
      coverHash: b.coverHash,
      label: b.label,
      hashes: b.photos.map((p) => p.hash),
      photos: b.photos,
    }));
  }

  function createPinDomNode(cluster, isActive) {
    const wrap = document.createElement('button');
    wrap.type = 'button';
    wrap.className = `photo-map-pin${isActive ? ' is-active' : ''}`;
    wrap.title = `${cluster.label} (${cluster.count} ${cluster.count === 1 ? 'item' : 'items'})`;
    wrap.setAttribute('aria-label', wrap.title);

    const img = document.createElement('img');
    img.className = 'photo-map-pin-thumb';
    img.alt = '';
    img.loading = 'lazy';
    wrap.appendChild(img);
    if (cluster.coverHash) attachPreviewToImg(img, cluster.coverHash);

    if (cluster.count > 1) {
      const badge = document.createElement('span');
      badge.className = 'photo-map-pin-badge';
      badge.textContent = cluster.count > 999 ? '999+' : String(cluster.count);
      wrap.appendChild(badge);
    }

    const tip = document.createElement('span');
    tip.className = 'photo-map-pin-tip';
    wrap.appendChild(tip);
    return wrap;
  }

  function handleVisualPinClick(cluster, currentZoom) {
    const spread = Math.max(
      Math.abs(cluster.maxLat - cluster.minLat),
      Math.abs(cluster.maxLng - cluster.minLng)
    );
    const sameAlreadySelected =
      state.selectedMapFilter && state.selectedMapFilter.id === cluster.id;

    // Clicking an already-selected single photo pin opens it directly in Lightbox
    if (sameAlreadySelected && cluster.count === 1) {
      const targetHash = String(cluster.coverHash || '').toLowerCase();
      const idx = state.visibleFlatPhotos.findIndex(
        (p) => String(p.hash || '').toLowerCase() === targetHash
      );
      if (idx >= 0) {
        openLightbox(idx);
        return;
      }
    }

    // Select the cluster's photos in the timeline grid below
    state.selectedMapClusterId = null;
    state.selectedMapFilter = {
      id: cluster.id,
      label: cluster.label,
      lat: cluster.lat,
      lng: cluster.lng,
      count: cluster.count,
      hashes: new Set(cluster.hashes.map((h) => String(h).toLowerCase())),
    };

    // If zoomed out on a multi-photo cluster with real geographic spread, zoom in to split pins
    if (cluster.count > 1 && currentZoom < 14 && spread > 0.002) {
      fitMapToCoords(cluster.photos);
    } else if (currentZoom < 12) {
      focusMapOnLatLng(cluster.lat, cluster.lng, Math.max(currentZoom + 3, 12));
    }

    updateMapSelectedHeader();
    renderMapPlacePills();
    renderGallery();
    renderMapMarkers();
  }

  function focusMapOnLatLng(lat, lng, zoom = 12) {
    if (state.mapProvider === 'google' && mapRuntime.googleMap) {
      mapRuntime.googleMap.panTo({ lat, lng });
      mapRuntime.googleMap.setZoom(zoom);
    } else if (mapRuntime.leafletMap) {
      mapRuntime.leafletMap.flyTo([lat, lng], zoom, { duration: 0.45 });
    }
  }

  function fitMapToCoords(photos) {
    const valid = (photos || []).filter(
      (p) => typeof p.gpsLat === 'number' && typeof p.gpsLng === 'number'
    );
    if (valid.length === 0) {
      if (state.mapProvider === 'google' && mapRuntime.googleMap) {
        mapRuntime.googleMap.setCenter({ lat: 20, lng: 0 });
        mapRuntime.googleMap.setZoom(2);
      } else if (mapRuntime.leafletMap) {
        mapRuntime.leafletMap.setView([20, 0], 2);
      }
      return;
    }
    if (valid.length === 1) {
      focusMapOnLatLng(valid[0].gpsLat, valid[0].gpsLng, 13);
      return;
    }

    if (state.mapProvider === 'google' && mapRuntime.googleMap && window.google?.maps) {
      const bounds = new window.google.maps.LatLngBounds();
      for (const p of valid) bounds.extend({ lat: p.gpsLat, lng: p.gpsLng });
      mapRuntime.googleMap.fitBounds(bounds, 56);
    } else if (mapRuntime.leafletMap && window.L) {
      const bounds = window.L.latLngBounds(valid.map((p) => [p.gpsLat, p.gpsLng]));
      mapRuntime.leafletMap.fitBounds(bounds, { padding: [52, 52], maxZoom: 15 });
    }
  }

  function renderMapMarkers() {
    clearActiveMapMarkers();
    const photos = getActiveMapPhotos();
    if (photos.length === 0) return;

    if (state.mapProvider === 'google' && mapRuntime.googleMap && window.google?.maps) {
      const gmaps = window.google.maps;
      const zoom = mapRuntime.googleMap.getZoom() || 2;
      const clusters = buildZoomClusters(photos, zoom);

      class PhotoPinOverlay extends gmaps.OverlayView {
        constructor(cluster) {
          super();
          this.cluster = cluster;
          this.el = null;
        }
        onAdd() {
          const isActive = Boolean(
            state.selectedMapFilter && state.selectedMapFilter.id === this.cluster.id
          );
          const wrap = createPinDomNode(this.cluster, isActive);
          wrap.style.position = 'absolute';
          wrap.addEventListener('click', (e) => {
            e.stopPropagation();
            handleVisualPinClick(this.cluster, mapRuntime.googleMap.getZoom() || 2);
          });
          this.el = wrap;
          const panes = this.getPanes();
          if (panes && panes.overlayMouseTarget) {
            panes.overlayMouseTarget.appendChild(wrap);
          }
        }
        draw() {
          if (!this.el) return;
          const proj = this.getProjection();
          if (!proj) return;
          const pt = proj.fromLatLngToDivPixel(new gmaps.LatLng(this.cluster.lat, this.cluster.lng));
          if (!pt) return;
          this.el.style.left = `${Math.round(pt.x - 25)}px`;
          this.el.style.top = `${Math.round(pt.y - 54)}px`;
        }
        onRemove() {
          if (this.el && this.el.parentNode) {
            this.el.parentNode.removeChild(this.el);
          }
          this.el = null;
        }
      }

      for (const c of clusters) {
        const ov = new PhotoPinOverlay(c);
        ov.setMap(mapRuntime.googleMap);
        mapRuntime.googleOverlays.push(ov);
      }
      return;
    }

    if (mapRuntime.leafletMap && mapRuntime.leafletMarkersLayer && window.L) {
      const L = window.L;
      const zoom = mapRuntime.leafletMap.getZoom() || 2;
      const clusters = buildZoomClusters(photos, zoom);
      for (const c of clusters) {
        const isActive = Boolean(
          state.selectedMapFilter && state.selectedMapFilter.id === c.id
        );
        const icon = L.divIcon({
          className: 'photo-map-div-icon',
          html: '',
          iconSize: [50, 56],
          iconAnchor: [25, 56],
        });
        const marker = L.marker([c.lat, c.lng], { icon });
        marker.addTo(mapRuntime.leafletMarkersLayer);
        const rootEl = marker.getElement();
        if (rootEl) {
          const pinNode = createPinDomNode(c, isActive);
          pinNode.addEventListener('click', (e) => {
            e.stopPropagation();
            handleVisualPinClick(c, mapRuntime.leafletMap.getZoom() || 2);
          });
          rootEl.appendChild(pinNode);
        }
      }
    }
  }

  function updateMapSelectedHeader() {
    const header = $('mapSelectedHeader');
    if (!header) return;
    const sel = state.selectedMapFilter;
    header.classList.toggle('hidden', !sel);
    if (!sel) return;
    $('mapSelectedTitle').textContent = `📍 ${sel.label} · ${sel.count} photo(s)`;
    const gLink = $('mapOpenGoogleLink');
    if (gLink && typeof sel.lat === 'number' && typeof sel.lng === 'number') {
      gLink.href = getGoogleMapsLink(sel.lat, sel.lng);
      gLink.classList.remove('hidden');
    } else if (gLink) {
      gLink.classList.add('hidden');
    }
  }

  function updateMapControlLabels() {
    const googleKey = state.mapData?.mapConfig?.googleMapsApiKey;
    const toggleBtn = $('mapProviderToggleBtn');
    if (toggleBtn) {
      toggleBtn.classList.toggle('hidden', !googleKey);
      toggleBtn.textContent =
        state.mapProvider === 'google' ? 'Use Open Map' : 'Use Google Maps';
    }
    const osmBtn = document.querySelector('#mapStyleControl [data-map-style="osm"]');
    if (osmBtn) {
      osmBtn.textContent = state.mapProvider === 'google' ? 'Terrain' : 'OSM';
    }
    document.querySelectorAll('#mapStyleControl .seg-btn').forEach((b) => {
      b.classList.toggle('is-active', b.dataset.mapStyle === state.mapStyle);
    });
  }

  function renderMapPlacePills() {
    const pillsLayer = $('mapPlacePills');
    if (!pillsLayer || !state.mapData) return;
    const clusters = Array.isArray(state.mapData.clusters) ? state.mapData.clusters : [];
    pillsLayer.innerHTML = '';

    for (const c of clusters) {
      const isSelected = state.selectedMapClusterId === c.id;
      const pill = document.createElement('button');
      pill.type = 'button';
      pill.className = `year-pill${isSelected ? ' is-active' : ''}`;
      pill.textContent = `📍 ${c.label} (${c.count})`;
      pill.addEventListener('click', () => {
        if (isSelected) {
          state.selectedMapClusterId = null;
          state.selectedMapFilter = null;
          fitMapToCoords(getActiveMapPhotos());
        } else {
          state.selectedMapClusterId = c.id;
          const allowed = new Set(c.hashes.map((h) => String(h).toLowerCase()));
          state.selectedMapFilter = {
            id: c.id,
            label: c.label,
            lat: c.lat,
            lng: c.lng,
            count: c.count,
            hashes: allowed,
          };
          const matching = getActiveMapPhotos().filter((p) =>
            allowed.has(String(p.hash).toLowerCase())
          );
          if (matching.length > 1) {
            fitMapToCoords(matching);
          } else {
            focusMapOnLatLng(c.lat, c.lng, 12);
          }
        }
        updateMapSelectedHeader();
        renderMapPlacePills();
        renderMapMarkers();
        renderGallery();
      });
      pillsLayer.appendChild(pill);
    }
  }

  async function initAndRenderInteractiveMap({ fitBounds = false } = {}) {
    if (state.filterMedia !== 'map') return;
    const leafletEl = $('leafletMapCanvas');
    const googleEl = $('googleMapCanvas');
    if (!leafletEl || !googleEl) return;

    const googleKey = state.mapData?.mapConfig?.googleMapsApiKey || null;
    if (!state.mapProviderUserChosen) {
      state.mapProvider = googleKey ? 'google' : 'leaflet';
    }
    if (state.mapProvider === 'google' && !googleKey) {
      state.mapProvider = 'leaflet';
    }
    updateMapControlLabels();

    setMapLoading(
      true,
      state.mapProvider === 'google' ? 'Loading Google Maps…' : 'Loading interactive map…'
    );

    if (state.mapProvider === 'google' && googleKey) {
      leafletEl.classList.add('hidden');
      googleEl.classList.remove('hidden');
      try {
        const gmaps = await ensureGoogleMapsLoaded(googleKey);
        if (!mapRuntime.googleMap) {
          mapRuntime.googleMap = new gmaps.Map(googleEl, {
            center: { lat: 20, lng: 0 },
            zoom: 2,
            mapTypeId: 'roadmap',
            mapTypeControl: false,
            streetViewControl: true,
            fullscreenControl: true,
            gestureHandling: 'greedy',
          });
          mapRuntime.googleMap.addListener('zoom_changed', () => {
            renderMapMarkers();
          });
        }
        applyGoogleMapStyle();
        setMapLoading(false);
        if (fitBounds || !state.mapHasFittedOnce) {
          state.mapHasFittedOnce = true;
          fitMapToCoords(getActiveMapPhotos());
        }
        renderMapMarkers();
        return;
      } catch (err) {
        console.warn('[PhotoMap] Google Maps failed, falling back to Leaflet:', err);
        state.mapProvider = 'leaflet';
        updateMapControlLabels();
        showToast('Google Maps unavailable — switched to built-in Open Map.', 'amber');
      }
    }

    // Default / Fallback: Leaflet with Carto Voyager / Dark Matter / Esri Satellite / OpenStreetMap
    googleEl.classList.add('hidden');
    leafletEl.classList.remove('hidden');
    try {
      const L = await ensureLeafletLoaded();
      if (!mapRuntime.leafletMap) {
        mapRuntime.leafletMap = L.map(leafletEl, {
          center: [20, 0],
          zoom: 2,
          minZoom: 2,
          maxZoom: 19,
          zoomControl: true,
          worldCopyJump: true,
        });
        mapRuntime.leafletMarkersLayer = L.layerGroup().addTo(mapRuntime.leafletMap);
        mapRuntime.leafletMap.on('zoomend', () => {
          renderMapMarkers();
        });
      }
      applyLeafletBaseLayer();
      setMapLoading(false);

      const refreshView = () => {
        if (!mapRuntime.leafletMap) return;
        mapRuntime.leafletMap.invalidateSize(false);
        if (fitBounds || !state.mapHasFittedOnce) {
          state.mapHasFittedOnce = true;
          fitMapToCoords(getActiveMapPhotos());
        }
        renderMapMarkers();
      };
      requestAnimationFrame(refreshView);
      setTimeout(() => {
        if (mapRuntime.leafletMap && state.filterMedia === 'map') {
          mapRuntime.leafletMap.invalidateSize(false);
        }
      }, 180);
    } catch (err) {
      setMapLoading(
        true,
        'Map tiles unavailable offline. You can still browse places below.'
      );
      console.warn('[PhotoMap] Leaflet load error:', err);
    }
  }

  async function loadPhotoMap({ rescan = false } = {}) {
    if (!state.session) return;
    const rescanBtn = $('mapRescanBtn');
    if (rescan && rescanBtn) {
      rescanBtn.disabled = true;
      rescanBtn.textContent = 'Scanning…';
    }
    try {
      const url = rescan ? '/api/photos/map?rescan=1' : '/api/photos/map';
      const res = await apiFetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      state.mapData = await res.json();
      if (rescan) {
        const found = Number(state.mapData.newlyFoundGps) || 0;
        const scanned = Number(state.mapData.scannedNow) || 0;
        showToast(
          found > 0
            ? `Found GPS on ${found} more item(s) (${scanned} scanned)`
            : `GPS scan complete (${scanned} checked · ${state.mapData.geoTaggedCount || 0} total mapped)`,
          'mint'
        );
      }
      renderPhotoMap({ fitBounds: rescan || !state.mapHasFittedOnce });
      renderGallery();
    } catch (err) {
      showToast(err.message || 'Could not load photo map', 'rose');
    } finally {
      if (rescan && rescanBtn) {
        rescanBtn.disabled = false;
        rescanBtn.textContent = '↻ Scan GPS';
      }
    }
  }

  function renderPhotoMap({ fitBounds = false } = {}) {
    const data = state.mapData;
    if (!data) return;

    const clusters = Array.isArray(data.clusters) ? data.clusters : [];
    const remainingNote =
      data.remainingToScan > 0 ? ` · ${data.remainingToScan} more file(s) ready to Scan GPS` : '';
    $('mapSummaryText').textContent =
      data.geoTaggedCount > 0
        ? `${data.geoTaggedCount} geo-tagged item(s) across ${clusters.length} location(s) · Zoom in to explore streets or click any photo pin${remainingNote}`
        : `No GPS tags detected yet (${data.totalPhotos || 0} total). Click "Scan GPS" to index existing HEIC, JPEG & video locations.`;

    renderMapPlacePills();
    updateMapSelectedHeader();
    initAndRenderInteractiveMap({ fitBounds });
  }

  // ==================== SMART CLEANUP STUDIO (SIMILAR / BURST / BLURRY) ====================
  async function openCleanupModal(scan = true) {
    $('cleanupModal').classList.remove('hidden');
    $('cleanupSummaryText').textContent = 'Analyzing photos for burst shots, near-duplicates, and blurry frames…';
    $('cleanupContent').innerHTML = '<div class="muted-text" style="padding:26px;text-align:center;">Running visual similarity &amp; sharpness scan…</div>';
    state.cleanupSelectedHashes.clear();
    updateCleanupTrashButton();

    try {
      const res = await apiFetch(`/api/photos/cleanup-suggestions?scan=${scan ? '1' : '0'}`);
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.success) throw new Error(data.error || 'Cleanup scan failed');
      state.cleanupReport = data;

      // Auto-preselect non-best duplicates so 1 click cleans up burst clutter safely
      for (const grp of data.similarGroups || []) {
        for (const p of grp.photos || []) {
          if (!p.isBest && !p.isFavorite && !p.keepOriginalOnDevice) {
            state.cleanupSelectedHashes.add(p.hash.toLowerCase());
          }
        }
      }
      renderCleanupStudio();
    } catch (err) {
      $('cleanupContent').innerHTML = `<div class="error-banner">${err.message || 'Could not run cleanup scan'}</div>`;
    }
  }

  function closeCleanupModal() {
    $('cleanupModal').classList.add('hidden');
  }

  function updateCleanupTrashButton() {
    const btn = $('cleanupTrashSelectedBtn');
    if (!btn) return;
    const count = state.cleanupSelectedHashes.size;
    btn.disabled = count === 0;
    btn.textContent = count > 0 ? `Move ${count} to Trash` : 'Move Selected to Trash';
  }

  function renderCleanupStudio() {
    const rep = state.cleanupReport;
    if (!rep) return;
    const s = rep.summary || {};
    $('cleanupSimCount').textContent = String(s.similarGroupCount || 0);
    $('cleanupBlurCount').textContent = String(s.blurryCount || 0);
    $('cleanupSummaryText').textContent =
      `Analyzed ${s.analyzedCount || 0}/${s.totalPhotos || 0} photo(s) · Potential savings ${formatBytes(s.potentialSavingsBytes || 0)}${s.pendingCount > 0 ? ` · ${s.pendingCount} more ready to scan` : ''}`;
    $('cleanupRescanBtn').classList.toggle('hidden', !(s.pendingCount > 0));

    const box = $('cleanupContent');
    box.innerHTML = '';

    if (state.cleanupTab === 'similar') {
      const groups = rep.similarGroups || [];
      if (groups.length === 0) {
        box.innerHTML = '<div class="empty-state" style="padding:30px 10px;"><h3>No Similar or Burst Clutter Found</h3><p>Your library looks super tidy!</p></div>';
        updateCleanupTrashButton();
        return;
      }
      for (const grp of groups) {
        const gEl = document.createElement('div');
        gEl.className = 'cleanup-group';
        const head = document.createElement('div');
        head.className = 'cleanup-group-head';
        head.innerHTML = `<strong></strong><span class="muted-text"></span>`;
        head.querySelector('strong').textContent = grp.label;
        head.querySelector('span').textContent = `Save up to ${formatBytes(grp.reclaimableBytes)}`;
        gEl.appendChild(head);

        const cards = document.createElement('div');
        cards.className = 'cleanup-cards';
        for (const p of grp.photos) {
          const norm = p.hash.toLowerCase();
          const picked = state.cleanupSelectedHashes.has(norm);
          const card = document.createElement('div');
          card.className = `cleanup-card${p.isBest ? ' is-best' : ''}${picked ? ' is-picked' : ''}`;
          const img = document.createElement('img');
          img.alt = p.originalName || '';
          card.appendChild(img);
          attachPreviewToImg(img, p.hash);

          const tag = document.createElement('span');
          tag.className = `cleanup-tag ${picked ? 'cleanup-tag--trash' : p.isBest ? 'cleanup-tag--best' : ''}`;
          tag.textContent = picked ? 'Trash' : p.isBest ? '★ Best Shot' : 'Keep';
          card.appendChild(tag);

          const foot = document.createElement('div');
          foot.className = 'cleanup-foot';
          foot.innerHTML = `<span>${formatBytes(p.size)}</span><span>${typeof p.blurScore === 'number' ? '⚡' + Math.round(p.blurScore) : ''}</span>`;
          card.appendChild(foot);

          card.addEventListener('click', () => {
            if (state.cleanupSelectedHashes.has(norm)) state.cleanupSelectedHashes.delete(norm);
            else state.cleanupSelectedHashes.add(norm);
            renderCleanupStudio();
          });
          cards.appendChild(card);
        }
        gEl.appendChild(cards);
        box.appendChild(gEl);
      }
    } else {
      const blurry = rep.blurryPhotos || [];
      if (blurry.length === 0) {
        box.innerHTML = '<div class="empty-state" style="padding:30px 10px;"><h3>No Blurry Shots Detected</h3><p>All analyzed photos look crisp and focused.</p></div>';
        updateCleanupTrashButton();
        return;
      }
      const gEl = document.createElement('div');
      gEl.className = 'cleanup-group';
      const cards = document.createElement('div');
      cards.className = 'cleanup-cards';
      for (const p of blurry) {
        const norm = p.hash.toLowerCase();
        const picked = state.cleanupSelectedHashes.has(norm);
        const card = document.createElement('div');
        card.className = `cleanup-card${picked ? ' is-picked' : ''}`;
        const img = document.createElement('img');
        img.alt = p.originalName || '';
        card.appendChild(img);
        attachPreviewToImg(img, p.hash);

        const tag = document.createElement('span');
        tag.className = `cleanup-tag ${picked ? 'cleanup-tag--trash' : ''}`;
        tag.textContent = picked ? 'Trash' : `Blur ${Math.round(p.blurScore || 0)}`;
        card.appendChild(tag);

        const foot = document.createElement('div');
        foot.className = 'cleanup-foot';
        foot.innerHTML = `<span>${formatBytes(p.size)}</span><span>${p.photoDate || ''}</span>`;
        card.appendChild(foot);

        card.addEventListener('click', () => {
          if (state.cleanupSelectedHashes.has(norm)) state.cleanupSelectedHashes.delete(norm);
          else state.cleanupSelectedHashes.add(norm);
          renderCleanupStudio();
        });
        cards.appendChild(card);
      }
      gEl.appendChild(cards);
      box.appendChild(gEl);
    }
    updateCleanupTrashButton();
  }

  // ==================== LIGHTBOX ====================
  function applyLightboxZoomTransform() {
    const img = $('lbImage');
    if (!img) return;
    const zoomed = state.lightboxZoom > 1.01;
    img.classList.toggle('is-zoomed', zoomed);
    if (!zoomed) {
      state.lightboxZoom = 1;
      state.lightboxPanX = 0;
      state.lightboxPanY = 0;
      img.style.transform = '';
    } else {
      img.style.transform = `translate3d(${state.lightboxPanX}px, ${state.lightboxPanY}px, 0) scale(${state.lightboxZoom})`;
    }
  }

  function resetLightboxZoom() {
    state.lightboxZoom = 1;
    state.lightboxPanX = 0;
    state.lightboxPanY = 0;
    applyLightboxZoomTransform();
  }

  function renderLightboxInfoPanel(photo) {
    const list = $('lbInfoList');
    if (!list || !photo) return;
    const rows = [
      ['Filename', photo.originalName || '—'],
      ['Date', photo.takenAt ? new Date(photo.takenAt).toLocaleString() : photo.photoDate || 'Undated'],
      ['Original Size', formatBytes(photo.size)],
      ['Proxy Size', photo.proxySize ? formatBytes(photo.proxySize) : photo.videoProxySize ? formatBytes(photo.videoProxySize) : 'None'],
      ['Camera', photo.cameraModel || '—'],
      ['Location', photo.locationLabel || (typeof photo.gpsLat === 'number' ? `${photo.gpsLat.toFixed(4)}, ${photo.gpsLng.toFixed(4)}` : '—')],
      ['Verification', `SHA-256 Verified (${String(photo.hash || '').slice(0, 12)}…)`],
    ];
    if (photo.width && photo.height) {
      rows.splice(3, 0, ['Resolution', `${photo.width} × ${photo.height}`]);
    }
    if (typeof photo.blurScore === 'number') {
      rows.push(['Sharpness', `${Math.round(photo.blurScore)} (${photo.blurScore < 35 ? 'Soft / Blurry' : 'Sharp'})`]);
    }
    if (photo.deletedAt) {
      rows.push(['Trashed', `${new Date(photo.deletedAt).toLocaleDateString()} (${photo.daysRemaining ?? 30}d left)`]);
    }
    list.innerHTML = '';
    for (const [label, value] of rows) {
      const dt = document.createElement('dt');
      dt.textContent = label;
      const dd = document.createElement('dd');
      dd.textContent = value;
      if (
        label === 'Location' &&
        typeof photo.gpsLat === 'number' &&
        typeof photo.gpsLng === 'number'
      ) {
        dd.appendChild(document.createElement('br'));
        const mapLink = document.createElement('a');
        mapLink.className = 'lb-maps-link';
        mapLink.href = getGoogleMapsLink(photo.gpsLat, photo.gpsLng);
        mapLink.target = '_blank';
        mapLink.rel = 'noopener noreferrer';
        mapLink.textContent = `Open in Google Maps (${photo.gpsLat.toFixed(4)}, ${photo.gpsLng.toFixed(4)}) ↗`;
        dd.appendChild(mapLink);
      }
      list.appendChild(dt);
      list.appendChild(dd);
    }
  }

  function cleanupLightboxMedia() {
    const img = $('lbImage');
    const vid = $('lbVideo');
    vid.pause();
    vid.removeAttribute('src');
    vid.load();
    vid.classList.add('hidden');
    img.classList.add('hidden');
    img.removeAttribute('src');
    resetLightboxZoom();
    $('lbDownloadBar').classList.add('hidden');
  }

  function openLightbox(index) {
    if (index < 0 || index >= state.visibleFlatPhotos.length) return;
    state.lightboxIndex = index;
    $('lightbox').classList.remove('hidden', 'is-immersive');
    $('lbInfoPanel').classList.add('hidden');
    document.body.style.overflow = 'hidden';
    renderLightboxItem();
  }

  function closeLightbox() {
    cleanupLightboxMedia();
    $('lightbox').classList.add('hidden', 'is-immersive');
    $('lbInfoPanel').classList.add('hidden');
    document.body.style.overflow = '';
    state.lightboxIndex = -1;
  }

  async function renderLightboxItem() {
    const photo = state.visibleFlatPhotos[state.lightboxIndex];
    if (!photo) return;
    cleanupLightboxMedia();

    const isVid = isVideoPhoto(photo);
    const isTrash = state.filterMedia === 'trash' || Boolean(photo.deletedAt);
    $('lbFilename').textContent = photo.originalName || photo.hash.slice(0, 12);
    const dateStr = photo.photoDate || (photo.uploadedAt || '').slice(0, 10) || 'Undated';
    $('lbMeta').textContent = `${dateStr} · Original ${formatBytes(photo.size)}`;

    $('lbPrevBtn').disabled = state.lightboxIndex <= 0;
    $('lbNextBtn').disabled = state.lightboxIndex >= state.visibleFlatPhotos.length - 1;

    const favBtn = $('lbFavBtn');
    favBtn.classList.toggle('hidden', isTrash);
    favBtn.classList.toggle('is-fav', Boolean(photo.isFavorite));
    favBtn.textContent = photo.isFavorite ? '♥' : '♡';

    const badges = $('lbBadges');
    badges.innerHTML = '';
    if (isVid) {
      badges.innerHTML += `<span class="mini-badge mini-badge--orange">Video</span>`;
    }
    if (photo.isFavorite) {
      badges.innerHTML += `<span class="mini-badge mini-badge--orange">♥ Favorite</span>`;
    }
    if (photo.keepOriginalOnDevice) {
      badges.innerHTML += `<span class="mini-badge mini-badge--mint">Protected Original</span>`;
    }
    if (photo.proxySize) {
      badges.innerHTML += `<span class="mini-badge mini-badge--amber">Proxy ${formatBytes(photo.proxySize)}</span>`;
    }

    $('lbProtectBtn').classList.toggle('hidden', isTrash);
    $('lbShareBtn').classList.toggle('hidden', isTrash);
    $('lbAlbumBtn').classList.toggle('hidden', isTrash);
    $('lbRestoreBtn').classList.toggle('hidden', !isTrash);
    $('lbProtectBtn').textContent = photo.keepOriginalOnDevice ? 'Allow Re-Proxy' : 'Protect';
    $('lbDeleteBtn').textContent = isTrash ? 'Delete Forever' : 'Trash';
    renderLightboxInfoPanel(photo);

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
      preloadAdjacentLightboxItems(state.lightboxIndex);
      return;
    }

    // Progressive Lightbox: immediately display the cached grid thumbnail (0ms, zero spinner flash!)
    // while fetching the full 1440px-1920px proxy in the background and swapping seamlessly.
    const img = $('lbImage');
    const cachedFullUrl = lbPreviewCache.get(photo.hash) || null;
    const cachedGridThumb = !cachedFullUrl ? thumbUrlCache.get(photo.hash) || null : null;
    if (cachedGridThumb) {
      img.src = cachedGridThumb;
      img.classList.remove('hidden');
      spinner.classList.add('hidden');
    }

    try {
      const objUrl = await fetchLightboxPreviewCached(photo.hash);
      if (!objUrl) throw new Error('Preview unavailable');
      if (state.visibleFlatPhotos[state.lightboxIndex]?.hash !== photo.hash) return;
      img.src = objUrl;
      if (img.complete && img.naturalWidth > 0) {
        spinner.classList.add('hidden');
        img.classList.remove('hidden');
      } else {
        img.onload = () => {
          spinner.classList.add('hidden');
          img.classList.remove('hidden');
        };
      }
      preloadAdjacentLightboxItems(state.lightboxIndex);
    } catch {
      spinner.classList.add('hidden');
      if (!cachedGridThumb) {
        showToast('Preview not available — tap Original to download.', 'amber');
      }
    }
  }

  async function toggleLightboxFavorite() {
    const photo = state.visibleFlatPhotos[state.lightboxIndex];
    if (!photo) return;
    const nextFav = !photo.isFavorite;
    try {
      const res = await apiFetch(`/api/photo/${encodeURIComponent(photo.hash)}/favorite`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ isFavorite: nextFav }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Could not update favorite');
      photo.isFavorite = nextFav;
      const norm = String(photo.hash || '').toLowerCase();
      for (const list of [state.photos, state.protectedPhotos, state.activeAlbumPhotos]) {
        for (const p of list) {
          if (String(p.hash || '').toLowerCase() === norm) p.isFavorite = nextFav;
        }
      }
      if (nextFav) {
        if (!state.favoritePhotos.some((p) => String(p.hash || '').toLowerCase() === norm)) {
          state.favoritePhotos.unshift({ ...(data.photo || photo), isFavorite: true });
        }
        state.favoriteCount =
          typeof data.favoriteCount === 'number'
            ? data.favoriteCount
            : state.favoriteLoadedOnce
              ? state.favoritePhotos.length
              : state.favoriteCount + 1;
      } else {
        state.favoritePhotos = state.favoritePhotos.filter(
          (p) => String(p.hash || '').toLowerCase() !== norm
        );
        state.favoriteCount =
          typeof data.favoriteCount === 'number'
            ? data.favoriteCount
            : state.favoriteLoadedOnce
              ? state.favoritePhotos.length
              : Math.max(0, state.favoriteCount - 1);
      }
      applyServerCategoryCounts(data);
      state.photosEtag = null;
      updateFavoriteBadge();
      const favBtn = $('lbFavBtn');
      favBtn.classList.toggle('is-fav', nextFav);
      favBtn.textContent = nextFav ? '♥' : '♡';
      if (state.filterMedia === 'favorite' && !nextFav) {
        closeLightbox();
      }
      renderGallery();
      showToast(nextFav ? 'Added to Favorites ♥' : 'Removed from Favorites', 'mint');
    } catch (err) {
      showToast(err.message || 'Could not update favorite', 'rose');
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
      const norm = String(photo.hash || '').toLowerCase();
      state.protectedLoadSeq += 1;
      applyProtectedDeltaLocally([norm], data.photo ? [data.photo] : [photo], nextProtected, data);
      updateProtectedBannerUI();
      if (state.filterMedia === 'protected' && !nextProtected) {
        closeLightbox();
      } else {
        renderLightboxItem();
      }
      renderGallery();
      showToast(
        nextProtected
          ? 'Protected from auto re-compression'
          : 'Unlocked — synced with phone to allow re-proxy.',
        'mint'
      );
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

  // ==================== INVISIBLE WHOLE-PAGE DRAG & DROP UPLOAD ====================
  const MEDIA_UPLOAD_EXTS = new Set([
    'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif', 'bmp', 'tif', 'tiff', 'avif',
    'dng', 'raw', 'cr2', 'nef', 'arw',
    'mov', 'mp4', 'm4v', '3gp', 'avi', 'mkv', 'webm',
  ]);
  const UPLOAD_CONCURRENCY = 3;
  const CLIENT_HASH_MAX_BYTES = 120 * 1024 * 1024; // 120 MB browser SubtleCrypto pre-check cap

  const uploadState = {
    queue: [],
    activeXhrs: new Set(),
    activeChunkUploadIds: new Set(),
    inFlightBytes: new Map(),
    isRunning: false,
    cancelled: false,
    quotaExceeded: false,
    totalCount: 0,
    completedCount: 0,
    uploadedCount: 0,
    duplicateCount: 0,
    failedCount: 0,
    totalBytes: 0,
    completedBytes: 0,
    currentFilename: '',
    currentDetail: '',
    hideTimer: null,
  };

  function loadChunkResumeMap() {
    try {
      return JSON.parse(localStorage.getItem(CHUNK_RESUME_KEY) || '{}') || {};
    } catch {
      return {};
    }
  }

  function saveChunkResumeId(fileKey, uploadId) {
    try {
      const map = loadChunkResumeMap();
      if (uploadId) map[fileKey] = { uploadId, ts: Date.now() };
      else delete map[fileKey];
      localStorage.setItem(CHUNK_RESUME_KEY, JSON.stringify(map));
    } catch {
      // ignore storage errors
    }
  }

  function isSupportedMediaFile(file) {
    if (!file || !file.name || file.size <= 0) return false;
    if (file.name.startsWith('.') || /^thumbs\.db$/i.test(file.name)) return false;
    const type = String(file.type || '').toLowerCase();
    if (type.startsWith('image/') || type.startsWith('video/')) return true;
    const dot = file.name.lastIndexOf('.');
    if (dot < 0) return false;
    return MEDIA_UPLOAD_EXTS.has(file.name.slice(dot + 1).toLowerCase());
  }

  function readAllDirectoryEntries(dirReader) {
    return new Promise((resolve) => {
      const all = [];
      const readNext = () => {
        dirReader.readEntries(
          (batch) => {
            if (!batch || batch.length === 0) {
              resolve(all);
            } else {
              all.push(...batch);
              readNext();
            }
          },
          () => resolve(all)
        );
      };
      readNext();
    });
  }

  async function collectFilesFromEntry(entry) {
    if (!entry) return [];
    if (entry.isFile) {
      return new Promise((resolve) => {
        entry.file(
          (f) => resolve(f ? [f] : []),
          () => resolve([])
        );
      });
    }
    if (entry.isDirectory) {
      const entries = await readAllDirectoryEntries(entry.createReader());
      const out = [];
      for (const child of entries) {
        const nested = await collectFilesFromEntry(child);
        out.push(...nested);
      }
      return out;
    }
    return [];
  }

  async function extractDroppedFiles(dataTransfer) {
    if (!dataTransfer) return [];
    const items = dataTransfer.items ? Array.from(dataTransfer.items) : [];
    const entries = [];
    for (const item of items) {
      if (item && item.kind === 'file' && typeof item.webkitGetAsEntry === 'function') {
        const entry = item.webkitGetAsEntry();
        if (entry) entries.push(entry);
      }
    }
    if (entries.length > 0) {
      const collected = [];
      for (const entry of entries) {
        const files = await collectFilesFromEntry(entry);
        collected.push(...files);
      }
      if (collected.length > 0) return collected;
    }
    return dataTransfer.files ? Array.from(dataTransfer.files) : [];
  }

  async function computeFileSha256Hex(file) {
    if (!window.crypto || !window.crypto.subtle || file.size > CLIENT_HASH_MAX_BYTES) {
      return '';
    }
    try {
      const buf = await file.arrayBuffer();
      const digest = await window.crypto.subtle.digest('SHA-256', buf);
      return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('');
    } catch {
      return '';
    }
  }

  function renderUploadTray() {
    const tray = $('uploadTray');
    if (!tray) return;
    tray.classList.remove('hidden');

    let inFlightLoaded = 0;
    for (const v of uploadState.inFlightBytes.values()) inFlightLoaded += v;
    const loadedBytes = Math.min(uploadState.totalBytes, uploadState.completedBytes + inFlightLoaded);
    const pct =
      uploadState.totalBytes > 0
        ? Math.min(100, Math.round((loadedBytes / uploadState.totalBytes) * 100))
        : uploadState.totalCount > 0
          ? Math.min(100, Math.round((uploadState.completedCount / uploadState.totalCount) * 100))
          : 0;

    $('uploadTrayFill').style.width = `${Math.max(3, pct)}%`;

    if (uploadState.isRunning) {
      const idx = Math.min(uploadState.totalCount, uploadState.completedCount + 1);
      $('uploadTrayTitle').textContent = `Backing up ${idx} of ${uploadState.totalCount} (${pct}%)`;
      $('uploadTraySub').textContent = uploadState.currentFilename
        ? `${uploadState.currentFilename} · ${formatBytes(loadedBytes)} / ${formatBytes(uploadState.totalBytes)}`
        : `${formatBytes(loadedBytes)} / ${formatBytes(uploadState.totalBytes)}`;
      $('uploadCancelBtn').classList.remove('hidden');
    } else {
      $('uploadCancelBtn').classList.add('hidden');
    }
  }

  function uploadFileWithProgress(file, sha256, onProgress) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      uploadState.activeXhrs.add(xhr);

      xhr.open('POST', apiUrlFor('/api/upload'), true);
      const token = state.session && state.session.token;
      if (token) {
        xhr.setRequestHeader('Authorization', `Bearer ${token}`);
      }
      xhr.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
      xhr.setRequestHeader('X-File-Name', encodeURIComponent(file.name));
      xhr.setRequestHeader('X-Upload-Source', 'web');
      if (file.lastModified) {
        xhr.setRequestHeader('X-Created-At', new Date(file.lastModified).toISOString());
      }
      if (sha256) {
        xhr.setRequestHeader('X-File-Sha256', sha256);
      }

      xhr.upload.onprogress = (ev) => {
        if (ev.lengthComputable && typeof onProgress === 'function') {
          onProgress(ev.loaded);
        }
      };

      const cleanup = () => uploadState.activeXhrs.delete(xhr);

      xhr.onload = () => {
        cleanup();
        let data = {};
        try {
          data = JSON.parse(xhr.responseText || '{}');
        } catch {
          data = {};
        }
        resolve({ status: xhr.status, ok: xhr.status >= 200 && xhr.status < 300, data });
      };
      xhr.onerror = () => {
        cleanup();
        reject(new Error('Network error during upload'));
      };
      xhr.onabort = () => {
        cleanup();
        const err = new Error('Cancelled');
        err.isAbort = true;
        reject(err);
      };

      xhr.send(file);
    });
  }

  async function uploadFileChunkedResumable(file, sha256, onProgress) {
    const fileKey = `${file.name}|${file.size}|${file.lastModified || 0}`;
    const resumeEntry = loadChunkResumeMap()[fileKey];
    const resumeUploadId = resumeEntry && resumeEntry.uploadId ? resumeEntry.uploadId : null;

    const initRes = await apiFetch('/api/upload/chunked/init', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        fileName: file.name,
        mimeType: file.type || 'application/octet-stream',
        fileSize: file.size,
        chunkSize: CHUNK_SIZE_BYTES,
        expectedHash: sha256 || '',
        createdAt: file.lastModified ? new Date(file.lastModified).toISOString() : '',
        resumeUploadId,
      }),
    });
    const initData = await initRes.json().catch(() => ({}));
    if (!initRes.ok || !initData.success) {
      return { status: initRes.status, ok: false, data: initData };
    }
    if (initData.alreadyExists) {
      saveChunkResumeId(fileKey, null);
      if (typeof onProgress === 'function') onProgress(file.size);
      return { status: 200, ok: true, data: initData };
    }

    const { uploadId, chunkSize, totalChunks } = initData;
    const uploadedSet = new Set(Array.isArray(initData.uploadedChunks) ? initData.uploadedChunks : []);
    saveChunkResumeId(fileKey, uploadId);
    uploadState.activeChunkUploadIds.add(uploadId);

    const chunkProgress = new Map();
    for (const idx of uploadedSet) {
      const start = idx * chunkSize;
      const end = Math.min(file.size, start + chunkSize);
      chunkProgress.set(idx, end - start);
    }
    const emitTotal = () => {
      let sum = 0;
      for (const v of chunkProgress.values()) sum += v;
      if (typeof onProgress === 'function') onProgress(Math.min(file.size, sum));
    };
    emitTotal();

    const pendingIndices = [];
    for (let i = 0; i < totalChunks; i++) {
      if (!uploadedSet.has(i)) pendingIndices.push(i);
    }

    const sendPartOnce = (idx, blob) =>
      new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        uploadState.activeXhrs.add(xhr);
        xhr.open('PUT', apiUrlFor(`/api/upload/chunked/${encodeURIComponent(uploadId)}/part/${idx}`), true);
        const token = state.session && state.session.token;
        if (token) xhr.setRequestHeader('Authorization', `Bearer ${token}`);
        xhr.setRequestHeader('Content-Type', 'application/octet-stream');
        xhr.upload.onprogress = (ev) => {
          if (ev.lengthComputable) {
            chunkProgress.set(idx, Math.min(blob.size, ev.loaded));
            emitTotal();
          }
        };
        const cleanup = () => uploadState.activeXhrs.delete(xhr);
        xhr.onload = () => {
          cleanup();
          if (xhr.status >= 200 && xhr.status < 300) {
            chunkProgress.set(idx, blob.size);
            emitTotal();
            resolve();
          } else {
            reject(new Error(`Chunk ${idx} failed with HTTP ${xhr.status}`));
          }
        };
        xhr.onerror = () => {
          cleanup();
          reject(new Error(`Network error on chunk ${idx}`));
        };
        xhr.onabort = () => {
          cleanup();
          const e = new Error('Cancelled');
          e.isAbort = true;
          reject(e);
        };
        xhr.send(blob);
      });

    const uploadOnePart = async (idx) => {
      const start = idx * chunkSize;
      const end = Math.min(file.size, start + chunkSize);
      const blob = file.slice(start, end);
      let lastErr;
      for (let attempt = 0; attempt < 3; attempt++) {
        if (uploadState.cancelled) {
          const e = new Error('Cancelled');
          e.isAbort = true;
          throw e;
        }
        try {
          await sendPartOnce(idx, blob);
          return;
        } catch (err) {
          if (err && err.isAbort) throw err;
          lastErr = err;
          await new Promise((r) => setTimeout(r, 600 * (attempt + 1)));
        }
      }
      throw lastErr || new Error(`Chunk ${idx} failed`);
    };

    try {
      const partWorkers = [];
      const partConcurrency = 2;
      const runWorker = async () => {
        while (!uploadState.cancelled && pendingIndices.length > 0) {
          const nextIdx = pendingIndices.shift();
          uploadState.currentFilename = `${file.name} (part ${nextIdx + 1}/${totalChunks})`;
          renderUploadTray();
          await uploadOnePart(nextIdx);
        }
      };
      for (let w = 0; w < Math.min(partConcurrency, Math.max(1, pendingIndices.length)); w++) {
        partWorkers.push(runWorker());
      }
      await Promise.all(partWorkers);

      if (uploadState.cancelled) {
        const e = new Error('Cancelled');
        e.isAbort = true;
        throw e;
      }

      uploadState.currentFilename = `${file.name} (verifying SHA-256…)`;
      renderUploadTray();
      const compRes = await apiFetch(`/api/upload/chunked/${encodeURIComponent(uploadId)}/complete`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Upload-Source': 'chunked-web',
        },
        body: JSON.stringify({ expectedHash: sha256 || '' }),
      });
      const compData = await compRes.json().catch(() => ({}));
      if (compRes.ok && compData.success) {
        saveChunkResumeId(fileKey, null);
      }
      return { status: compRes.status, ok: compRes.ok, data: compData };
    } finally {
      uploadState.activeChunkUploadIds.delete(uploadId);
    }
  }

  async function processOneDroppedFile(file) {
    if (uploadState.cancelled || uploadState.quotaExceeded) return;
    uploadState.currentFilename = file.name;
    uploadState.inFlightBytes.set(file, 0);
    renderUploadTray();

    try {
      // Never re-upload a PhotoHub compressed proxy as a brand-new original
      if (/^PHOTOHUB_PROXY_[a-f0-9]{8,}/i.test(String(file.name || '').trim())) {
        uploadState.duplicateCount++;
        return;
      }

      const sha256 = await computeFileSha256Hex(file);
      if (uploadState.cancelled || uploadState.quotaExceeded) return;

      // Intra-batch deduplication: if the user dropped duplicate copies in the same batch, skip immediately
      if (sha256) {
        if (!uploadState.seenHashes) uploadState.seenHashes = new Set();
        if (uploadState.seenHashes.has(sha256)) {
          uploadState.duplicateCount++;
          return;
        }
        uploadState.seenHashes.add(sha256);
      }

      // Fast pre-upload duplicate & proxy check so already-backed-up files finish instantly with zero upload bandwidth
      if (sha256) {
        try {
          const checkRes = await apiFetch(`/api/check/${encodeURIComponent(sha256)}`);
          if (checkRes.ok) {
            const checkData = await checkRes.json().catch(() => ({}));
            if (checkData.exists && (checkData.isMaster || checkData.isProxy)) {
              uploadState.duplicateCount++;
              return;
            }
          }
        } catch (err) {
          if (err && err.isUnauthorized) {
            uploadState.cancelled = true;
            return;
          }
        }
      }

      const useChunked = file.size >= CHUNKED_THRESHOLD_BYTES;
      const res = useChunked
        ? await uploadFileChunkedResumable(file, sha256, (loaded) => {
            uploadState.inFlightBytes.set(file, Math.min(file.size, loaded));
            renderUploadTray();
          })
        : await uploadFileWithProgress(file, sha256, (loaded) => {
            uploadState.inFlightBytes.set(file, Math.min(file.size, loaded));
            renderUploadTray();
          });

      if (res.status === 401) {
        uploadState.cancelled = true;
        signOut(false);
        showToast('Session expired — please sign in again.', 'rose');
        openLoginModal();
        return;
      }
      if (res.status === 507) {
        uploadState.quotaExceeded = true;
        uploadState.failedCount++;
        showToast(res.data.error || 'Server storage quota exceeded.', 'rose');
        return;
      }
      if (!res.ok || !res.data.success) {
        uploadState.failedCount++;
        return;
      }

      if (res.data.isDuplicate || res.data.status === 'duplicate_verified') {
        uploadState.duplicateCount++;
      } else {
        uploadState.uploadedCount++;
      }
    } catch (err) {
      if (!err || !err.isAbort) {
        uploadState.failedCount++;
      }
    } finally {
      uploadState.inFlightBytes.delete(file);
      uploadState.completedBytes += file.size;
      uploadState.completedCount++;
      renderUploadTray();
    }
  }

  async function drainUploadQueue() {
    uploadState.isRunning = true;
    setMascotMood($('uploadTrayMascot'), 'uploading');
    renderUploadTray();

    const worker = async () => {
      while (!uploadState.cancelled && !uploadState.quotaExceeded) {
        const nextFile = uploadState.queue.shift();
        if (!nextFile) break;
        await processOneDroppedFile(nextFile);
      }
    };

    const workers = [];
    const n = Math.min(UPLOAD_CONCURRENCY, Math.max(1, uploadState.queue.length));
    for (let i = 0; i < n; i++) workers.push(worker());
    await Promise.all(workers);

    uploadState.isRunning = false;
    uploadState.queue.length = 0;
    uploadState.inFlightBytes.clear();

    const parts = [];
    if (uploadState.uploadedCount > 0) parts.push(`${uploadState.uploadedCount} uploaded`);
    if (uploadState.duplicateCount > 0) parts.push(`${uploadState.duplicateCount} already backed up`);
    if (uploadState.failedCount > 0) parts.push(`${uploadState.failedCount} failed`);

    if (uploadState.cancelled) {
      setMascotMood($('uploadTrayMascot'), 'sleeping');
      $('uploadTrayTitle').textContent = 'Upload cancelled';
      $('uploadTraySub').textContent = parts.join(' · ') || 'Stopped';
      showToast('Upload cancelled.', 'amber');
    } else if (uploadState.quotaExceeded) {
      setMascotMood($('uploadTrayMascot'), 'alert');
      $('uploadTrayTitle').textContent = 'Storage quota reached';
      $('uploadTraySub').textContent = parts.join(' · ') || 'Free up space on server';
    } else if (uploadState.failedCount > 0 && uploadState.uploadedCount === 0 && uploadState.duplicateCount === 0) {
      setMascotMood($('uploadTrayMascot'), 'alert');
      $('uploadTrayTitle').textContent = 'Upload failed';
      $('uploadTraySub').textContent = 'Check your server connection and retry.';
      showToast('Could not upload dropped file(s).', 'rose');
    } else {
      setMascotMood($('uploadTrayMascot'), 'celebrate');
      $('uploadTrayTitle').textContent = 'Backup complete!';
      $('uploadTraySub').textContent = parts.join(' · ') || 'All items synced';
      $('uploadTrayFill').style.width = '100%';
      showToast(parts.join(' · ') || 'Backup complete!', uploadState.failedCount > 0 ? 'amber' : 'mint');
    }

    renderUploadTray();

    if (uploadState.uploadedCount > 0 && state.session) {
      state.photosEtag = null;
      if (state.activeView !== 'gallery') {
        switchView('gallery');
      }
      loadGallery(false);
      // Gentle refresh shortly after so auto-generated server proxies appear cleanly
      setTimeout(() => {
        if (state.session && !state.isLoadingPhotos) {
          state.photosEtag = null;
          loadGallery(false);
        }
      }, 2800);
    }

    clearTimeout(uploadState.hideTimer);
    uploadState.hideTimer = setTimeout(() => {
      if (!uploadState.isRunning) {
        $('uploadTray').classList.add('hidden');
      }
    }, 2800);
  }

  function enqueueWebUploads(files) {
    if (!files || files.length === 0) return;
    clearTimeout(uploadState.hideTimer);

    if (!uploadState.isRunning) {
      uploadState.cancelled = false;
      uploadState.quotaExceeded = false;
      uploadState.totalCount = 0;
      uploadState.completedCount = 0;
      uploadState.uploadedCount = 0;
      uploadState.duplicateCount = 0;
      uploadState.failedCount = 0;
      uploadState.totalBytes = 0;
      uploadState.completedBytes = 0;
      uploadState.currentFilename = '';
      uploadState.seenHashes = new Set();
      uploadState.seenFileKeys = new Set();
    }

    if (!uploadState.seenFileKeys) uploadState.seenFileKeys = new Set();
    let addedCount = 0;
    for (const f of files) {
      const fileKey = `${f.name}|${f.size}|${f.lastModified || 0}`;
      if (uploadState.seenFileKeys.has(fileKey)) {
        uploadState.duplicateCount++;
        continue;
      }
      uploadState.seenFileKeys.add(fileKey);
      uploadState.queue.push(f);
      uploadState.totalCount++;
      uploadState.totalBytes += f.size;
      addedCount++;
    }
    if (addedCount === 0 && !uploadState.isRunning) {
      showToast('Duplicate file(s) already queued or backed up.', 'mint');
      return;
    }

    if (!uploadState.isRunning) {
      drainUploadQueue();
    } else {
      renderUploadTray();
      showToast(`Added ${files.length} more item(s) to upload queue.`, 'orange');
    }
  }

  function cancelActiveWebUploads() {
    uploadState.cancelled = true;
    uploadState.queue.length = 0;
    for (const xhr of uploadState.activeXhrs) {
      try {
        xhr.abort();
      } catch {
        // ignore
      }
    }
    uploadState.activeXhrs.clear();
    for (const uid of uploadState.activeChunkUploadIds) {
      apiFetch(`/api/upload/chunked/${encodeURIComponent(uid)}`, { method: 'DELETE' }).catch(() => {});
    }
    uploadState.activeChunkUploadIds.clear();
  }

  function initInvisibleDragAndDrop() {
    const overlay = $('dropUploadOverlay');
    if (!overlay) return;

    let dragDepth = 0;

    const isFileDrag = (e) => {
      const dt = e.dataTransfer;
      if (!dt || !dt.types) return false;
      return Array.from(dt.types).includes('Files');
    };

    const showOverlay = () => {
      if (state.session) {
        $('dropOverlayTitle').textContent = 'Drop photos & videos to back up';
        $('dropOverlaySub').textContent = 'Full-resolution originals · SHA-256 verified · Folders supported';
      } else {
        $('dropOverlayTitle').textContent = 'Sign in to back up photos';
        $('dropOverlaySub').textContent = 'Drop files after signing in with Google';
      }
      overlay.classList.remove('hidden');
    };

    const hideOverlay = () => {
      dragDepth = 0;
      overlay.classList.add('hidden');
    };

    window.addEventListener('dragenter', (e) => {
      if (!isFileDrag(e)) return;
      e.preventDefault();
      dragDepth++;
      showOverlay();
    });

    window.addEventListener('dragover', (e) => {
      if (!isFileDrag(e)) return;
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
      if (overlay.classList.contains('hidden')) {
        showOverlay();
      }
    });

    window.addEventListener('dragleave', (e) => {
      if (dragDepth <= 0) return;
      dragDepth--;
      if (dragDepth <= 0 || (e.clientX === 0 && e.clientY === 0)) {
        hideOverlay();
      }
    });

    window.addEventListener('dragend', hideOverlay);
    window.addEventListener('blur', hideOverlay);

    window.addEventListener('drop', async (e) => {
      if (!isFileDrag(e)) return;
      e.preventDefault();
      hideOverlay();

      if (!state.session) {
        openLoginModal('Sign in with Google first to upload photos.');
        return;
      }

      const rawFiles = await extractDroppedFiles(e.dataTransfer);
      const mediaFiles = rawFiles.filter(isSupportedMediaFile);
      const skipped = rawFiles.length - mediaFiles.length;

      if (mediaFiles.length === 0) {
        showToast('No supported photos or videos found in dropped files.', 'amber');
        return;
      }

      if (skipped > 0) {
        showToast(`Uploading ${mediaFiles.length} media file(s) (skipped ${skipped} non-media file(s)).`, 'orange');
      }
      enqueueWebUploads(mediaFiles);
    });

    const cancelBtn = $('uploadCancelBtn');
    if (cancelBtn) {
      cancelBtn.addEventListener('click', cancelActiveWebUploads);
    }
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
        state.selectedHashes.clear();
        state.lastSelectedIndex = -1;
        if (state.filterMedia !== 'albums') {
          state.activeAlbum = null;
          state.activeAlbumPhotos = [];
        }
        updateSelectionBar();
        if (state.filterMedia === 'trash') {
          loadTrash();
        } else if (state.filterMedia === 'protected') {
          renderGallery();
          loadProtectedPhotos();
        } else if (state.filterMedia === 'favorite') {
          renderGallery();
          loadFavoritePhotos();
        } else if (state.filterMedia === 'albums') {
          loadAlbums();
          renderGallery();
        } else if (state.filterMedia === 'map') {
          renderGallery();
          loadPhotoMap();
        } else {
          renderGallery();
          syncGalleryFromServerIfChanged();
        }
      });
    });

    // Subtle upload file picker button (great for mobile/tablet browsers alongside desktop drag-and-drop)
    $('webUploadBtn').addEventListener('click', () => {
      if (!state.session) {
        openLoginModal('Sign in with Google first to upload photos.');
        return;
      }
      $('webUploadInput').click();
    });
    $('webUploadInput').addEventListener('change', (e) => {
      const picked = Array.from(e.target.files || []).filter(isSupportedMediaFile);
      e.target.value = '';
      if (picked.length > 0) {
        enqueueWebUploads(picked);
      }
    });

    $('selectAllProtectedBtn').addEventListener('click', () => {
      if (!state.isSelectionMode) {
        state.isSelectionMode = true;
        $('selectModeBtn').textContent = 'Done';
      }
      for (const p of state.visibleFlatPhotos) {
        if (p.keepOriginalOnDevice) state.selectedHashes.add(p.hash.toLowerCase());
      }
      updateSelectionBar();
      renderGallery();
    });
    $('allowReproxyAllProtectedBtn').addEventListener('click', () => {
      const list = state.visibleFlatPhotos.filter((p) => Boolean(p.keepOriginalOnDevice));
      if (list.length === 0) return;
      openConfirmModal(
        `Allow re-proxy for ${list.length} protected photo(s)?`,
        'Your phone app will be allowed to compress these restored originals back into lightweight proxies to save local storage. Full-resolution originals stay safely backed up on your server.',
        () => batchSetProtectOriginals(list.map((p) => p.hash), false),
        `Allow Re-Proxy (${list.length})`
      );
    });
    $('allowReproxySelectedBtn').addEventListener('click', () => {
      const source = getActiveSelectionSource();
      const targetHashes = source
        .filter((p) => state.selectedHashes.has(p.hash.toLowerCase()) && Boolean(p.keepOriginalOnDevice))
        .map((p) => p.hash);
      if (targetHashes.length === 0) return;
      batchSetProtectOriginals(targetHashes, false);
    });
    $('protectSelectedBtn').addEventListener('click', () => {
      const hashes = Array.from(state.selectedHashes);
      if (hashes.length === 0) return;
      batchSetProtectOriginals(hashes, true);
    });
    $('emptyTrashBtn').addEventListener('click', () => {
      if (state.trashPhotos.length === 0) return;
      openConfirmModal(
        `Empty Trash (${state.trashPhotos.length} item(s))?`,
        'This permanently deletes all trashed originals and proxies from your server and frees space immediately.',
        () => emptyTrashOnServer(null),
        'Empty Trash'
      );
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
        if (state.filterMedia === 'map') {
          renderMapMarkers();
          const matched = getActiveMapPhotos();
          if (matched.length > 0) fitMapToCoords(matched);
        }
      }, 140);
    });

    $('selectModeBtn').addEventListener('click', () => toggleSelectionMode());
    $('cancelSelectBtn').addEventListener('click', () => toggleSelectionMode(false));
    $('selectAllVisibleBtn').addEventListener('click', () => {
      for (const p of state.visibleFlatPhotos) state.selectedHashes.add(p.hash.toLowerCase());
      updateSelectionBar();
      renderGallery();
    });
    $('downloadZipBtn').addEventListener('click', () => {
      const hashes = Array.from(state.selectedHashes);
      if (hashes.length > 0) downloadSelectedAsZip(hashes);
    });
    $('addToAlbumSelectedBtn').addEventListener('click', () => {
      const hashes = Array.from(state.selectedHashes);
      if (hashes.length > 0) openAlbumPickerModal(hashes);
    });
    $('removeFromAlbumSelectedBtn').addEventListener('click', () => {
      const hashes = Array.from(state.selectedHashes);
      if (hashes.length > 0) removeSelectedFromActiveAlbum(hashes);
    });
    $('shareSelectedBtn').addEventListener('click', () => {
      const hashes = Array.from(state.selectedHashes);
      if (hashes.length > 0) openShareModal(hashes);
    });
    $('restoreSelectedBtn').addEventListener('click', () => {
      const hashes = Array.from(state.selectedHashes);
      if (hashes.length > 0) restorePhotosFromTrash(hashes);
    });
    $('deleteSelectedBtn').addEventListener('click', () => {
      const hashes = Array.from(state.selectedHashes);
      if (hashes.length === 0) return;
      if (state.filterMedia === 'trash') {
        openConfirmModal(
          `Permanently delete ${hashes.length} item(s)?`,
          'This cannot be undone and removes the originals from your server immediately.',
          () => emptyTrashOnServer(hashes),
          'Delete Forever'
        );
      } else {
        openConfirmModal(
          `Move ${hashes.length} item(s) to Trash?`,
          'Items stay in Trash for 30 days so you can restore them anytime before permanent removal.',
          () => movePhotosToTrash(hashes),
          'Move to Trash'
        );
      }
    });
    const refreshCurrentGalleryView = () => {
      if (state.filterMedia === 'trash') {
        loadTrash();
        loadGallery(false, { silent: true });
      } else if (state.filterMedia === 'protected') {
        loadProtectedPhotos();
        loadGallery(false, { silent: true });
      } else if (state.filterMedia === 'favorite') {
        loadFavoritePhotos();
        loadGallery(false, { silent: true });
      } else if (state.filterMedia === 'albums') {
        loadAlbums();
        if (state.activeAlbum) openAlbumDetail(state.activeAlbum.id);
        loadGallery(false, { silent: true });
      } else if (state.filterMedia === 'map') {
        loadPhotoMap();
        loadGallery(false, { silent: true });
      } else {
        loadGallery(true);
      }
    };
    $('refreshGalleryBtn').addEventListener('click', refreshCurrentGalleryView);
    $('emptyRetryBtn').addEventListener('click', refreshCurrentGalleryView);

    // Cross-device auto-sync: whenever you switch back to this browser tab from your phone
    // (or periodically while browsing), lightweight ETag check pulls any Protected/Favorite/Trash/Upload changes.
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        syncGalleryFromServerIfChanged();
      }
    });
    window.addEventListener('focus', () => {
      syncGalleryFromServerIfChanged();
    });
    setInterval(() => {
      if (document.visibilityState === 'visible') {
        syncGalleryFromServerIfChanged();
      }
    }, 20000);

    // Share modal + Manage Share Links + Cleanup + Albums + Map + Memory Viewer
    $('closeShareModalBtn').addEventListener('click', closeShareModal);
    $('shareModal').addEventListener('click', (e) => {
      if (e.target === $('shareModal')) closeShareModal();
    });
    $('shareCreateForm').addEventListener('submit', handleCreateShareLink);
    $('openManageSharesFromModalBtn').addEventListener('click', () => {
      closeShareModal();
      openManageSharesModal();
    });
    $('manageSharesBtn').addEventListener('click', openManageSharesModal);
    $('closeManageSharesBtn').addEventListener('click', closeManageSharesModal);
    $('manageSharesModal').addEventListener('click', (e) => {
      if (e.target === $('manageSharesModal')) closeManageSharesModal();
    });

    // Albums controls
    renderAlbumCategoryPills();
    $('albumCategorySelect').addEventListener('change', () => {
      syncAlbumCustomCategoryField({ focus: true });
    });
    $('newAlbumBtn').addEventListener('click', () => openAlbumModal(null, []));
    $('closeAlbumModalBtn').addEventListener('click', closeAlbumModal);
    $('albumModal').addEventListener('click', (e) => {
      if (e.target === $('albumModal')) closeAlbumModal();
    });
    $('albumForm').addEventListener('submit', handleSaveAlbum);
    $('backToAlbumsBtn').addEventListener('click', closeAlbumDetail);
    $('shareActiveAlbumBtn').addEventListener('click', () => {
      if (!state.activeAlbum) return;
      const hashes = state.activeAlbumPhotos.map((p) => p.hash);
      if (hashes.length === 0) {
        showToast('Add photos to this album first before sharing.', 'amber');
        return;
      }
      openShareModal(hashes, state.activeAlbum.name, state.activeAlbum.id);
    });
    $('editActiveAlbumBtn').addEventListener('click', () => {
      if (state.activeAlbum) openAlbumModal(state.activeAlbum);
    });
    $('deleteActiveAlbumBtn').addEventListener('click', () => {
      if (!state.activeAlbum) return;
      const alb = state.activeAlbum;
      openConfirmModal(
        `Delete album "${alb.name}"?`,
        'This deletes only the album container. All photos stay safely in your cloud library.',
        async () => {
          try {
            const res = await apiFetch(`/api/albums/${encodeURIComponent(alb.id)}`, { method: 'DELETE' });
            if (!res.ok) throw new Error('Delete failed');
            showToast(`Deleted album "${alb.name}"`, 'amber');
            closeAlbumDetail();
            await loadAlbums();
          } catch (err) {
            showToast(err.message || 'Could not delete album', 'rose');
          }
        },
        'Delete Album'
      );
    });
    $('closeAlbumPickerBtn').addEventListener('click', closeAlbumPickerModal);
    $('albumPickerModal').addEventListener('click', (e) => {
      if (e.target === $('albumPickerModal')) closeAlbumPickerModal();
    });
    $('pickerCreateNewAlbumBtn').addEventListener('click', () => {
      const hashes = state.albumPickerHashes.slice();
      closeAlbumPickerModal();
      openAlbumModal(null, hashes);
    });

    // Map controls
    document.querySelectorAll('#mapStyleControl .seg-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        state.mapStyle = btn.dataset.mapStyle || 'street';
        updateMapControlLabels();
        if (state.mapProvider === 'google') {
          applyGoogleMapStyle();
        } else {
          applyLeafletBaseLayer();
        }
      });
    });
    $('mapProviderToggleBtn').addEventListener('click', () => {
      state.mapProviderUserChosen = true;
      state.mapProvider = state.mapProvider === 'google' ? 'leaflet' : 'google';
      initAndRenderInteractiveMap({ fitBounds: true });
    });
    $('mapRescanBtn').addEventListener('click', () => {
      loadPhotoMap({ rescan: true });
    });
    $('mapFitBoundsBtn').addEventListener('click', () => {
      state.selectedMapClusterId = null;
      state.selectedMapFilter = null;
      updateMapSelectedHeader();
      renderMapPlacePills();
      fitMapToCoords(getActiveMapPhotos());
      renderMapMarkers();
      renderGallery();
    });
    $('mapClearPlaceBtn').addEventListener('click', () => {
      state.selectedMapClusterId = null;
      state.selectedMapFilter = null;
      updateMapSelectedHeader();
      renderMapPlacePills();
      fitMapToCoords(getActiveMapPhotos());
      renderMapMarkers();
      renderGallery();
    });

    // Cleanup studio controls
    $('cleanupBtn').addEventListener('click', () => openCleanupModal(true));
    $('closeCleanupModalBtn').addEventListener('click', closeCleanupModal);
    $('cleanupModal').addEventListener('click', (e) => {
      if (e.target === $('cleanupModal')) closeCleanupModal();
    });
    $('cleanupRescanBtn').addEventListener('click', () => openCleanupModal(true));
    document.querySelectorAll('#cleanupTabPills .f-pill').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('#cleanupTabPills .f-pill').forEach((b) => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        state.cleanupTab = btn.dataset.cleanupTab || 'similar';
        renderCleanupStudio();
      });
    });
    $('cleanupTrashSelectedBtn').addEventListener('click', () => {
      const hashes = Array.from(state.cleanupSelectedHashes);
      if (hashes.length === 0) return;
      openConfirmModal(
        `Move ${hashes.length} photo(s) to Trash?`,
        'They remain recoverable in Trash for 30 days before permanent deletion.',
        async () => {
          await movePhotosToTrash(hashes);
          state.cleanupSelectedHashes.clear();
          await openCleanupModal(false);
        },
        'Move to Trash'
      );
    });

    $('shareCopyBtn').addEventListener('click', async () => {
      const val = $('shareUrlOutput').value;
      if (!val) return;
      try {
        await navigator.clipboard.writeText(val);
        showToast('Link copied to clipboard!', 'mint');
      } catch {
        $('shareUrlOutput').select();
        document.execCommand('copy');
        showToast('Link copied!', 'mint');
      }
    });

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

    // Lightbox controls + keyboard + zoom + swipe
    $('lbCloseBtn').addEventListener('click', closeLightbox);
    $('lbFavBtn').addEventListener('click', toggleLightboxFavorite);
    $('lbInfoBtn').addEventListener('click', () => $('lbInfoPanel').classList.toggle('hidden'));
    $('lbInfoCloseBtn').addEventListener('click', () => $('lbInfoPanel').classList.add('hidden'));
    $('lbShareBtn').addEventListener('click', () => {
      const photo = state.visibleFlatPhotos[state.lightboxIndex];
      if (photo) openShareModal([photo.hash], photo.originalName || '');
    });
    $('lbAlbumBtn').addEventListener('click', () => {
      const photo = state.visibleFlatPhotos[state.lightboxIndex];
      if (photo) openAlbumPickerModal([photo.hash]);
    });
    $('lbRestoreBtn').addEventListener('click', async () => {
      const photo = state.visibleFlatPhotos[state.lightboxIndex];
      if (!photo) return;
      closeLightbox();
      await restorePhotosFromTrash([photo.hash]);
    });
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
      if (state.filterMedia === 'trash' || photo.deletedAt) {
        openConfirmModal(
          `Permanently delete ${photo.originalName}?`,
          'This cannot be undone and removes the original from your server immediately.',
          async () => {
            closeLightbox();
            await emptyTrashOnServer([photo.hash]);
          },
          'Delete Forever'
        );
      } else {
        openConfirmModal(
          `Move ${photo.originalName} to Trash?`,
          'You can restore this item from Trash for up to 30 days.',
          async () => {
            closeLightbox();
            await movePhotosToTrash([photo.hash]);
          },
          'Move to Trash'
        );
      }
    });

    // Lightbox image double-click zoom, wheel zoom, drag pan, pinch zoom & tap-to-toggle chrome
    const lbImg = $('lbImage');
    let lbDragStart = null;
    let lbDragged = false;
    lbImg.addEventListener('dblclick', (e) => {
      e.stopPropagation();
      if (state.lightboxZoom > 1.05) {
        resetLightboxZoom();
      } else {
        state.lightboxZoom = 2.4;
        state.lightboxPanX = 0;
        state.lightboxPanY = 0;
        applyLightboxZoomTransform();
      }
    });
    lbImg.addEventListener('click', (e) => {
      e.stopPropagation();
      if (lbDragged) {
        lbDragged = false;
        return;
      }
      if (state.lightboxZoom <= 1.05) {
        $('lightbox').classList.toggle('is-immersive');
      }
    });
    $('lbMediaBox').addEventListener(
      'wheel',
      (e) => {
        if (lbImg.classList.contains('hidden')) return;
        e.preventDefault();
        const factor = e.deltaY < 0 ? 1.18 : 0.85;
        state.lightboxZoom = Math.min(4.5, Math.max(1, state.lightboxZoom * factor));
        applyLightboxZoomTransform();
      },
      { passive: false }
    );
    lbImg.addEventListener('mousedown', (e) => {
      if (state.lightboxZoom <= 1.05) return;
      e.preventDefault();
      lbDragStart = { x: e.clientX - state.lightboxPanX, y: e.clientY - state.lightboxPanY };
      lbDragged = false;
    });
    window.addEventListener('mousemove', (e) => {
      if (!lbDragStart) return;
      lbDragged = true;
      state.lightboxPanX = e.clientX - lbDragStart.x;
      state.lightboxPanY = e.clientY - lbDragStart.y;
      applyLightboxZoomTransform();
    });
    window.addEventListener('mouseup', () => {
      lbDragStart = null;
    });

    document.addEventListener('keydown', (e) => {
      if (!$('confirmModal').classList.contains('hidden')) {
        if (e.key === 'Escape') closeConfirmModal();
        return;
      }
      if (!$('shareModal').classList.contains('hidden')) {
        if (e.key === 'Escape') closeShareModal();
        return;
      }
      if (!$('manageSharesModal').classList.contains('hidden')) {
        if (e.key === 'Escape') closeManageSharesModal();
        return;
      }
      if (!$('albumModal').classList.contains('hidden')) {
        if (e.key === 'Escape') closeAlbumModal();
        return;
      }
      if (!$('albumPickerModal').classList.contains('hidden')) {
        if (e.key === 'Escape') closeAlbumPickerModal();
        return;
      }
      if (!$('cleanupModal').classList.contains('hidden')) {
        if (e.key === 'Escape') closeCleanupModal();
        return;
      }
      if (!$('loginModal').classList.contains('hidden')) {
        if (e.key === 'Escape') closeLoginModal();
        return;
      }
      if ($('lightbox').classList.contains('hidden')) return;
      const tag = e.target && e.target.tagName ? e.target.tagName.toUpperCase() : '';
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (e.target && e.target.isContentEditable)) {
        return;
      }
      if (e.key === 'Escape') closeLightbox();
      else if (e.key === 'ArrowLeft' && state.lightboxIndex > 0) {
        state.lightboxIndex--;
        renderLightboxItem();
      } else if (e.key === 'ArrowRight' && state.lightboxIndex < state.visibleFlatPhotos.length - 1) {
        state.lightboxIndex++;
        renderLightboxItem();
      } else if (e.key.toLowerCase() === 'i') {
        $('lbInfoPanel').classList.toggle('hidden');
      }
    });

    let touchStartX = 0;
    let pinchStartDist = 0;
    let pinchStartZoom = 1;
    let lastTapTs = 0;
    $('lbStage').addEventListener(
      'touchstart',
      (e) => {
        if (e.touches.length === 2) {
          const dx = e.touches[0].clientX - e.touches[1].clientX;
          const dy = e.touches[0].clientY - e.touches[1].clientY;
          pinchStartDist = Math.hypot(dx, dy);
          pinchStartZoom = state.lightboxZoom;
        } else if (e.touches.length === 1) {
          touchStartX = e.changedTouches[0].clientX;
          const now = Date.now();
          if (now - lastTapTs < 280 && !lbImg.classList.contains('hidden')) {
            if (state.lightboxZoom > 1.05) resetLightboxZoom();
            else {
              state.lightboxZoom = 2.3;
              applyLightboxZoomTransform();
            }
          }
          lastTapTs = now;
        }
      },
      { passive: true }
    );
    $('lbStage').addEventListener(
      'touchmove',
      (e) => {
        if (e.touches.length === 2 && pinchStartDist > 0 && !lbImg.classList.contains('hidden')) {
          const dx = e.touches[0].clientX - e.touches[1].clientX;
          const dy = e.touches[0].clientY - e.touches[1].clientY;
          const dist = Math.hypot(dx, dy);
          state.lightboxZoom = Math.min(4.5, Math.max(1, pinchStartZoom * (dist / pinchStartDist)));
          applyLightboxZoomTransform();
        }
      },
      { passive: true }
    );
    $('lbStage').addEventListener(
      'touchend',
      (e) => {
        if (e.touches.length < 2) pinchStartDist = 0;
        if (state.lightboxZoom > 1.05) return;
        const dx = e.changedTouches[0].clientX - touchStartX;
        if (Math.abs(dx) < 48) return;
        if (dx > 0 && state.lightboxIndex > 0) {
          state.lightboxIndex--;
          renderLightboxItem();
        } else if (dx < 0 && state.lightboxIndex < state.visibleFlatPhotos.length - 1) {
          state.lightboxIndex++;
          renderLightboxItem();
        }
      },
      { passive: true }
    );

    loadMoreObserver.observe($('loadMoreWrap'));
    initInvisibleDragAndDrop();
  }

  async function boot() {
    const bootStart = performance.now();
    initTheme();
    hydrateSunnyMascots();
    initShowcaseInteractions();
    bindEvents();

    // Register PWA Service Worker for installable fullscreen web app experience
    if ('serviceWorker' in navigator && window.isSecureContext) {
      navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => {});
    }

    // 1. Fetch public server capabilities (/api/auth/config)
    try {
      const cfgRes = await fetch('/api/auth/config');
      if (cfgRes.ok) {
        const cfg = await cfgRes.json();
        state.serverConfig = {
          googleEnabled: Boolean(cfg.googleEnabled),
        };
        const pill = $('navServerPill');
        pill.classList.add('is-online');
        $('navServerLabel').textContent = 'Online';
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
