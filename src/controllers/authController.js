/**
 * GOOGLE OAUTH PKCE & NODE ROUTING CONTROLLER
 *
 * Where this belongs: `src/controllers/authController.js`.
 * Called by:
 *   - `src/routes/publicRoutes.js`: `getConfig`, `startGoogleAuth`, `handleGoogleCallback`, `exchangeCode`
 *   - `src/routes/accountRoutes.js`: `resolveNode` (authenticated)
 * Calls: `models/userModel.js` (JWT tokens, PKCE check, consistent node selection),
 *        `services/googleOAuthService.js` (exchanges Google's auth code for user email/sub),
 *        and `services/contextService.js` (resolves public base URL).
 *
 * Step-by-step Google PKCE login flow:
 *   1. Mobile app creates a random `codeVerifier`, hashes it into `codeChallenge`, and opens `/api/auth/google/start`.
 *   2. Server redirects browser to Google -> Google redirects back to `/api/auth/google/callback`.
 *   3. Server creates/updates the user in `UserDirectory`, mints a signed JWT session token, stores it behind
 *      a 1-time code, and redirects to `photohub://auth/callback?code=...`.
 *   4. App POSTs `{ code, codeVerifier }` to `/api/auth/exchange` -> gets `{ token, serverUrl, user }`.
 */

const crypto = require('crypto');
const {
  signToken,
  verifyToken,
  isAllowedAppRedirectUri,
  selectNodeForUser,
} = require('../models/userModel');
const { isS3Configured } = require('../services/s3Service');

function buildAllowedWebOrigins(baseUrl, config, req = null) {
  const origins = new Set();
  const addUrl = (raw) => {
    if (!raw) return;
    try {
      const parsed = new URL(raw);
      origins.add(parsed.origin);
      if (config && config.webPort > 0) {
        origins.add(`${parsed.protocol}//${parsed.hostname}:${config.webPort}`);
        if (parsed.protocol === 'https:') {
          origins.add(`http://${parsed.hostname}:${config.webPort}`);
        }
      }
    } catch {
      // ignore invalid URL
    }
  };
  addUrl(baseUrl);
  addUrl(config && config.publicUrl);
  addUrl(config && config.publicWebUrl);
  if (req && req.headers && req.headers.host) {
    const proto = String(req.headers['x-forwarded-proto'] || req.protocol || 'http')
      .split(',')[0]
      .trim();
    addUrl(`${proto}://${req.headers.host}`);
  }
  return Array.from(origins);
}

function createAuthController({
  config,
  sessionSecret,
  userDirectory,
  exchangeStore,
  googleExchangeFn,
  contextService,
  nodeAllocationService = null,
}) {
  return {
    getConfig(req, res) {
      const googleEnabled = Boolean(config.googleClientId && config.googleClientSecret);
      const apiKeyEnabled = Boolean(config.userKeyMap.size > 0 || config.apiKey);
      const authRequired = Boolean(
        apiKeyEnabled || Boolean(config.googleClientId) || config.requireAuth
      );
      return res.json({
        success: true,
        googleEnabled,
        apiKeyEnabled,
        authRequired,
        s3Enabled: isS3Configured(config.s3),
        hasStorageNodes: config.storageNodes.length > 0,
        nodeCount: config.storageNodes.length || 1,
        nodeAllocationMode: config.nodeAllocationMode || 'ordered',
      });
    },

    startGoogleAuth(req, res) {
      if (!config.googleClientId || !config.googleClientSecret) {
        return res.status(501).json({
          success: false,
          error:
            'Google Login is not configured on this server. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in .env.',
        });
      }

      const codeChallenge = String(req.query.code_challenge || '').trim();
      const redirectUri = String(
        req.query.redirect_uri || 'photohub://auth/callback'
      ).trim();
      const baseUrl = contextService.resolveRequestBaseUrl(req);
      const allowedWebOrigins = buildAllowedWebOrigins(baseUrl, config, req);

      if (
        !codeChallenge ||
        codeChallenge.length < 32 ||
        !isAllowedAppRedirectUri(redirectUri, allowedWebOrigins)
      ) {
        return res.status(400).json({
          success: false,
          error: 'Valid PKCE code_challenge and allowed redirect_uri are required.',
        });
      }

      const state = signToken(
        {
          typ: 'oauth_state',
          nonce: crypto.randomBytes(16).toString('hex'),
          codeChallenge,
          redirectUri,
          baseUrl,
        },
        sessionSecret,
        600
      );

      const authUrl = new URL('https://accounts.google.com/o/oauth2/v2/auth');
      authUrl.searchParams.set('client_id', config.googleClientId);
      authUrl.searchParams.set('redirect_uri', `${baseUrl}/api/auth/google/callback`);
      authUrl.searchParams.set('response_type', 'code');
      authUrl.searchParams.set('scope', 'openid email profile');
      authUrl.searchParams.set('state', state);
      authUrl.searchParams.set('prompt', 'select_account');

      return res.redirect(authUrl.toString());
    },

    async handleGoogleCallback(req, res) {
      const statePayload = verifyToken(String(req.query.state || ''), sessionSecret);
      const allowedWebOrigins = statePayload
        ? buildAllowedWebOrigins(statePayload.baseUrl, config, req)
        : [];
      if (
        !statePayload ||
        statePayload.typ !== 'oauth_state' ||
        !isAllowedAppRedirectUri(statePayload.redirectUri, allowedWebOrigins)
      ) {
        return res.status(400).send('Invalid or expired OAuth state.');
      }

      const appRedirect = new URL(statePayload.redirectUri);
      const oauthError = req.query.error;
      if (oauthError) {
        appRedirect.searchParams.set('error', String(oauthError));
        return res.redirect(appRedirect.toString());
      }

      const googleCode = String(req.query.code || '').trim();
      if (!googleCode) {
        appRedirect.searchParams.set('error', 'Missing authorization code from Google.');
        return res.redirect(appRedirect.toString());
      }

      try {
        const profile = await googleExchangeFn({
          code: googleCode,
          redirectUri: `${statePayload.baseUrl}/api/auth/google/callback`,
          config,
        });

        const allocation = nodeAllocationService
          ? await nodeAllocationService.resolveNodeAndCapacityForLogin({
              sub: profile.sub,
              email: profile.email,
              publicBaseUrl: statePayload.baseUrl,
            })
          : await contextService.checkNewUserSignupCapacity({
              sub: profile.sub,
              email: profile.email,
              publicBaseUrl: statePayload.baseUrl,
            });
        if (!allocation.allowed) {
          appRedirect.searchParams.set(
            'error',
            allocation.reason || 'Server assigned storage is full. New sign-ins are closed.'
          );
          return res.redirect(appRedirect.toString());
        }

        const user = await userDirectory.upsertGoogleUser({
          ...profile,
          publicBaseUrl: statePayload.baseUrl,
          config,
          preferredNodeId: allocation.preferredNodeId || null,
        });

        const sessionToken = signToken(
          {
            typ: 'session',
            sub: user.sub,
            email: user.email,
            name: user.name,
            folderName: user.folderName ?? '__ROOT__',
            nodeId: user.nodeId,
          },
          sessionSecret,
          config.sessionTtlSeconds
        );

        const oneTimeCode = exchangeStore.issue({
          codeChallenge: statePayload.codeChallenge,
          sessionPayload: {
            token: sessionToken,
            serverUrl: user.assignedUrl || statePayload.baseUrl,
            nodeId: user.nodeId,
            user: {
              email: user.email,
              name: user.name,
              folderName: user.folderName || '',
              quotaBytes: user.quotaBytes > 0 ? user.quotaBytes : null,
            },
          },
        });

        appRedirect.searchParams.set('code', oneTimeCode);
        return res.redirect(appRedirect.toString());
      } catch (err) {
        appRedirect.searchParams.set('error', err.message || 'Google login failed');
        return res.redirect(appRedirect.toString());
      }
    },

    exchangeCode(req, res) {
      const { code, codeVerifier } = req.body || {};
      const session = exchangeStore.consume({ code, codeVerifier });
      if (!session) {
        return res.status(401).json({
          success: false,
          error: 'Invalid, expired, or mismatched authorization code.',
        });
      }
      return res.json({
        success: true,
        token: session.token,
        serverUrl: session.serverUrl,
        nodeId: session.nodeId,
        user: session.user,
      });
    },

    resolveNode(req, res) {
      const baseUrl = contextService.resolveRequestBaseUrl(req);
      const { folderName, email, name, sub, nodeId } = req.userContext;
      const existingUser = sub ? userDirectory.getBySub(sub) : null;
      const resolved = email
        ? selectNodeForUser({
            sub: sub || existingUser?.sub,
            email,
            publicBaseUrl: baseUrl,
            config,
            existingNodeId: existingUser?.nodeId || nodeId,
          })
        : { nodeId: nodeId || 'primary', serverUrl: baseUrl };

      return res.json({
        success: true,
        serverUrl: resolved.serverUrl || baseUrl,
        nodeId: resolved.nodeId,
        user: {
          email: email || null,
          name: name || null,
          folderName: folderName || '',
        },
      });
    },
  };
}

module.exports = { createAuthController };
