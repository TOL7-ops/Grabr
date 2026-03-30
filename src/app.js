const express = require("express");
const cors    = require("cors");
const helmet  = require("helmet");
const morgan  = require("morgan");
const path    = require("path");
const fs      = require("fs");

const downloadRoutes             = require("./routes/download.routes");
const { notFound, errorHandler } = require("./middlewares/error.middleware");
const config = require("./config");
const logger = require("./utils/logger");

const app = express();
app.set("trust proxy", 1);

// ── CORS ──────────────────────────────────────────────────────────
// Allow ALL *.vercel.app subdomains + localhost (any port)
// This means any Vercel deployment URL works automatically
function isAllowedOrigin(origin) {
  if (!origin) return true; // curl, Postman, mobile apps
  if (/^https:\/\/[a-z0-9-]+\.vercel\.app$/.test(origin)) return true;
  if (/^http:\/\/localhost:\d+$/.test(origin)) return true;
  if (/^http:\/\/127\.0\.0\.1:\d+$/.test(origin)) return true;
  // Also allow any explicit CORS_ORIGIN env var
  if (process.env.CORS_ORIGIN && origin === process.env.CORS_ORIGIN) return true;
  return false;
}

app.use(cors({
  origin: (origin, cb) => {
    if (isAllowedOrigin(origin)) return cb(null, true);
    logger.warn("CORS blocked", { origin });
    cb(new Error(`CORS: ${origin} not allowed`));
  },
  methods: ["GET", "POST", "OPTIONS"],
  allowedHeaders: ["Content-Type", "Authorization"],
  credentials: false,
}));

// Handle preflight for all routes
app.options("*", cors());

app.use(helmet({ crossOriginResourcePolicy: { policy: "cross-origin" } }));
app.use(morgan("combined", {
  stream: { write: msg => logger.http(msg.trim()) },
  skip: () => config.nodeEnv === "test",
}));
app.use(express.json({ limit: "10kb" }));

// ── File serving ──────────────────────────────────────────────────
// Forces download on all browsers including mobile
// Only blocks path traversal (..) — accepts all other filenames
app.get("/files/:filename(*)", (req, res) => {
  let filename;
  try { filename = decodeURIComponent(req.params.filename); }
  catch { return res.status(400).json({ error: "Invalid filename encoding" }); }

  if (filename.includes("..") || filename.includes("/") || filename.includes("\\")) {
    return res.status(400).json({ error: "Invalid filename" });
  }

  const downloadDir = path.resolve(config.storage.downloadPath);
  const filePath    = path.join(downloadDir, filename);

  if (!filePath.startsWith(downloadDir + path.sep)) {
    return res.status(400).json({ error: "Invalid path" });
  }

  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ error: "File not found", filename });
  }

  const stat = fs.statSync(filePath);
  const ext  = path.extname(filename).toLowerCase();

  const mimeMap = {
    ".mp4": "video/mp4",  ".webm": "video/webm",
    ".mkv": "video/x-matroska", ".mov": "video/quicktime",
    ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
    ".ogg": "audio/ogg",  ".wav": "audio/wav", ".opus": "audio/opus",
  };

  res.setHeader("Content-Type",        mimeMap[ext] || "application/octet-stream");
  res.setHeader("Content-Disposition", `attachment; filename="${encodeURIComponent(filename)}"`);
  res.setHeader("Content-Length",      stat.size);
  res.setHeader("Accept-Ranges",       "bytes");
  res.setHeader("Cache-Control",       "no-cache");
  res.setHeader("Access-Control-Allow-Origin", "*");

  res.sendFile(filePath, { root: "/" }, err => {
    if (err && !res.headersSent) {
      logger.error("sendFile error", { filename, error: err.message });
      res.status(500).json({ error: "Failed to send file" });
    }
  });
});

// Debug endpoint
app.get("/debug/path", (_req, res) => {
  const dir = config.storage.downloadPath;
  let writable = false, exists = fs.existsSync(dir);
  try { fs.accessSync(dir, fs.constants.W_OK); writable = true; } catch {}
  let files = [];
  try { files = fs.readdirSync(dir).slice(-5); } catch {}
  res.json({
    downloadPath: dir, exists, writable,
    baseUrl: config.baseUrl,
    NODE_ENV: process.env.NODE_ENV,
    RUN_WORKER: process.env.RUN_WORKER,
    recentFiles: files,
  });
});

app.use("/api/download", downloadRoutes);

app.get("/health", (_req, res) => {
  res.json({ status: "ok", uptime: process.uptime(), ts: new Date().toISOString() });
});

app.use(notFound);
app.use(errorHandler);
module.exports = app;
