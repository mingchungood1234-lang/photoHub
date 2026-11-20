const crypto = require('crypto');
const {
  signToken,
  verifyToken,
  isAllowedAppRedirectUri,
  selectNodeForUser,
} = require('../models/userModel');

function createAuthController({
  config,
  sessionSecret,
  userDirectory,
  exchangeStore,
  googleExchangeFn,
  contextService,
}) {
  return {
    getConfig(req, res) {
      return res.json({
        success: true,
        googleEnabled: Boolean(config.googleClientId && config.googleClientSecret),
        hasStorageNodes: config.storageNodes.length > 0,
        nodeCount: config.storageNodes.length || 1,
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

      if (!codeChallenge || codeChallenge.length < 32 || !isAllowedAppRedirectUri(redirectUri)) {
        return res.status(400).json({
          success: false,
          error: 'Valid PKCE code_challenge and photohub://auth redirect_uri are required.',
        });
      }

      const baseUrl = contextService.resolveRequestBaseUrl(req);
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
      if (
        !statePayload ||
        statePayload.typ !== 'oauth_state' ||
        !isAllowedAppRedirectUri(statePayload.redirectUri)
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

        const user = await userDirectory.upsertGoogleUser({
          ...profile,
          publicBaseUrl: statePayload.baseUrl,
          config,
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
