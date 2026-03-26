const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");
const path = require("path");

const downloadRoutes = require("./routes/download.routes");
const { notFound, errorHandler } = require("./middlewares/error.middleware");
const config = require("./config");
const logger = require("./utils/logger");

const app = express();

// Trust first proxy — required for rate limiter to use X-Forwarded-For
app.set("trust proxy", 1);

// Security headers
app.use(helmet());

// CORS — tighten CORS_ORIGIN in production
app.use(
  cors({
    origin: process.env.CORS_ORIGIN || "*",
    methods: ["GET", "POST"],
  })
);

// HTTP request logging
app.use(
  morgan("combined", {
    stream: { write: (msg) => logger.http(msg.trim()) },
    skip: () => config.nodeEnv === "test",
  })
);

app.use(express.json({ limit: "10kb" }));

// Serve downloaded files — direct streaming, no path traversal
app.use(
  "/files",
  (req, res, next) => {
    // Decode and re-encode to block traversal sequences like ../
    const decoded = decodeURIComponent(req.path.replace(/^\//, ""));
    if (decoded.includes("..") || decoded.includes("/") || decoded.includes("\\")) {
      return res.status(400).json({ error: "Invalid filename" });
    }
    next();
  },
  express.static(path.resolve(config.storage.downloadPath), {
  dotfiles: "deny",
  index: false,
})
);

// API routes
app.use("/api/download", downloadRoutes);

// Health check
app.get("/health", (_req, res) => {
  res.json({ status: "ok", uptime: process.uptime(), ts: new Date().toISOString() });
});

// 404 + error handlers — must be last
app.use(notFound);
app.use(errorHandler);

module.exports = app;