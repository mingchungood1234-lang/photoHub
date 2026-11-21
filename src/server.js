const fs = require('fs');
const http = require('http');
const https = require('https');
const { createApp } = require('./app');

if (require.main === module) {
  createApp()
    .then((app) => {
      const { port, protocol, sslCertPath, sslKeyPath, storageDir, userKeyMap } =
        app.locals.config;

      const onListening = () => {
        const scheme = protocol === 'https' ? 'https' : 'http';
        console.log(`PhotoHub backend listening on ${scheme}://0.0.0.0:${port}`);
        console.log(`Base storage directory: ${storageDir}`);
        if (userKeyMap.size > 0) {
          console.log(
            `Multi-user folders active: ${Array.from(new Set(userKeyMap.values())).join(', ')}`
          );
        }
      };

      if (protocol === 'https') {
        if (!sslCertPath || !sslKeyPath) {
          throw new Error(
            'PROTOCOL=https requires SSL_CERT_PATH and SSL_KEY_PATH in .env'
          );
        }
        const server = https.createServer(
          {
            cert: fs.readFileSync(sslCertPath),
            key: fs.readFileSync(sslKeyPath),
          },
          app
        );
        server.keepAliveTimeout = 65_000;
        server.headersTimeout = 66_000;
        server.listen(port, '0.0.0.0', onListening);
      } else {
        const server = http.createServer(app);
        server.keepAliveTimeout = 65_000;
        server.headersTimeout = 66_000;
        server.listen(port, '0.0.0.0', onListening);
      }
    })
    .catch((err) => {
      console.error('Failed to start server:', err);
      process.exit(1);
    });
}

module.exports = { createApp };
