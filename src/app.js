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

// ── CORS — allow ALL *.vercel.app + localhost ─────────────────────
function isAllowedOrigin(origin) {
  if (!origin) return true;
  if (/^https:\/\/[a-zA-Z0-9-]+\.vercel\.app$/.test(origin)) return true;
  if (/^http:\/\/localhost:\d+$/.test(origin)) return true;
  if (/^http:\/\/127\.0\.0\.1:\d+$/.test(origin)) return true;
  if (process.env.CORS_ORIGIN && origin === process.env.CORS_ORIGIN) return true;
  return false;
}

app.use(cors({
  origin: (origin, cb) => isAllowedOrigin(origin) ? cb(null, true) : cb(new Error(`CORS: ${origin}`)),
  methods: ["GET", "POST", "OPTIONS"],
  allowedHeaders: ["Content-Type", "Authorization"],
  credentials: false,
}));
app.options("*", cors());

app.use(helmet({ crossOriginResourcePolicy: { policy: "cross-origin" } }));
app.use(morgan("combined", {
  stream: { write: msg => logger.http(msg.trim()) },
  skip: () => config.nodeEnv === "test",
}));
app.use(express.json({ limit: "10kb" }));

// ── MIME types ────────────────────────────────────────────────────
const MIME = {
  ".mp4":  "video/mp4",
  ".webm": "video/webm",
  ".mkv":  "video/x-matroska",
  ".mov":  "video/quicktime",
  ".mp3":  "audio/mpeg",
  ".m4a":  "audio/mp4",
  ".ogg":  "audio/ogg",
  ".wav":  "audio/wav",
  ".opus": "audio/opus",
};

// ── File serving ──────────────────────────────────────────────────
// Uses wildcard route to accept filenames with dots, dashes, spaces
// Only blocks path traversal (..)
// Sets Content-Disposition: attachment → forces download on all browsers
// Sets correct MIME → iOS offers "Save to Photos" for video/mp4
app.get("/files/:filename(*)", (req, res) => {
  let filename;
  try {
    filename = decodeURIComponent(req.params.filename);
  } catch {
    return res.status(400).json({ error: "Bad filename encoding" });
  }

  // Only block traversal — allow dots, dashes, spaces, underscores
  if (filename.includes("..") || filename.includes("/") || filename.includes("\\")) {
    return res.status(400).json({ error: "Invalid filename" });
  }

  const downloadDir = path.resolve(config.storage.downloadPath);
  const filePath    = path.join(downloadDir, filename);

  // Ensure within download dir
  if (!filePath.startsWith(downloadDir + path.sep)) {
    return res.status(400).json({ error: "Invalid path" });
  }

  if (!fs.existsSync(filePath)) {
    logger.warn("File not found", { filename });
    return res.status(404).json({ error: "File not found", filename });
  }

  const stat      = fs.statSync(filePath);
  const ext       = path.extname(filename).toLowerCase();
  const mimeType  = MIME[ext] || "application/octet-stream";
  const isVideo   = mimeType.startsWith("video/");

  // Content-Disposition: attachment → forces download (not open-in-browser)
  // iOS Safari: video/mp4 + attachment → "Save to Photos" option appears
  res.setHeader("Content-Type",        mimeType);
  res.setHeader("Content-Disposition", `attachment; filename="${encodeURIComponent(filename)}"`);
  res.setHeader("Content-Length",      stat.size);
  res.setHeader("Accept-Ranges",       "bytes");
  res.setHeader("Cache-Control",       "no-cache");
  res.setHeader("Access-Control-Allow-Origin", "*");
  // faststart flag in ffmpeg moves moov atom to front → mobile can play while downloading
  if (isVideo) {
    res.setHeader("X-Content-Type-Options", "nosniff");
  }

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
  res.json({ downloadPath: dir, exists, writable, baseUrl: config.baseUrl,
             NODE_ENV: process.env.NODE_ENV, RUN_WORKER: process.env.RUN_WORKER, recentFiles: files });
});

app.use("/api/download", downloadRoutes);
app.get("/health", (_req, res) => res.json({ status: "ok", uptime: process.uptime(), ts: new Date().toISOString() }));
app.use(notFound);
app.use(errorHandler);
module.exports = app;
