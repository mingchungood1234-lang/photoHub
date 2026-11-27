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
    },
    session: null, // { token, serverUrl, authMode, user }
    whoami: null,
    activeView: 'landing', // 'landing' | 'gallery'
    photos: [],
    trashPhotos: [],
    trashCount: 0,
    isLoadingTrash: false,
    years: [],
    totalPhotos: 0,
    hasMore: false,
    isLoadingPhotos: false,
    isLoadingMore: false,
    photosEtag: null,
    filterMedia: 'all', // 'all' | 'photo' | 'video' | 'favorite' | 'protected' | 'trash'
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
    confirmCallback: null,
  };

  // Bounded LRU cache for preloaded lightbox full previews (eliminates spinner flash on swipe/next)
  const MAX_LB_CACHE = 12;
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
    for (const delta of [1, -1]) {
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
    state.trashPhotos = [];
    state.trashCount = 0;
    state.years = [];
    state.photosEtag = null;
    state.selectedHashes.clear();
    state.lastSelectedIndex = -1;
    state.isSelectionMode = false;
    clearThumbCache();
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
      state.trashCount = Number(data.trashCount) || 0;
      state.hasMore = Boolean(data.hasMore);
      updateTrashBadge();
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

  async function loadTrash() {
    if (!state.session || state.isLoadingTrash) return;
    state.isLoadingTrash = true;
    try {
      const res = await apiFetch('/api/photos/trash');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
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
      showToast(err.message || 'Could not load Trash', 'rose');
    } finally {
      state.isLoadingTrash = false;
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
    const isTrash = state.filterMedia === 'trash';
    const source = isTrash ? state.trashPhotos : state.photos;
    return source.filter((p) => {
      const isVid = isVideoPhoto(p);
      if (state.filterMedia === 'photo' && isVid) return false;
      if (state.filterMedia === 'video' && !isVid) return false;
      if (state.filterMedia === 'favorite' && !p.isFavorite) return false;
      if (state.filterMedia === 'protected' && !p.keepOriginalOnDevice) return false;
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
    const isTrashView = state.filterMedia === 'trash';
    $('trashBanner').classList.toggle('hidden', !isTrashView);
    const items = filteredPhotos();
    state.visibleFlatPhotos = items;

    const vidCount = state.photos.filter(isVideoPhoto).length;
    const photoCount = state.photos.length - vidCount;
    $('galleryCountsText').textContent = isTrashView
      ? `${state.trashPhotos.length} item(s) in Trash`
      : `${state.totalPhotos} total · ${photoCount} photos · ${vidCount} videos`;

    const container = $('galleryTimeline');
    container.innerHTML = '';

    if (items.length === 0) {
      $('galleryEmptyState').classList.remove('hidden');
      setMascotMood($('emptyStateMascot'), 'sleeping');
      if (isTrashView) {
        $('emptyStateTitle').textContent = 'Trash is Empty';
        $('emptyStateText').textContent = 'Deleted photos appear here for 30 days before permanent removal.';
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

        if (photo.keepOriginalOnDevice || photo.isFavorite) {
          const badges = document.createElement('div');
          badges.className = 'tile-badges';
          if (photo.isFavorite) {
            badges.innerHTML += `<span class="tile-badge tile-badge--fav" title="Favorite">♥</span>`;
          }
          if (photo.keepOriginalOnDevice) {
            badges.innerHTML += `<span class="tile-badge tile-badge--protected" title="Restored original protected">✓</span>`;
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

  function updateSelectionBar() {
    const bar = $('selectionBar');
    bar.classList.toggle('hidden', !state.isSelectionMode);
    if (!state.isSelectionMode) return;
    const isTrash = state.filterMedia === 'trash';
    const source = isTrash ? state.trashPhotos : state.photos;
    const count = state.selectedHashes.size;
    let totalBytes = 0;
    for (const p of source) {
      if (state.selectedHashes.has(p.hash.toLowerCase())) {
        totalBytes += Number(p.size) || 0;
      }
    }
    $('selectionCountText').textContent = `${count} selected`;
    $('selectionSizeText').textContent = `${formatBytes(totalBytes)} · Shift+Click for range`;
    $('deleteSelectedBtn').disabled = count === 0;
    $('deleteSelectedBtn').textContent = isTrash ? 'Delete Forever' : 'Trash';
    $('downloadZipBtn').classList.toggle('hidden', isTrash);
    $('downloadZipBtn').disabled = count === 0;
    $('shareSelectedBtn').classList.toggle('hidden', isTrash);
    $('shareSelectedBtn').disabled = count === 0;
    $('restoreSelectedBtn').classList.toggle('hidden', !isTrash);
    $('restoreSelectedBtn').disabled = count === 0;
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
      state.photos = state.photos.filter((p) => !moved.has(p.hash.toLowerCase()));
      state.totalPhotos = Math.max(0, state.totalPhotos - moved.size);
      state.trashCount += moved.size;
      state.photosEtag = null;
      for (const h of moved) state.selectedHashes.delete(h);
      updateTrashBadge();
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
      state.photosEtag = null;
      for (const h of restored) state.selectedHashes.delete(h);
      updateTrashBadge();
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

  function openShareModal(hashes, defaultTitle = '') {
    state.shareTargetHashes = Array.from(hashes || []);
    if (state.shareTargetHashes.length === 0) return;
    $('shareModalTitle').textContent =
      state.shareTargetHashes.length === 1
        ? 'Share Photo Link'
        : `Share ${state.shareTargetHashes.length} Photos`;
    $('shareTitleInput').value = defaultTitle || '';
    $('sharePasscodeInput').value = '';
    $('shareExpirySelect').value = '168';
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
      const res = await apiFetch('/api/shares', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          hashes: state.shareTargetHashes,
          title: $('shareTitleInput').value.trim(),
          expiresInHours: Number($('shareExpirySelect').value) || 168,
          passcode: $('sharePasscodeInput').value.trim(),
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
      ['Verification', `SHA-256 Verified (${String(photo.hash || '').slice(0, 12)}…)`],
    ];
    if (photo.deletedAt) {
      rows.push(['Trashed', `${new Date(photo.deletedAt).toLocaleDateString()} (${photo.daysRemaining ?? 30}d left)`]);
    }
    list.innerHTML = '';
    for (const [label, value] of rows) {
      const dt = document.createElement('dt');
      dt.textContent = label;
      const dd = document.createElement('dd');
      dd.textContent = value;
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
    $('lbRestoreBtn').classList.toggle('hidden', !isTrash);
    $('lbProtectBtn').textContent = photo.keepOriginalOnDevice ? 'Unprotect' : 'Protect';
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

    try {
      const objUrl = await fetchLightboxPreviewCached(photo.hash);
      if (!objUrl) throw new Error('Preview unavailable');
      if (state.visibleFlatPhotos[state.lightboxIndex]?.hash !== photo.hash) return;
      const img = $('lbImage');
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
      showToast('Preview not available — tap Original to download.', 'amber');
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
      state.photosEtag = null;
      const favBtn = $('lbFavBtn');
      favBtn.classList.toggle('is-fav', nextFav);
      favBtn.textContent = nextFav ? '♥' : '♡';
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
    hideTimer: null,
  };

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

      const res = await uploadFileWithProgress(file, sha256, (loaded) => {
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
        updateSelectionBar();
        if (state.filterMedia === 'trash') {
          loadTrash();
        } else {
          renderGallery();
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
    $('refreshGalleryBtn').addEventListener('click', () => {
      if (state.filterMedia === 'trash') loadTrash();
      else loadGallery(true);
    });
    $('emptyRetryBtn').addEventListener('click', () => {
      if (state.filterMedia === 'trash') loadTrash();
      else loadGallery(true);
    });

    // Share modal
    $('closeShareModalBtn').addEventListener('click', closeShareModal);
    $('shareModal').addEventListener('click', (e) => {
      if (e.target === $('shareModal')) closeShareModal();
    });
    $('shareCreateForm').addEventListener('submit', handleCreateShareLink);
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
