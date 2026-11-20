const express = require('express');
const { getConfig } = require('./config/env');
const {
  resolveSessionSecret,
  UserDirectory,
  OneTimeExchangeStore,
} = require('./models/userModel');
const { exchangeGoogleCodeForProfile } = require('./services/googleOAuthService');
const { createContextService } = require('./services/contextService');
const { createAuthMiddleware } = require('./middleware/authMiddleware');
const { createUploadMiddleware } = require('./middleware/uploadMiddleware');
const { errorMiddleware } = require('./middleware/errorMiddleware');
const { createHealthController } = require('./controllers/healthController');
const { createAuthController } = require('./controllers/authController');
const { createAccountController } = require('./controllers/accountController');
const { createCheckController } = require('./controllers/checkController');
const { createUploadController } = require('./controllers/uploadController');
const { createProxyController } = require('./controllers/proxyController');
const { createPhotoController } = require('./controllers/photoController');
const { mountRoutes } = require('./routes');

async function createApp(configOverrides = {}) {
  const config = getConfig(configOverrides);
  const sessionSecret = await resolveSessionSecret(
    config.authSessionSecret,
    config.dataDir
  );

  // Initialize models and domain services
  const userDirectory = new UserDirectory(config.dataDir);
  await userDirectory.init();
  const exchangeStore = new OneTimeExchangeStore();
  const googleExchangeFn =
    configOverrides.exchangeGoogleCodeForProfile || exchangeGoogleCodeForProfile;

  const contextService = createContextService(config);
  await contextService.init();

  // Build Express application
  const app = express();
  app.set('trust proxy', 1);
  app.locals.config = config;
  app.locals.hashIndex = contextService.defaultHashIndex;
  app.locals.folderContexts = contextService.folderContexts;
  app.locals.sessionSecret = sessionSecret;

  // Middleware
  const uploadMiddleware = createUploadMiddleware(config);
  const authMiddleware = createAuthMiddleware({
    config,
    sessionSecret,
    contextService,
  });

  app.use(express.json({ limit: '50mb' }));
  app.use('/api/upload', uploadMiddleware.rawUploadParser);

  // Controllers
  const controllers = {
    healthController: createHealthController({ config, contextService }),
    authController: createAuthController({
      config,
      sessionSecret,
      userDirectory,
      exchangeStore,
      googleExchangeFn,
      contextService,
    }),
    accountController: createAccountController({ config, contextService }),
    checkController: createCheckController(),
    uploadController: createUploadController({ config, contextService }),
    proxyController: createProxyController({ config }),
    photoController: createPhotoController({ config }),
  };

  // Routes & global error handler
  mountRoutes(app, { authMiddleware, uploadMiddleware, controllers });
  app.use(errorMiddleware);

  return app;
}

module.exports = { createApp };
