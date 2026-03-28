const rateLimit = require("express-rate-limit");
const config = require("../config");

const downloadLimiter = rateLimit({
  windowMs: config.rateLimit.windowMs,
  max: config.rateLimit.max,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    error: `Too many requests. Limit: ${config.rateLimit.max} per ${config.rateLimit.windowMs / 1000}s.`,
  },
});

module.exports = { downloadLimiter };