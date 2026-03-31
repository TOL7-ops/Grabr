const Redis  = require("ioredis");
const logger = require("../utils/logger");

let client = null;

function getRedisClient() {
  if (client) return client;

  const url  = process.env.REDIS_URL;
  const host = process.env.REDIS_HOST || "localhost";
  const port = parseInt(process.env.REDIS_PORT, 10) || 6379;
  const pass = process.env.REDIS_PASSWORD || undefined;

  const baseOpts = {
    maxRetriesPerRequest: null,   // required by BullMQ
    enableReadyCheck:     false,
    lazyConnect:          false,
    retryStrategy: (times) => {
      if (times > 10) return null; // stop retrying after 10 attempts
      return Math.min(times * 500, 3000);
    },
  };

  // Prefer REDIS_URL (Railway native format) over separate host/port
  if (url) {
    logger.info("Redis: connecting via REDIS_URL");
    client = new Redis(url, baseOpts);
  } else {
    logger.info("Redis: connecting via host/port", { host, port });
    client = new Redis({ host, port, password: pass, ...baseOpts });
  }

  client.on("connect", () => logger.info("Redis connected"));
  client.on("ready",   () => logger.info("Redis ready"));
  client.on("error",   err => logger.error("Redis error", { error: err.message }));
  client.on("close",   ()  => logger.warn("Redis connection closed"));

  return client;
}

module.exports = { getRedisClient };
