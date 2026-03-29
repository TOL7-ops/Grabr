#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# fix-final.sh — Fix localhost URL, filename sanitization,
#                file serving, mobile download
# Run: bash script/fix-final.sh
# ─────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n${B}  $1${N}\n${C}══════════════════════════════════════════${N}"; }
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=""; dir="$SCRIPT_DIR"
for i in 1 2 3 4 5; do
  [ -f "$dir/src/app.js" ] && { BACKEND_DIR="$dir"; break; }; dir="$(dirname "$dir")"
done
[ -z "$BACKEND_DIR" ] && [ -f "$(pwd)/src/app.js" ] && BACKEND_DIR="$(pwd)"
[ -z "$BACKEND_DIR" ] && { echo -e "${R}Run from inside downloader-Api${N}"; exit 1; }

FRONTEND_DIR=""
for name in my-downloader-frontend grabr-frontend frontend; do
  [ -d "$BACKEND_DIR/$name/src" ] && { FRONTEND_DIR="$BACKEND_DIR/$name"; break; }
done

section "0. Paths"
pass "Backend  : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend : $FRONTEND_DIR" || warn "Frontend not found"

# ════════════════════════════════════════════════════════════════
section "1. ROOT CAUSE: BASE_URL=localhost in Railway"
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${B}  The SSE event showed:${N}"
echo '  fileUrl: "http://localhost:3000/files/..."'
echo ""
echo -e "${R}  This means BASE_URL is not set correctly on Railway!${N}"
echo ""
echo -e "${B}  ACTION REQUIRED — Railway Dashboard:${N}"
echo "  → Go to railway.app → your API service → Variables"
echo "  → Set: BASE_URL = https://grabr-production-fa32.up.railway.app"
echo "  → Do the SAME for your worker service"
echo ""
warn "Do this NOW before running anything else — it's the root cause of localhost URLs"
echo ""

# ════════════════════════════════════════════════════════════════
section "2. FIX: download.service.js — sanitize filename + correct fileUrl"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/services/download.service.js" << 'EOF'
const { spawn, execFile } = require("child_process");
const path   = require("path");
const fs     = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE registry ─────────────────────────────────────────────────
const sseClients = new Map();
function registerSSE(jobId, res)  { sseClients.set(String(jobId), res); }
function unregisterSSE(jobId)     { sseClients.delete(String(jobId)); }
function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) { logger.warn("SSE write failed", { jobId }); unregisterSSE(jobId); }
}

// ── Binary resolution ─────────────────────────────────────────────
function resolveBin(envKey, candidates) {
  const fromEnv = process.env[envKey];
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv;
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return candidates[0];
}
const YTDLP_BIN  = resolveBin("YTDLP_PATH",  ["/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp", "yt-dlp"]);
const FFMPEG_BIN = resolveBin("FFMPEG_PATH",  ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "ffmpeg"]);
logger.info("Binaries resolved", { ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN });

// ── Filename sanitizer ────────────────────────────────────────────
// Replaces any char that isn't alphanumeric, dash, underscore, or dot with underscore
// Also collapses multiple underscores and trims length
function sanitizeFilename(raw) {
  return raw
    .replace(/[^\w.-]+/g, "_")   // replace bad chars
    .replace(/_+/g, "_")          // collapse repeated underscores
    .replace(/^_+|_+$/g, "")      // trim leading/trailing underscores
    .slice(0, 200);               // max length
}

// ── Format map ────────────────────────────────────────────────────
const FORMAT_MAP = {
  mp4:   ["-f", "bestvideo+bestaudio/best", "--merge-output-format", "mp4"],
  mp3:   ["-f", "bestaudio/best", "--extract-audio", "--audio-format", "mp3"],
  webm:  ["-f", "bestvideo+bestaudio/best", "--merge-output-format", "webm"],
  m4a:   ["-f", "bestaudio/best", "--extract-audio", "--audio-format", "m4a"],
  "720p":  ["-f", "bestvideo[height<=720]+bestaudio/best[height<=720]",   "--merge-output-format", "mp4"],
  "1080p": ["-f", "bestvideo[height<=1080]+bestaudio/best[height<=1080]", "--merge-output-format", "mp4"],
  "480p":  ["-f", "bestvideo[height<=480]+bestaudio/best[height<=480]",   "--merge-output-format", "mp4"],
  "360p":  ["-f", "bestvideo[height<=360]+bestaudio/best[height<=360]",   "--merge-output-format", "mp4"],
  best:    ["-f", "bestvideo+bestaudio/best", "--merge-output-format", "mp4"],
};

function buildArgs(url, format, outputTemplate) {
  const cookiesFile = "/app/cookies/youtube.txt";
  const cookiesArgs = fs.existsSync(cookiesFile) ? ["--cookies", cookiesFile] : [];
  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist",
    "--restrict-filenames",
    "--js-runtimes",          "nodejs",
    "--max-filesize",         `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout",       "60",
    "--retries",              "5",
    "--fragment-retries",     "5",
    "--concurrent-fragments", "4",
    "--no-cache-dir",
    "--no-part",
    "--newline",
    "--ffmpeg-location",      FFMPEG_BIN,
    ...cookiesArgs,
    "-o",                     outputTemplate,
    url,
  ];
}

const RE_PROGRESS = /\[download\]\s+([\d.]+)%\s+of\s+([\d.]+\S+)\s+at\s+([\S]+)\s+ETA\s+([\S]+)/;
const RE_MERGE    = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG   = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST     = /\[download\] Destination:\s+(.+)/;

// ── runDownload ───────────────────────────────────────────────────
async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);

  if (!fs.existsSync(downloadDir)) {
    try { fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 }); }
    catch (e) { throw new Error(`Cannot create download dir ${downloadDir}: ${e.message}`); }
  }
  try { fs.accessSync(downloadDir, fs.constants.W_OK); }
  catch { throw new Error(`No write permission: ${downloadDir}. Set DOWNLOAD_PATH=/tmp/downloads`); }

  // Use sanitized template — yt-dlp --restrict-filenames helps but we double-sanitize
  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const args = buildArgs(url, format || "best", outputTemplate);

  // BASE_URL must be the public Railway URL — validated here so errors are obvious
  const baseUrl = config.baseUrl;
  if (baseUrl.includes("localhost") || baseUrl.includes("127.0.0.1")) {
    logger.warn("BASE_URL is localhost — fileUrl will be wrong in production!", { baseUrl });
  }

  logger.info("Starting download", { jobId, format, dir: downloadDir, baseUrl });

  const emit = (data) => {
    sendProgress(jobId, data);
    if (onProgress) onProgress(data, typeof data === "object" ? (data.percent || 0) : Number(data) || 0);
  };

  emit({ status: "starting", percent: 5 });

  const start = Date.now();
  let outputPath = null, stdoutBuf = "", stderrBuf = "", lastPct = 0, phase = "downloading";

  return new Promise((resolve, reject) => {
    const child = spawn(YTDLP_BIN, args, {
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });

    child.stdout.on("data", chunk => {
      stdoutBuf += chunk.toString();
      const lines = stdoutBuf.split("\n");
      stdoutBuf = lines.pop();
      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;

        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          emit({ status: "processing", percent: 99 });
        }

        const mM = line.match(RE_MERGE);
        const fM = line.match(RE_FFMPEG);
        const dM = line.match(RE_DEST);
        if (mM) outputPath = mM[1].trim();
        else if (fM) outputPath = fM[1].trim();
        else if (dM && !outputPath) outputPath = dM[1].trim();

        const pM = line.match(RE_PROGRESS);
        if (pM) {
          const percent = parseFloat(pM[1]);
          if (percent - lastPct >= 1 || percent >= 100) {
            lastPct = percent;
            emit({ status: "downloading", percent: Math.min(percent, 98), size: pM[2], speed: pM[3], eta: pM[4] });
          }
        }
      }
    });

    child.stderr.on("data", chunk => { stderrBuf += chunk.toString(); });

    child.on("close", code => {
      const elapsed = ((Date.now() - start) / 1000).toFixed(1);
      logger.info("yt-dlp exit", { jobId, code, elapsed: `${elapsed}s` });

      if (code !== 0) {
        const msg = stderrBuf.trim() || `yt-dlp exited with code ${code}`;
        emit({ status: "error", message: msg });
        return reject(new Error(msg));
      }

      // Find output file
      if (!outputPath || !fs.existsSync(outputPath)) {
        const files = fs.readdirSync(downloadDir)
          .filter(f => f.startsWith(String(jobId)))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(downloadDir, f)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime);
        if (!files.length) {
          emit({ status: "error", message: "Download completed but output file not found" });
          return reject(new Error("Output file not found"));
        }
        outputPath = path.join(downloadDir, files[0].name);
      }

      // Sanitize filename for URL safety
      const rawName   = path.basename(outputPath);
      const ext       = path.extname(rawName);
      const baseName  = path.basename(rawName, ext);
      const cleanName = sanitizeFilename(baseName) + ext;

      // Rename file if needed
      const cleanPath = path.join(downloadDir, cleanName);
      if (rawName !== cleanName) {
        try { fs.renameSync(outputPath, cleanPath); outputPath = cleanPath; }
        catch { /* keep original name if rename fails */ }
      }

      const filename  = path.basename(outputPath);
      // CRITICAL: use config.baseUrl which must be set to Railway URL in production
      const fileUrl   = `${baseUrl}/files/${encodeURIComponent(filename)}`;
      const mediaType = [".mp4",".webm",".mkv",".mov"].includes(ext.toLowerCase()) ? "video"
                      : [".mp3",".m4a",".ogg",".wav",".opus"].includes(ext.toLowerCase()) ? "audio"
                      : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });
      logger.info("Download complete", { jobId, filename, fileUrl, elapsed: `${elapsed}s` });
      resolve({ filePath: outputPath, filename, fileUrl, mediaType });
    });

    child.on("error", err => {
      emit({ status: "error", message: err.message });
      reject(err);
    });
  });
}

async function getMetadata(url) {
  return new Promise((resolve, reject) => {
    execFile(YTDLP_BIN, ["--dump-json", "--no-playlist", "--js-runtimes", "nodejs", url],
      { timeout: 30_000 }, (err, stdout) => {
        if (err) return reject(err);
        try {
          const d = JSON.parse(stdout);
          resolve({ title: d.title, thumbnail: d.thumbnail, duration: d.duration, uploader: d.uploader, extractor: d.extractor });
        } catch { reject(new Error("Failed to parse metadata")); }
      });
  });
}

function pruneOldFiles() {
  const dir = config.storage.downloadPath;
  if (!fs.existsSync(dir)) return;
  const maxMs = config.storage.maxFileAgeHours * 3600 * 1000;
  const now = Date.now();
  fs.readdirSync(dir).forEach(f => {
    const full = path.join(dir, f);
    try { if (now - fs.statSync(full).mtimeMs > maxMs) { fs.unlinkSync(full); } }
    catch {}
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles, registerSSE, unregisterSSE, sendProgress };
EOF
pass "download.service.js — filename sanitized, baseUrl validated"

# ════════════════════════════════════════════════════════════════
section "3. FIX: app.js — file serving with relaxed validation"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/app.js" << 'EOF'
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
EOF
pass "app.js — relaxed filename validation, Content-Disposition: attachment"

# ════════════════════════════════════════════════════════════════
section "4. FIX: frontend api.js — correct fileUrl + blob download"
# ════════════════════════════════════════════════════════════════
[ -n "$FRONTEND_DIR" ] && cat > "$FRONTEND_DIR/src/api.js" << 'EOF'
export const API_BASE = (
  import.meta.env.VITE_API_URL ||
  "https://grabr-production-fa32.up.railway.app"
).replace(/\/$/, "");

export function safeStr(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  try { return JSON.stringify(v); } catch { return "Unknown error"; }
}

/**
 * downloadFile — works on desktop AND mobile
 *
 * Strategy:
 * 1. Fetch file as blob (works cross-origin, respects Content-Disposition)
 * 2. Create object URL → click hidden anchor
 * 3. Fallback: window.open (browser handles download via Content-Disposition)
 *
 * On iOS Safari: step 1+2 triggers "Save to Files"
 * On Android Chrome: step 1+2 saves to Downloads
 * On Desktop: step 1+2 downloads immediately
 */
export async function downloadFile(fileUrl, filename) {
  // Ensure we use the correct backend URL (not localhost)
  let url = fileUrl;
  if (!url || url.includes("localhost") || url.includes("127.0.0.1")) {
    // Reconstruct using API_BASE
    const name = filename || url.split("/").pop();
    url = `${API_BASE}/files/${encodeURIComponent(name)}`;
  }

  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const blob    = await response.blob();
    const objUrl  = URL.createObjectURL(blob);
    const a       = document.createElement("a");
    a.href        = objUrl;
    a.download    = filename || "download";
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(objUrl); document.body.removeChild(a); }, 10000);
    return { ok: true };
  } catch (err) {
    // Fallback: open in new tab — Content-Disposition will trigger download
    window.open(url, "_blank");
    return { ok: true };
  }
}

export async function submitDownload(url, format) {
  try {
    const res = await fetch(`${API_BASE}/api/download`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, format }),
    });
    const data = await res.json();
    if (!res.ok) return { ok: false, error: safeStr(data?.error || "Request failed") };
    return { ok: true, jobId: String(data.jobId) };
  } catch (err) {
    return { ok: false, error: safeStr(err?.message || "Network error") };
  }
}

/**
 * watchJob — SSE primary, polling fallback
 * Fixes localhost URL in fileUrl before passing to onComplete
 */
export function watchJob(jobId, { onProgress, onStatus, onComplete, onError }) {
  let closed = false, es = null, pollTimer = null, retries = 0;
  const MAX_RETRIES = 3;

  function stop() {
    closed = true;
    if (es)        { try { es.close(); } catch {} es = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  // Fix localhost URLs that leak from misconfigured Railway env
  function fixUrl(rawUrl, filename) {
    if (!rawUrl) return rawUrl;
    if (rawUrl.includes("localhost") || rawUrl.includes("127.0.0.1")) {
      return `${API_BASE}/files/${encodeURIComponent(filename || rawUrl.split("/").pop())}`;
    }
    return rawUrl;
  }

  function handle(data) {
    if (closed) return;
    const status = safeStr(data.status);
    onStatus && onStatus(status);
    switch (status) {
      case "starting":
        onProgress && onProgress(0, "", "", ""); break;
      case "downloading":
        onProgress && onProgress(Number(data.percent)||0, safeStr(data.speed), safeStr(data.eta), safeStr(data.size)); break;
      case "processing":
        onProgress && onProgress(99, "", "", ""); break;
      case "completed": {
        const filename = safeStr(data.filename);
        const fileUrl  = fixUrl(safeStr(data.fileUrl), filename);
        onProgress && onProgress(100, "", "", "");
        onComplete && onComplete(filename, fileUrl, safeStr(data.mediaType || "file"));
        stop(); break;
      }
      case "error":
        onError && onError(safeStr(data.message || "Download failed"));
        stop(); break;
    }
  }

  function startPolling() {
    if (closed || pollTimer) return;
    let count = 0;
    pollTimer = setInterval(async () => {
      if (closed) return;
      count++;
      try {
        const res  = await fetch(`${API_BASE}/api/download/${jobId}`);
        const data = await res.json();
        onProgress && onProgress(Number(data.progress)||0, "", "", "");
        onStatus   && onStatus(safeStr(data.state));
        if (data.state === "completed" && data.result) {
          const filename = safeStr(data.result.filename);
          const fileUrl  = fixUrl(safeStr(data.result.downloadUrl), filename);
          onProgress && onProgress(100, "", "", "");
          onComplete && onComplete(filename, fileUrl, safeStr(data.result.mediaType||"file"));
          stop();
        } else if (data.state === "failed") {
          onError && onError(safeStr(data.error || "Download failed"));
          stop();
        }
      } catch { if (count > 72) { onError && onError("Connection lost"); stop(); } }
    }, 2500);
  }

  function openSSE() {
    if (closed) return;
    try {
      es = new EventSource(`${API_BASE}/api/download/stream/${jobId}`);
      es.onmessage = e => { retries = 0; try { handle(JSON.parse(e.data)); } catch {} };
      es.onerror = () => {
        if (closed) return;
        if (++retries >= MAX_RETRIES) { try { es.close(); } catch {} es = null; startPolling(); }
      };
    } catch { startPolling(); }
  }

  openSSE();
  return stop;
}
EOF
pass "api.js — localhost URL fix, blob download"

# ════════════════════════════════════════════════════════════════
section "5. FIX: MediaPreview.jsx — use downloadFile, handle localhost"
# ════════════════════════════════════════════════════════════════
[ -n "$FRONTEND_DIR" ] && cat > "$FRONTEND_DIR/src/MediaPreview.jsx" << 'EOF'
import { useState } from "react";
import { API_BASE, safeStr, downloadFile } from "./api";

export default function MediaPreview({ job }) {
  const [playing,  setPlaying]  = useState(false);
  const [saving,   setSaving]   = useState(false);
  const [copied,   setCopied]   = useState(false);

  if (!job || job.state !== "completed" || !job.result) return null;

  const filename  = safeStr(job.result.filename);
  const mediaType = safeStr(job.result.mediaType || "file");

  // Fix localhost URLs
  let rawUrl = safeStr(job.result.downloadUrl || "");
  if (!rawUrl || rawUrl.includes("localhost") || rawUrl.includes("127.0.0.1")) {
    rawUrl = `${API_BASE}/files/${encodeURIComponent(filename)}`;
  }
  const fileUrl = rawUrl;

  const handleSave = async () => {
    setSaving(true);
    await downloadFile(fileUrl, filename);
    setSaving(false);
  };

  const handleCopy = async () => {
    try { await navigator.clipboard.writeText(fileUrl); } catch {}
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="mpreview">

      {/* Video player */}
      {mediaType === "video" && (
        <div className="mplayer">
          {!playing ? (
            <button className="mplay-btn" onClick={() => setPlaying(true)} aria-label="Preview video">
              <div className="mplay-circle">▶</div>
              <span className="mplay-hint">Tap to preview</span>
            </button>
          ) : (
            <video
              className="mvideo"
              src={fileUrl}
              controls
              autoPlay
              playsInline
              preload="metadata"
            />
          )}
        </div>
      )}

      {/* Audio player */}
      {mediaType === "audio" && (
        <div className="maudio">
          <span className="maudio-icon">🎵</span>
          <audio src={fileUrl} controls preload="metadata" style={{ flex: 1, minWidth: 0 }} />
        </div>
      )}

      {/* Filename */}
      <p className="mfilename">
        {mediaType === "video" ? "🎬" : mediaType === "audio" ? "🎵" : "📄"}&nbsp;{filename}
      </p>

      {/* Buttons */}
      <div className="mbtns">
        <button className="mbtn mbtn-primary" onClick={handleSave} disabled={saving}>
          {saving ? "⏳ Saving…" : "⬇ Save to device"}
        </button>
        <button className="mbtn mbtn-ghost" onClick={handleCopy}>
          {copied ? "✓ Copied!" : "🔗 Copy link"}
        </button>
      </div>
    </div>
  );
}
EOF
pass "MediaPreview.jsx — localhost fix, blob download"

# ════════════════════════════════════════════════════════════════
section "6. Verify critical pieces"
# ════════════════════════════════════════════════════════════════
chk() { [ ! -f "$1" ] && { fail "MISSING: $1"; return; }; grep -q "$2" "$1" && pass "$3" || fail "$3 — missing: $2"; }

chk "$BACKEND_DIR/src/services/download.service.js" "sanitizeFilename"        "service — sanitizeFilename"
chk "$BACKEND_DIR/src/services/download.service.js" "localhost.*warn"         "service — localhost URL warning"
chk "$BACKEND_DIR/src/services/download.service.js" "renameSync"              "service — file rename to clean name"
chk "$BACKEND_DIR/src/app.js"                       "Content-Disposition"     "app.js — attachment header"
chk "$BACKEND_DIR/src/app.js"                       "sendFile"                "app.js — sendFile"
chk "$BACKEND_DIR/src/app.js"                       "filename\(\*\)"          "app.js — wildcard filename route"
[ -n "$FRONTEND_DIR" ] && {
  chk "$FRONTEND_DIR/src/api.js"           "fixUrl"            "api.js — fixUrl for localhost"
  chk "$FRONTEND_DIR/src/api.js"           "createObjectURL"   "api.js — blob download"
  chk "$FRONTEND_DIR/src/api.js"           "localhost"         "api.js — localhost detection"
  chk "$FRONTEND_DIR/src/MediaPreview.jsx" "localhost"         "MediaPreview — localhost fix"
  chk "$FRONTEND_DIR/src/MediaPreview.jsx" "downloadFile"      "MediaPreview — downloadFile"
}

# ════════════════════════════════════════════════════════════════
section "7. Git commit + push"
# ════════════════════════════════════════════════════════════════
cd "$BACKEND_DIR" || exit 1
if git rev-parse --git-dir > /dev/null 2>&1; then
  git add src/services/download.service.js src/app.js
  [ -n "$FRONTEND_DIR" ] && git add "$FRONTEND_DIR/src/api.js" "$FRONTEND_DIR/src/MediaPreview.jsx" 2>/dev/null
  if git diff --cached --quiet; then
    warn "Nothing to commit"
  else
    git commit -m "fix: sanitize filenames, fix localhost URL, relaxed file validation, blob download"
    pass "Committed"
    git push && pass "Pushed → Railway redeploys" || fail "git push failed"
  fi
else
  warn "No git repo — push manually"
fi

# ════════════════════════════════════════════════════════════════
section "8. Vercel deploy"
# ════════════════════════════════════════════════════════════════
if [ -n "$FRONTEND_DIR" ]; then
  cd "$FRONTEND_DIR" || exit 1
  [ ! -f ".env.production" ] && echo "VITE_API_URL=https://grabr-production-fa32.up.railway.app" > .env.production
  command -v vercel &>/dev/null && vercel --prod && pass "Vercel deployed" || warn "Run: cd $FRONTEND_DIR && vercel --prod"
fi

# ════════════════════════════════════════════════════════════════
section "Summary"
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${B}  MOST IMPORTANT ACTION:${N}"
echo -e "${R}  Set BASE_URL=https://grabr-production-fa32.up.railway.app in Railway Variables${N}"
echo "  (both API service AND worker service)"
echo ""
echo "  Fixes in this script:"
echo "  1. sanitizeFilename() — replaces spaces/symbols with _ before saving"
echo "  2. File renamed to clean name after download completes"
echo "  3. /files/:filename(*) — wildcard route, only blocks .."
echo "  4. Content-Disposition: attachment — forces download everywhere"
echo "  5. api.js fixUrl() — replaces localhost URLs with Railway URL"
echo "  6. downloadFile() — blob fetch + anchor click (works on mobile)"
echo "  7. MediaPreview — uses downloadFile, fixes localhost URLs"
echo ""
echo "  After deploy, test file serving:"
echo '  curl -I "https://grabr-production-fa32.up.railway.app/files/FILENAME"'
echo "  → Content-Disposition: attachment; filename=..."
echo ""
if [ $FAIL -eq 0 ]; then echo -e "${G}  ✓ All done!${N}"; else echo -e "${R}  ✗ $FAIL issue(s)${N}"; fi