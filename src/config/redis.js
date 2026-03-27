const Redis = require("ioredis");
const logger = require("../utils/logger");

let client = null;

function getRedisClient() {
  if (client) return client;

  // Railway provides REDIS_URL — prefer it over host/port
  const redisUrl = process.env.REDIS_URL;

  client = redisUrl
    ? new Redis(redisUrl, {
        maxRetriesPerRequest: null,
        enableReadyCheck: false,
      })
    : new Redis({
        host: process.env.REDIS_HOST || "localhost",
        port: parseInt(process.env.REDIS_PORT, 10) || 6379,
        password: process.env.REDIS_PASSWORD || undefined,
        maxRetriesPerRequest: null,
        enableReadyCheck: false,
      });

  client.on("connect", () => logger.info("Redis connected"));
  client.on("error",   (err) => logger.error("Redis error", { error: err.message }));

  return client;
}

module.exports = { getRedisClient };
