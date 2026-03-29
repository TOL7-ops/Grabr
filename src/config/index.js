require("dotenv").config();
const os   = require("os");
const path = require("path");

function resolveDownloadPath() {
  const raw = (process.env.DOWNLOAD_PATH || "").trim();
  const isWindowsPath = /^[A-Za-z]:[\\\/]|^\/mnt\/[a-z]\//.test(raw);
  if (raw && !isWindowsPath && path.isAbsolute(raw)) return raw;
  if (process.env.NODE_ENV === "production" || process.env.RAILWAY_ENVIRONMENT) return "/tmp/downloads";
  return path.join(os.tmpdir(), "grabr-downloads");
}

const config = {
  port:    parseInt(process.env.PORT, 10) || 3000,
  nodeEnv: process.env.NODE_ENV || "development",
  baseUrl: (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, ""),
  redis: {
    host:     process.env.REDIS_HOST || "localhost",
    port:     parseInt(process.env.REDIS_PORT, 10) || 6379,
    password: process.env.REDIS_PASSWORD || undefined,
  },
  storage: {
    downloadPath:    resolveDownloadPath(),
    maxFileSizeMb:   parseInt(process.env.MAX_FILE_SIZE_MB, 10)   || 500,
    maxFileAgeHours: parseInt(process.env.MAX_FILE_AGE_HOURS, 10) || 24,
  },
  rateLimit: {
    windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS, 10) || 60_000,
    max:      parseInt(process.env.RATE_LIMIT_MAX, 10)        || 10,
  },
  queue: {
    attempts:     parseInt(process.env.JOB_ATTEMPTS, 10)     || 3,
    backoffDelay: parseInt(process.env.JOB_BACKOFF_DELAY, 10) || 5000,
  },
  allowedDomains: (
    process.env.ALLOWED_DOMAINS ||
    "youtube.com,youtu.be,instagram.com,tiktok.com,twitter.com,x.com,t.co"
  ).split(",").map(d => d.trim()),
};

console.log(`[config] downloadPath=${config.storage.downloadPath} env=${config.nodeEnv}`);
module.exports = config;
