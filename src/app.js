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

const allowedOrigins = [
  /https:\/\/.*\.vercel\.app$/,
  /http:\/\/localhost:\d+$/,
];
if (process.env.CORS_ORIGIN) allowedOrigins.push(process.env.CORS_ORIGIN);

app.use(cors({
  origin: (origin, cb) => {
    if (!origin) return cb(null, true);
    const ok = allowedOrigins.some(o => typeof o === "string" ? o === origin : o.test(origin));
    ok ? cb(null, true) : cb(new Error(`CORS blocked: ${origin}`));
  },
  methods: ["GET", "POST", "OPTIONS"],
  allowedHeaders: ["Content-Type", "Authorization"],
  credentials: false,
}));

app.use(helmet({ crossOriginResourcePolicy: { policy: "cross-origin" } }));
app.use(morgan("combined", {
  stream: { write: msg => logger.http(msg.trim()) },
  skip: () => config.nodeEnv === "test",
}));
app.use(express.json({ limit: "10kb" }));

// ── File serving ──────────────────────────────────────────────────
// Accepts any filename — only blocks path traversal (..)
// Forces download via Content-Disposition: attachment on all clients
app.get("/files/:filename(*)", (req, res) => {
  // Decode the filename (handles %20, %2B etc from encodeURIComponent)
  let filename;
  try { filename = decodeURIComponent(req.params.filename); }
  catch { return res.status(400).json({ error: "Invalid filename encoding" }); }

  // Block path traversal ONLY — do NOT reject special chars
  if (filename.includes("..") || filename.includes("/") || filename.includes("\\")) {
    return res.status(400).json({ error: "Invalid filename" });
  }

  const downloadDir = path.resolve(config.storage.downloadPath);
  const filePath    = path.join(downloadDir, filename);

  // Confirm path stays within download dir
  if (!filePath.startsWith(downloadDir + path.sep)) {
    return res.status(400).json({ error: "Invalid path" });
  }

  if (!fs.existsSync(filePath)) {
    logger.warn("File not found", { filename, filePath });
    return res.status(404).json({ error: "File not found", filename });
  }

  const stat = fs.statSync(filePath);
  const ext  = path.extname(filename).toLowerCase();

  const mimeMap = {
    ".mp4": "video/mp4",  ".webm": "video/webm", ".mkv": "video/x-matroska",
    ".mov": "video/quicktime", ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
    ".ogg": "audio/ogg",  ".wav": "audio/wav",   ".opus": "audio/opus",
  };

  // Content-Disposition: attachment forces download on ALL browsers
  // including iOS Safari and Android Chrome
  res.setHeader("Content-Type",        mimeMap[ext] || "application/octet-stream");
  res.setHeader("Content-Disposition", `attachment; filename="${encodeURIComponent(filename)}"`);
  res.setHeader("Content-Length",      stat.size);
  res.setHeader("Accept-Ranges",       "bytes");
  res.setHeader("Cache-Control",       "no-cache");
  res.setHeader("Access-Control-Allow-Origin", "*");

  // Send the file — works for range requests too
  res.sendFile(filePath, { root: "/" }, err => {
    if (err && !res.headersSent) {
      logger.error("sendFile error", { filename, error: err.message });
      res.status(500).json({ error: "Failed to send file" });
    }
  });
});

// Debug endpoint — shows resolved download path and BASE_URL
app.get("/debug/path", (_req, res) => {
  const dir = config.storage.downloadPath;
  let writable = false, exists = fs.existsSync(dir);
  try { fs.accessSync(dir, fs.constants.W_OK); writable = true; } catch {}
  // List recent files so you can test /files/:filename
  let files = [];
  try { files = fs.readdirSync(dir).slice(-5); } catch {}
  res.json({
    downloadPath: dir, exists, writable,
    baseUrl: config.baseUrl,
    NODE_ENV: process.env.NODE_ENV,
    BASE_URL_ENV: process.env.BASE_URL,
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
