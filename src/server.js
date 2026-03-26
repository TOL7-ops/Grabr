require("dotenv").config();
const app = require("./app");
const config = require("./config");
const logger = require("./utils/logger");
const { pruneOldFiles } = require("./services/download.service");

const server = app.listen(config.port, () => {
  logger.info(`Server started`, {
    port: config.port,
    env: config.nodeEnv,
    baseUrl: config.baseUrl,
  });
});

// Run file cleanup on startup and every hour
pruneOldFiles();
const pruneInterval = setInterval(pruneOldFiles, 60 * 60 * 1000);

async function shutdown(signal) {
  logger.info(`${signal} received — shutting down`);
  clearInterval(pruneInterval);
  server.close(() => {
    logger.info("HTTP server closed");
    process.exit(0);
  });

  // Force exit after 10s
  setTimeout(() => {
    logger.error("Forced shutdown after timeout");
    process.exit(1);
  }, 10_000);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("uncaughtException", (err) => {
  logger.error("Uncaught exception", { error: err.message, stack: err.stack });
  process.exit(1);
});
process.on("unhandledRejection", (reason) => {
  logger.error("Unhandled rejection", { reason });
  process.exit(1);
});