/**
 * ADMIN AUTHENTICATION MIDDLEWARE (Protects `/api/admin/*` Endpoints)
 *
 * Where this belongs: `src/middleware/adminAuthMiddleware.js`.
 * Where it runs: Mounted in `src/routes/index.js` on `/api/admin` BEFORE user `authMiddleware`.
 * Allowed credentials:
 *   1. `X-Admin-Key` header (or `?adminKey=` / `Authorization: Bearer <ADMIN_KEY>`) matching `config.adminKey`
 *   2. OR a signed Google session JWT whose `email` is listed in `ADMIN_EMAILS`
 *   3. OR open local dev mode ONLY when neither admin credentials nor any user auth are configured
 */

const crypto = require('crypto');
const { verifyToken } = require('../models/userModel');

function timingSafeStringEqual(a, b) {
  const bufA = Buffer.from(String(a || ''), 'utf8');
  const bufB = Buffer.from(String(b || ''), 'utf8');
  if (bufA.length === 0 || bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function createAdminAuthMiddleware({ config, sessionSecret }) {
  return function adminAuthMiddleware(req, res, next) {
    const authHeader = String(req.headers.authorization || '').trim();
    const bearer = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
    const providedAdminKey = String(
      req.headers['x-admin-key'] || req.query.adminKey || bearer || ''
    ).trim();

    const hasAdminKey = Boolean(config.adminKey);
    const hasAdminEmails = config.adminEmails instanceof Set && config.adminEmails.size > 0;

    if (hasAdminKey && timingSafeStringEqual(providedAdminKey, config.adminKey)) {
      req.adminContext = { authType: 'admin_key', isAdmin: true };
      return next();
    }

    if (hasAdminEmails && bearer) {
      const payload = verifyToken(bearer, sessionSecret);
      const email = String((payload && payload.email) || '').trim().toLowerCase();
      if (payload && payload.typ === 'session' && email && config.adminEmails.has(email)) {
        req.adminContext = { authType: 'admin_google', email, isAdmin: true };
        return next();
      }
    }

    // In local dev without any auth or admin key configured, allow local inspection cleanly
    const anyUserAuthConfigured =
      config.userKeyMap.size > 0 ||
      Boolean(config.apiKey) ||
      Boolean(config.googleClientId) ||
      config.requireAuth;

    if (!hasAdminKey && !hasAdminEmails && !anyUserAuthConfigured) {
      req.adminContext = { authType: 'open_local', isAdmin: true };
      return next();
    }

    if (!hasAdminKey && !hasAdminEmails) {
      return res.status(503).json({
        success: false,
        needsSetup: true,
        error: 'Set ADMIN_KEY (or ADMIN_EMAILS) in .env to access the server admin dashboard.',
      });
    }

    return res.status(401).json({
      success: false,
      error: 'Unauthorized: Valid ADMIN_KEY is required.',
    });
  };
}

module.exports = { createAdminAuthMiddleware };
