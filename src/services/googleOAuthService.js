function isGoogleUserAllowed(email, config) {
  const lower = String(email || '').trim().toLowerCase();
  if (!lower || !lower.includes('@')) return false;
  const hasEmailList =
    config.allowedGoogleEmails instanceof Set && config.allowedGoogleEmails.size > 0;
  const hasDomainList =
    config.allowedGoogleDomains instanceof Set && config.allowedGoogleDomains.size > 0;

  if (!hasEmailList && !hasDomainList) return true;
  if (hasEmailList && config.allowedGoogleEmails.has(lower)) return true;
  const domain = lower.split('@')[1] || '';
  if (hasDomainList && config.allowedGoogleDomains.has(domain)) return true;
  return false;
}

async function exchangeGoogleCodeForProfile({
  code,
  redirectUri,
  config,
  fetchFn = fetch,
}) {
  const tokenRes = await fetchFn('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      code: String(code),
      client_id: config.googleClientId,
      client_secret: config.googleClientSecret,
      redirect_uri: redirectUri,
      grant_type: 'authorization_code',
    }),
  });
  const tokenData = await tokenRes.json().catch(() => ({}));
  if (!tokenRes.ok || !tokenData || (!tokenData.id_token && !tokenData.access_token)) {
    const msg =
      (tokenData && (tokenData.error_description || tokenData.error)) ||
      `Google token exchange failed (${tokenRes.status})`;
    const err = new Error(msg);
    err.statusCode = 401;
    throw err;
  }

  let profile = null;
  if (tokenData.id_token) {
    const infoRes = await fetchFn(
      `https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(tokenData.id_token)}`
    );
    const info = await infoRes.json().catch(() => ({}));
    if (!infoRes.ok || !info || !info.sub || !info.email) {
      const err = new Error('Google ID token verification failed.');
      err.statusCode = 401;
      throw err;
    }
    if (config.googleClientId && info.aud !== config.googleClientId) {
      const err = new Error('Google ID token audience mismatch.');
      err.statusCode = 401;
      throw err;
    }
    if (info.email_verified !== true && info.email_verified !== 'true') {
      const err = new Error('Google email address is not verified.');
      err.statusCode = 403;
      throw err;
    }
    profile = {
      sub: info.sub,
      email: info.email,
      name: info.name || info.email,
      picture: info.picture || null,
    };
  } else {
    const userRes = await fetchFn('https://openidconnect.googleapis.com/v1/userinfo', {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    });
    const info = await userRes.json().catch(() => ({}));
    if (!userRes.ok || !info || !info.sub || !info.email || !info.email_verified) {
      const err = new Error('Google user profile verification failed.');
      err.statusCode = 401;
      throw err;
    }
    profile = {
      sub: info.sub,
      email: info.email,
      name: info.name || info.email,
      picture: info.picture || null,
    };
  }

  if (!isGoogleUserAllowed(profile.email, config)) {
    const err = new Error('This Google account is not authorized on this PhotoHub server.');
    err.statusCode = 403;
    throw err;
  }

  return profile;
}

module.exports = {
  isGoogleUserAllowed,
  exchangeGoogleCodeForProfile,
};
