require("dotenv").config();
const app    = require("./app");
const config = require("./config");
const logger = require("./utils/logger");
const { pruneOldFiles } = require("./services/download.service");

const server = app.listen(config.port, () => {
  logger.info("Server started", {
    port:      config.port,
    env:       config.nodeEnv,
    baseUrl:   config.baseUrl,
    runWorker: process.env.RUN_WORKER,
    redisUrl:  process.env.REDIS_URL ? "set" : "not set",
  });
});

pruneOldFiles();
const pruneInterval = setInterval(pruneOldFiles, 60 * 60 * 1000);

// ── Embedded worker ───────────────────────────────────────────────
// WHY: API and worker must share the same Node.js process to share
//      the sseClients Map. Separate Railway services = separate Maps
//      = worker can't push to SSE = only pings forever.
//
// HOW: set RUN_WORKER=true in Railway → API service → Variables
//      Worker starts in same process → shares sseClients → SSE works
//
// SAFE: wrapped in try/catch so a worker crash doesn't kill the API
if (process.env.RUN_WORKER === "true") {
  try {
    logger.info("Starting embedded worker...");
    require("./workers/download.worker");
    logger.info("Embedded worker started OK");
  } catch (err) {
    // Log but don't crash — API stays up even if worker fails
    logger.error("Embedded worker failed to start", {
      error: err.message,
      stack: err.stack,
    });
  }
}

async function shutdown(signal) {
  logger.info(`${signal} — shutting down`);
  clearInterval(pruneInterval);
  server.close(() => {
    logger.info("HTTP server closed");
    process.exit(0);
  });
  setTimeout(() => { logger.error("Forced shutdown"); process.exit(1); }, 10_000);
}

process.on("SIGTERM",            () => shutdown("SIGTERM"));
process.on("SIGINT",             () => shutdown("SIGINT"));
process.on("uncaughtException",  err => {
  logger.error("Uncaught exception", { error: err.message });
  process.exit(1);
});
process.on("unhandledRejection", reason => {
  logger.error("Unhandled rejection", { reason: String(reason) });
  process.exit(1);
});
