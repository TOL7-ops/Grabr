require("dotenv").config();
const app    = require("./app");
const config = require("./config");
const logger = require("./utils/logger");
const { pruneOldFiles } = require("./services/download.service");

const server = app.listen(config.port, () => {
  logger.info("Server started", {
    port:    config.port,
    env:     config.nodeEnv,
    baseUrl: config.baseUrl,
    worker:  process.env.RUN_WORKER === "true" ? "embedded" : "external",
  });
});

pruneOldFiles();
const pruneInterval = setInterval(pruneOldFiles, 60 * 60 * 1000);

// ── Embedded worker ───────────────────────────────────────────────
// CRITICAL for SSE: API and worker must share the same Node.js process
// so they share the same sseClients Map in download.service.js
//
// Set RUN_WORKER=true in Railway → API service → Variables
// Then delete the separate worker service — you only need one service
if (process.env.RUN_WORKER === "true") {
  logger.info("Starting embedded worker (same process as API — SSE will work correctly)");
  require("./workers/download.worker");
}

async function shutdown(signal) {
  logger.info(`${signal} — shutting down`);
  clearInterval(pruneInterval);
  server.close(() => { logger.info("HTTP server closed"); process.exit(0); });
  setTimeout(() => { logger.error("Forced shutdown"); process.exit(1); }, 10_000);
}

process.on("SIGTERM",             () => shutdown("SIGTERM"));
process.on("SIGINT",              () => shutdown("SIGINT"));
process.on("uncaughtException",   err => { logger.error("Uncaught exception", { error: err.message }); process.exit(1); });
process.on("unhandledRejection",  reason => { logger.error("Unhandled rejection", { reason }); process.exit(1); });
