const Redis = require("ioredis");
const config = require("./index");
const logger = require("../utils/logger");

let client = null;

function getRedisClient() {
  if (client) return client;

  client = new Redis({
    host: config.redis.host,
    port: config.redis.port,
    password: config.redis.password,
    maxRetriesPerRequest: null, // Required by BullMQ
    enableReadyCheck: false,
    lazyConnect: false,
  });

  client.on("connect", () => logger.info("Redis connected"));
  client.on("error", (err) => logger.error("Redis error", { error: err.message }));
  client.on("close", () => logger.warn("Redis connection closed"));

  return client;
}

module.exports = { getRedisClient };