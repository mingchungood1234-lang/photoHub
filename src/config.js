/**
 * LEGACY CONFIG ENTRY POINT
 *
 * Where this belongs: Top-level alias under `src/`.
 * Re-exports `./config/env` so any external script requiring `src/config` gets
 * the exact same parsed environment settings object.
 */
module.exports = require('./config/env');
