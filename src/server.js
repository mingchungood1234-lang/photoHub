/**
 * ENTRY POINT — HTTP / HTTPS Server Bootstrap
 *
 * Where this belongs: Top-level entry script (`npm start` / `node src/server.js`).
 * Where it connects: Imports `createApp()` from `./app`, wraps the Express app in
 * Node's built-in `http` or `https` server, and starts listening on `PORT`.
 * Also exports `{ createApp }` so `test/server.test.js` can spin up isolated test servers.
 */

const fs = require('fs');
const http = require('http');
const https = require('https');
const { createApp } = require('./app');

// `require.main === module` is true ONLY when you run `node src/server.js` directly
// (and false when another file like a test imports `./server` via `require`).
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
        // Keep TCP/TLS sockets warm longer (65s vs Node's 5s default) so phones
        // can reuse connections across rapid bursts of photo fetches.
        server.keepAliveTimeout = 65_000;
        server.headersTimeout = 66_000;
        server.listen(port, '0.0.0.0', onListening);
      } else {
        const server = http.createServer(app);
        // Match reverse proxy (Nginx/Caddy) keep-alive windows for faster photo browsing.
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
