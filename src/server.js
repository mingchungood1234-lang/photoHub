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
      const { port, webPort, protocol, sslCertPath, sslKeyPath, storageDir, userKeyMap } =
        app.locals.config;
      const scheme = protocol === 'https' ? 'https' : 'http';

      const createServerInstance = () => {
        let srv;
        if (protocol === 'https') {
          if (!sslCertPath || !sslKeyPath) {
            throw new Error(
              'PROTOCOL=https requires SSL_CERT_PATH and SSL_KEY_PATH in .env'
            );
          }
          srv = https.createServer(
            {
              cert: fs.readFileSync(sslCertPath),
              key: fs.readFileSync(sslKeyPath),
            },
            app
          );
        } else {
          srv = http.createServer(app);
        }
        // Keep TCP/TLS sockets warm longer (65s vs Node's 5s default) and allow slow
        // large-video uploads over Tailscale/WAN without hitting Node 22's 5-min requestTimeout.
        srv.keepAliveTimeout = 65_000;
        srv.headersTimeout = 66_000;
        srv.requestTimeout = 0;
        return srv;
      };

      const servers = [];
      const apiServer = createServerInstance();
      servers.push(apiServer);

      const useSeparateWebPort = Number.isInteger(webPort) && webPort > 0 && webPort !== port;
      let webServer = null;
      if (useSeparateWebPort) {
        webServer = createServerInstance();
        servers.push(webServer);
      }

      let shuttingDown = false;
      const shutdown = () => {
        if (shuttingDown) return;
        shuttingDown = true;
        const flushFn = app.locals && app.locals.flushAllIndexes;
        Promise.resolve(typeof flushFn === 'function' ? flushFn() : null)
          .catch(() => {})
          .finally(() => {
            Promise.all(
              servers.map((s) => new Promise((resolve) => s.close(resolve)))
            ).finally(() => process.exit(0));
            setTimeout(() => process.exit(0), 3000).unref();
          });
      };
      process.once('SIGINT', shutdown);
      process.once('SIGTERM', shutdown);

      apiServer.listen(port, '0.0.0.0', () => {
        console.log(`PhotoHub backend listening on ${scheme}://0.0.0.0:${port}`);
        console.log(`Base storage directory: ${storageDir}`);
        if (userKeyMap.size > 0) {
          console.log(
            `Multi-user folders active: ${Array.from(new Set(userKeyMap.values())).join(', ')}`
          );
        }
      });

      if (webServer) {
        webServer.listen(webPort, '0.0.0.0', () => {
          console.log(`PhotoHub webpage listening on ${scheme}://0.0.0.0:${webPort}`);
        });
      }
    })
    .catch((err) => {
      console.error('Failed to start server:', err);
      process.exit(1);
    });
}

module.exports = { createApp };
