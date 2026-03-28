require("dotenv").config();

const config = {
  port: parseInt(process.env.PORT, 10) || 3000,
  nodeEnv: process.env.NODE_ENV || "development",
  baseUrl: process.env.BASE_URL || "http://localhost:3000",

  redis: {
    host: process.env.REDIS_HOST || "localhost",
    port: parseInt(process.env.REDIS_PORT, 10) || 6379,
    password: process.env.REDIS_PASSWORD || undefined,
  },

  storage: {
    downloadPath: process.env.DOWNLOAD_PATH || "downloads",
    maxFileSizeMb: parseInt(process.env.MAX_FILE_SIZE_MB, 10) || 500,
    maxFileAgeHours: parseInt(process.env.MAX_FILE_AGE_HOURS, 10) || 24,
  },

  rateLimit: {
    windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS, 10) || 60_000,
    max: parseInt(process.env.RATE_LIMIT_MAX, 10) || 10,
  },

  queue: {
    attempts: parseInt(process.env.JOB_ATTEMPTS, 10) || 3,
    backoffDelay: parseInt(process.env.JOB_BACKOFF_DELAY, 10) || 5000,
  },

  allowedDomains: (
    process.env.ALLOWED_DOMAINS ||
    "youtube.com,youtu.be,instagram.com,www.youtube.com,www.instagram.com,m.youtube.com"
  )
    .split(",")
    .map((d) => d.trim()),
};

module.exports = config;