/**
 * AUTHENTICATION MIDDLEWARE (Gatekeeper for Protected `/api/*` Endpoints)
 *
 * Where this belongs: `src/middleware/authMiddleware.js`.
 * Where it runs: Mounted in `src/routes/index.js` right AFTER `publicRoutes` and BEFORE
 * `accountRoutes`, `uploadRoutes`, `proxyRoutes`, and `photoRoutes`.
 * Where it goes next: Calls `contextService.getOrCreateFolderContext(...)` & `models/userModel.js`
 * to verify credentials, attaches `req.userContext = { folderName, storageDir, hashIndex, ... }`,
 * and calls `next()` so the target controller knows which user folder to read/write.
 */

const { verifyToken, resolveConfiguredUserFolder } = require('../models/userModel');

/**
 * Authenticates `/api/*` requests via:
 * 1) Signed Google session Bearer JWT
 * 2) Multi-user API keys (`USER_KEYS`)
 * 3) Single shared `API_KEY`
 * 4) Open access only when no authentication mechanism is configured
 */
function createAuthMiddleware({ config, sessionSecret, contextService }) {
  return async function authMiddleware(req, res, next) {
    try {
      const authHeader = String(req.headers.authorization || '').trim();
      const bearerToken = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7).trim()
        : '';
      const providedKey = String(
        req.headers['x-api-key'] || req.query.apiKey || bearerToken || ''
      ).trim();

      // 1. Signed Google session Bearer/JWT token
      const sessionPayload = providedKey
        ? verifyToken(providedKey, sessionSecret)
        : null;
      if (
        sessionPayload &&
        sessionPayload.typ === 'session' &&
        (sessionPayload.folderName !== undefined || sessionPayload.email)
      ) {
        const configuredFolder = resolveConfiguredUserFolder(
          sessionPayload.email,
          config
        );
        const effectiveFolder = configuredFolder.matched
          ? configuredFolder.folderName
          : (sessionPayload.folderName === '__ROOT__' || !sessionPayload.folderName
              ? null
              : sessionPayload.folderName);

        if (!effectiveFolder) {
          await contextService.ensureDefaultHashIndexReady();
          req.userContext = {
            folderName: null,
            storageDir: config.storageDir,
            hashIndex: contextService.defaultHashIndex,
            sub: sessionPayload.sub || null,
            email: sessionPayload.email || null,
            name: sessionPayload.name || null,
            nodeId: sessionPayload.nodeId || 'primary',
            authType: 'google_session',
          };
          return next();
        }

        const folderCtx = await contextService.getOrCreateFolderContext(effectiveFolder);
        req.userContext = {
          ...folderCtx,
          sub: sessionPayload.sub || null,
          email: sessionPayload.email || null,
          name: sessionPayload.name || null,
          nodeId: sessionPayload.nodeId || 'primary',
          authType: 'google_session',
        };
        return next();
      }

      // 2. Multi-user key map (USER_KEYS)
      if (config.userKeyMap.size > 0 && config.userKeyMap.has(providedKey)) {
        const folderName = config.userKeyMap.get(providedKey);
        const folderCtx = await contextService.getOrCreateFolderContext(folderName);
        req.userContext = {
          ...folderCtx,
          apiKey: providedKey,
          nodeId: 'primary',
          authType: 'api_key',
        };
        return next();
      }

      // 3. Single shared API_KEY
      if (config.apiKey && providedKey === config.apiKey) {
        req.userContext = {
          folderName: null,
          apiKey: providedKey,
          storageDir: config.storageDir,
          hashIndex: contextService.defaultHashIndex,
          nodeId: 'primary',
          authType: 'api_key',
        };
        return next();
      }

      // 4. Open access when no authentication mechanism is configured
      const authRequired =
        config.userKeyMap.size > 0 ||
        Boolean(config.apiKey) ||
        Boolean(config.googleClientId) ||
        config.requireAuth;
      if (!authRequired) {
        req.userContext = {
          folderName: null,
          storageDir: config.storageDir,
          hashIndex: contextService.defaultHashIndex,
          nodeId: 'primary',
          authType: 'open',
        };
        return next();
      }

      return res.status(401).json({
        success: false,
        canDelete: false,
        error: 'Unauthorized: Sign in with Google or provide a valid session token.',
      });
    } catch (err) {
      return next(err);
    }
  };
}

module.exports = { createAuthMiddleware };
