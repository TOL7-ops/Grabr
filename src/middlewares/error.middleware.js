const logger = require("../utils/logger");

// 404 handler — must be placed after all routes
function notFound(req, res, next) {
  res.status(404).json({ error: "Route not found", path: req.originalUrl });
}

// Global error handler — must have exactly 4 params so Express recognises it
// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  logger.error("Unhandled error", {
    message: err.message,
    stack: err.stack,
    path: req.originalUrl,
    method: req.method,
  });

  const status = err.status || err.statusCode || 500;
  const body = {
    error: err.message || "Internal server error",
  };

  if (process.env.NODE_ENV !== "production") {
    body.stack = err.stack;
  }

  res.status(status).json(body);
}

module.exports = { notFound, errorHandler };