#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# fix-mobile-video.sh
# Fix 1: Invalid filename — dots/spaces in names blocked by route
# Fix 2: Audio-only on mobile — wrong codec, not H.264/AAC
# Fix 3: Save to Photos on iOS/Android — needs correct MIME + share
# Fix 4: ETIMEDOUT — concurrent-fragments too high, add keepalive
# Run: bash script/fix-mobile-video.sh
# ─────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n  $1\n${C}══════════════════════════════════════════${N}"; }
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=""; dir="$SCRIPT_DIR"
for i in 1 2 3 4 5; do
  [ -f "$dir/src/app.js" ] && { BACKEND_DIR="$dir"; break; }
  dir="$(dirname "$dir")"
done
[ -z "$BACKEND_DIR" ] && [ -f "$(pwd)/src/app.js" ] && BACKEND_DIR="$(pwd)"
[ -z "$BACKEND_DIR" ] && { echo "Run from inside downloader-Api"; exit 1; }

FRONTEND_DIR=""
for name in my-downloader-frontend grabr-frontend frontend; do
  [ -d "$BACKEND_DIR/$name/src" ] && { FRONTEND_DIR="$BACKEND_DIR/$name"; break; }
done

section "0. Paths"
pass "Backend : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend: $FRONTEND_DIR"

# ════════════════════════════════════════════════════════════════
section "1. FIX app.js — file serving + Invalid filename + correct headers"
# ════════════════════════════════════════════════════════════════
# Problems:
# - express.static doesn't set Content-Disposition: attachment
# - Route middleware blocks dots and special chars in filename
# - No Content-Type for video/mp4 → mobile can't identify file
# - iOS needs video/mp4 to offer "Save to Photos"

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
EOF
pass "app.js — wildcard file route, correct MIME, Content-Disposition"

# ════════════════════════════════════════════════════════════════
section "2. FIX download.service.js — H.264/AAC codec, faststart, ETIMEDOUT fix"
# ════════════════════════════════════════════════════════════════
# Problems:
# - Audio-only on mobile = VP9/AV1 video codec that iOS/Android can't play
#   Must force H.264 (avc1) video + AAC audio for maximum compatibility
# - --concurrent-fragments 4 causes ETIMEDOUT on slow connections
# - --remux-video and --postprocessor-args must be in args array correctly
# - faststart moves moov atom to beginning → playback starts immediately

cat > "$BACKEND_DIR/src/services/download.service.js" << 'JSEOF'
const { spawn, execFile } = require("child_process");
const path   = require("path");
const fs     = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE registry ──────────────────────────────────────────────────
const sseClients = new Map();
function registerSSE(jobId, res) {
  sseClients.set(String(jobId), res);
  logger.info("SSE registered", { jobId, clients: sseClients.size });
}
function unregisterSSE(jobId) { sseClients.delete(String(jobId)); }
function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) { logger.warn("SSE write failed", { jobId }); unregisterSSE(jobId); }
}

// ── Binary resolution ─────────────────────────────────────────────
function resolveBin(envKey, candidates) {
  const v = process.env[envKey];
  if (v && fs.existsSync(v)) return v;
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return candidates[0];
}
const YTDLP_BIN  = resolveBin("YTDLP_PATH", ["/usr/local/bin/yt-dlp",  "/usr/bin/yt-dlp",  "yt-dlp"]);
const FFMPEG_BIN = resolveBin("FFMPEG_PATH", ["/usr/bin/ffmpeg",        "/usr/local/bin/ffmpeg", "ffmpeg"]);
const NODE_BIN   = process.execPath || "/usr/local/bin/node";
logger.info("Binaries", { ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN, node: NODE_BIN });

// ── Filename sanitizer ────────────────────────────────────────────
function sanitizeFilename(raw) {
  return raw.replace(/[^\w.-]+/g, "_").replace(/_+/g, "_")
            .replace(/^_+|_+$/g, "").slice(0, 180);
}

// ── Format map ────────────────────────────────────────────────────
// KEY CHANGE: force H.264 (avc1) + AAC for maximum mobile compatibility
// VP9/AV1 plays on desktop but NOT on older iOS/Android without special codecs
// Fallback chain ensures we always get a playable file
const MP4_COMPAT = [
  // H.264 video + M4A audio — plays on ALL devices
  "-f", "bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[vcodec^=avc1]+bestaudio/bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best",
  "--merge-output-format", "mp4",
  "--remux-video", "mp4",
  // faststart: move moov atom to front of file → plays immediately on mobile
  "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
];

const FORMAT_MAP = {
  mp4:   MP4_COMPAT,
  mp3:   ["-f", "bestaudio/best", "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0"],
  webm:  ["-f", "bestvideo+bestaudio/best", "--merge-output-format", "webm"],
  m4a:   ["-f", "bestaudio/best", "--extract-audio", "--audio-format", "m4a"],
  "720p":  [
    "-f", "bestvideo[vcodec^=avc1][height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best[height<=720]",
    "--merge-output-format", "mp4",
    "--remux-video", "mp4",
    "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
  ],
  "1080p": [
    "-f", "bestvideo[vcodec^=avc1][height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best[height<=1080]",
    "--merge-output-format", "mp4",
    "--remux-video", "mp4",
    "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
  ],
  "480p":  [
    "-f", "bestvideo[vcodec^=avc1][height<=480][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=480]+bestaudio/best[height<=480]",
    "--merge-output-format", "mp4",
    "--remux-video", "mp4",
    "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
  ],
  "360p":  [
    "-f", "bestvideo[vcodec^=avc1][height<=360][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=360]+bestaudio/best[height<=360]",
    "--merge-output-format", "mp4",
    "--remux-video", "mp4",
    "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
  ],
  best: MP4_COMPAT,
};

function buildArgs(url, format, outputTemplate) {
  const cookiesPaths = [
    "/app/cookies/youtube.txt",
    path.join(__dirname, "../../cookies/youtube.txt"),
  ];
  const cookiesFile = cookiesPaths.find(p => fs.existsSync(p));
  const cookiesArgs = cookiesFile ? ["--cookies", cookiesFile] : [];
  if (cookiesFile) logger.info("Using cookies", { path: cookiesFile });
  else             logger.warn("No cookies — YouTube may block");

  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist",
    "--restrict-filenames",
    `--js-runtimes`, `node:${NODE_BIN}`,
    "--max-filesize",         `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout",       "60",
    "--retries",              "5",
    "--fragment-retries",     "5",
    // Reduced from 4 → 2 to prevent ETIMEDOUT on Railway's network
    "--concurrent-fragments", "2",
    "--no-cache-dir",
    "--no-part",
    "--newline",
    "--ffmpeg-location",      FFMPEG_BIN,
    ...cookiesArgs,
    "-o",                     outputTemplate,
    url,
  ];
}

// ── Progress regexes ──────────────────────────────────────────────
// Handles all yt-dlp output formats including fragments
const RE_PROGRESS_FULL = /\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\S+)\s+at\s+([\d.]+\S+)\s+ETA\s+([\d:]+)/;
const RE_PROGRESS_DONE = /\[download\]\s+100%\s+of\s+~?\s*([\d.]+\S+)/;
const RE_FRAG          = /\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\S+).*\(frag\s+(\d+)\/(\d+)\)/;
const RE_MERGE         = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG_DEST   = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST          = /\[download\] Destination:\s+(.+)/;

// ── runDownload ───────────────────────────────────────────────────
async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(downloadDir)) {
    try { fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 }); }
    catch (e) { throw new Error(`Cannot create dir: ${e.message}`); }
  }
  try { fs.accessSync(downloadDir, fs.constants.W_OK); }
  catch { throw new Error(`No write permission: ${downloadDir}`); }

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const args = buildArgs(url, format || "best", outputTemplate);
  logger.info("Spawning yt-dlp", { jobId, bin: YTDLP_BIN, dir: downloadDir, format });

  // emit: ALWAYS sends objects, never plain numbers
  // Pushes to both SSE stream AND BullMQ via onProgress callback
  const emit = (data) => {
    sendProgress(String(jobId), data);
    if (onProgress) {
      const pct = typeof data === "object" ? (data.percent || 0) : Number(data) || 0;
      try { onProgress(data, pct); } catch {}
    }
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

        // Phase: merging / ffmpeg post-processing
        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          emit({ status: "processing", percent: 99 });
        }

        // Capture output path
        const mM = line.match(RE_MERGE);
        const fM = line.match(RE_FFMPEG_DEST);
        const dM = line.match(RE_DEST);
        if (mM) outputPath = mM[1].trim();
        else if (fM) outputPath = fM[1].trim();
        else if (dM && !outputPath) outputPath = dM[1].trim();

        // Parse progress — try all three formats
        let percent = null, size = "", speed = "", eta = "";
        const fullM = line.match(RE_PROGRESS_FULL);
        const fragM = line.match(RE_FRAG);
        const doneM = line.match(RE_PROGRESS_DONE);

        if (fullM) {
          percent = parseFloat(fullM[1]); size = fullM[2]; speed = fullM[3]; eta = fullM[4];
        } else if (fragM) {
          percent = Math.round((parseInt(fragM[3]) / parseInt(fragM[4])) * 100);
          size = fragM[2];
        } else if (doneM) {
          percent = 100; size = doneM[1]; eta = "0:00";
        }

        if (percent !== null && (percent - lastPct >= 1 || percent >= 100)) {
          lastPct = percent;
          emit({ status: "downloading", percent: Math.min(percent, 98), size, speed, eta });
        }
      }
    });

    child.stderr.on("data", chunk => {
      const text = chunk.toString();
      stderrBuf += text;
      text.split("\n").forEach(l => { if (l.trim()) logger.debug("yt-dlp stderr", { jobId, line: l.trim() }); });
    });

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
          emit({ status: "error", message: "Output file not found after download" });
          return reject(new Error("Output file not found"));
        }
        outputPath = path.join(downloadDir, files[0].name);
      }

      // Sanitize filename
      const rawName   = path.basename(outputPath);
      const ext       = path.extname(rawName);
      const cleanName = sanitizeFilename(path.basename(rawName, ext)) + ext;
      const cleanPath = path.join(downloadDir, cleanName);
      if (rawName !== cleanName && !fs.existsSync(cleanPath)) {
        try { fs.renameSync(outputPath, cleanPath); outputPath = cleanPath; } catch {}
      }

      const filename  = path.basename(outputPath);
      const fileUrl   = `${config.baseUrl.replace(/\/$/, "")}/files/${encodeURIComponent(filename)}`;
      const mediaType = [".mp4",".webm",".mkv",".mov"].includes(ext.toLowerCase()) ? "video"
                      : [".mp3",".m4a",".ogg",".wav",".opus"].includes(ext.toLowerCase()) ? "audio"
                      : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });
      logger.info("Complete", { jobId, filename, fileUrl, elapsed: `${elapsed}s` });
      resolve({ filePath: outputPath, filename, fileUrl, mediaType });
    });

    child.on("error", err => { emit({ status: "error", message: err.message }); reject(err); });
  });
}

async function getMetadata(url) {
  return new Promise((resolve, reject) => {
    execFile(YTDLP_BIN,
      ["--dump-json", "--no-playlist", `--js-runtimes`, `node:${NODE_BIN}`, url],
      { timeout: 30_000 },
      (err, stdout) => {
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
    try { if (now - fs.statSync(full).mtimeMs > maxMs) fs.unlinkSync(full); } catch {}
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles, registerSSE, unregisterSSE, sendProgress };
JSEOF
pass "download.service.js — H.264/AAC codec, faststart, ETIMEDOUT fix, multi-regex"

# ════════════════════════════════════════════════════════════════
section "3. FIX frontend — MediaPreview + mobile save to Photos"
# ════════════════════════════════════════════════════════════════
# iOS "Save to Photos": requires video/mp4 MIME + user must long-press
# Android: downloads to gallery if MIME is video/mp4
# The Web Share API lets us share directly to Photos/Gallery on mobile

[ -n "$FRONTEND_DIR" ] && cat > "$FRONTEND_DIR/src/MediaPreview.jsx" << 'EOF'
import { useState } from "react";
import { API_BASE, safeStr, downloadFile } from "./api";

export default function MediaPreview({ job }) {
  const [playing,  setPlaying]  = useState(false);
  const [saving,   setSaving]   = useState(false);
  const [copied,   setCopied]   = useState(false);
  const [shareErr, setShareErr] = useState("");

  if (!job || job.state !== "completed" || !job.result) return null;

  const filename  = safeStr(job.result.filename);
  const mediaType = safeStr(job.result.mediaType || "file");

  // Fix localhost URLs that leak from misconfigured env
  let rawUrl = safeStr(job.result.downloadUrl || "");
  if (!rawUrl || rawUrl.includes("localhost") || rawUrl.includes("127.0.0.1")) {
    rawUrl = `${API_BASE}/files/${encodeURIComponent(filename)}`;
  }
  const fileUrl = rawUrl;

  const isVideo = mediaType === "video";
  const isAudio = mediaType === "audio";

  // ── Save to device ─────────────────────────────────────────────
  // On iOS: triggers "Save to Photos" when MIME is video/mp4
  // On Android: saves to Downloads/Gallery
  // Desktop: direct download
  const handleSave = async () => {
    setSaving(true);
    setShareErr("");

    // Try Web Share API first (iOS 15+ / Android Chrome)
    // This gives "Save to Photos" option on iOS
    if (navigator.canShare) {
      try {
        const response = await fetch(fileUrl);
        const blob     = await response.blob();
        const file     = new File([blob], filename, { type: blob.type });
        if (navigator.canShare({ files: [file] })) {
          await navigator.share({ files: [file], title: filename });
          setSaving(false);
          return;
        }
      } catch (e) {
        // Share cancelled or not supported — fall through to blob download
      }
    }

    // Blob download fallback — works on all platforms
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
      {isVideo && (
        <div className="mplayer">
          {!playing ? (
            <button className="mplay-btn" onClick={() => setPlaying(true)}>
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
      {isAudio && (
        <div className="maudio">
          <span className="maudio-icon">🎵</span>
          <audio src={fileUrl} controls preload="metadata" style={{ flex: 1, minWidth: 0 }} />
        </div>
      )}

      <p className="mfilename">
        {isVideo ? "🎬" : isAudio ? "🎵" : "📄"}&nbsp;{filename}
      </p>

      {shareErr && <p className="mshare-err">{shareErr}</p>}

      <div className="mbtns">
        <button className="mbtn mbtn-primary" onClick={handleSave} disabled={saving}>
          {saving ? "⏳ Saving…" : isVideo ? "⬇ Save to Photos" : "⬇ Save file"}
        </button>
        <button className="mbtn mbtn-ghost" onClick={handleCopy}>
          {copied ? "✓ Copied!" : "🔗 Link"}
        </button>
      </div>

      {/* iOS hint */}
      {isVideo && (
        <p className="mhint">
          iOS: tap "Save to Photos" when prompted · Android: check Gallery/Downloads
        </p>
      )}
    </div>
  );
}
EOF
pass "MediaPreview.jsx — Web Share API for Save to Photos, blob fallback"

# ════════════════════════════════════════════════════════════════
section "4. Add hint CSS"
# ════════════════════════════════════════════════════════════════
APPCSS="$FRONTEND_DIR/src/App.css"
if [ -n "$FRONTEND_DIR" ] && [ -f "$APPCSS" ]; then
  if ! grep -q "mhint" "$APPCSS"; then
    cat >> "$APPCSS" << 'CSSEOF'

.mhint{font-size:0.65rem;color:var(--txt3);text-align:center;padding:0 0.25rem;line-height:1.4}
.mshare-err{font-size:0.7rem;color:var(--warn);text-align:center}
CSSEOF
    pass "App.css — hint styles added"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "5. Verify"
# ════════════════════════════════════════════════════════════════
grep -q "avc1" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service — H.264 (avc1) codec forced" \
  || fail "service — avc1 codec missing"

grep -q "faststart" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service — faststart flag present" \
  || fail "service — faststart missing"

grep -q "concurrent-fragments.*2" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service — concurrent-fragments reduced to 2 (ETIMEDOUT fix)" \
  || fail "service — concurrent-fragments not fixed"

grep -q "filename\(\*\)" "$BACKEND_DIR/src/app.js" \
  && pass "app.js — wildcard filename route" \
  || fail "app.js — wildcard route missing"

grep -q "sendFile" "$BACKEND_DIR/src/app.js" \
  && pass "app.js — sendFile used" \
  || fail "app.js — express.static still used (needs sendFile)"

[ -n "$FRONTEND_DIR" ] && grep -q "canShare" "$FRONTEND_DIR/src/MediaPreview.jsx" \
  && pass "MediaPreview — Web Share API (Save to Photos)" \
  || fail "MediaPreview — Web Share API missing"

# ════════════════════════════════════════════════════════════════
section "6. Git commit and push"
# ════════════════════════════════════════════════════════════════
GIT_ROOT=""
dir="$BACKEND_DIR"
for i in 1 2 3 4 5; do
  [ -d "$dir/.git" ] && { GIT_ROOT="$dir"; break; }
  dir="$(dirname "$dir")"
done

if [ -n "$GIT_ROOT" ]; then
  cd "$GIT_ROOT" || exit 1
  git config user.email "deploy@grabr.app" 2>/dev/null || true
  git config user.name  "Grabr Deploy"    2>/dev/null || true
  git add \
    "$BACKEND_DIR/src/app.js" \
    "$BACKEND_DIR/src/services/download.service.js"
  [ -n "$FRONTEND_DIR" ] && git add \
    "$FRONTEND_DIR/src/MediaPreview.jsx" \
    "$FRONTEND_DIR/src/App.css" 2>/dev/null
  if git diff --cached --quiet; then
    git commit --allow-empty -m "fix: mobile video codec, faststart, ETIMEDOUT, Save to Photos"
  else
    git commit -m "fix: H.264/AAC codec, faststart, ETIMEDOUT, wildcard route, Save to Photos"
  fi
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  git push origin "$BRANCH" \
    && pass "Pushed → Railway redeploys" \
    || { git push --set-upstream origin "$BRANCH" && pass "Pushed"; }
fi

# ════════════════════════════════════════════════════════════════
section "7. Vercel deploy"
# ════════════════════════════════════════════════════════════════
if [ -n "$FRONTEND_DIR" ]; then
  cd "$FRONTEND_DIR" || exit 1
  [ ! -f ".env.production" ] && echo "VITE_API_URL=https://grabr-production-fa32.up.railway.app" > .env.production
  if command -v vercel &>/dev/null; then
    vercel whoami &>/dev/null 2>&1 || vercel login
    vercel --prod --yes && pass "Vercel deployed" || warn "Run: vercel --prod"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "Summary"
# ════════════════════════════════════════════════════════════════
echo ""
echo "  Fixes applied:"
echo ""
echo "  1. INVALID FILENAME → wildcard route /files/:filename(*)"
echo "     Only blocks '..' — dots, dashes, spaces all allowed"
echo ""
echo "  2. AUDIO-ONLY on mobile → forced H.264 (avc1) + AAC codec"
echo "     iOS/Android can't play VP9/AV1 without special decoders"
echo "     Format: bestvideo[vcodec^=avc1]+bestaudio → remux → mp4"
echo "     Fallback chain ensures we always get a playable file"
echo ""
echo "  3. SAVE TO PHOTOS on iOS/Android:"
echo "     → Web Share API: navigator.share({files:[...]}) triggers"
echo "       native share sheet with 'Save to Photos' option on iOS 15+"
echo "     → Android Chrome: downloads to Gallery automatically"
echo "     → Blob fallback for browsers without Share API"
echo ""
echo "  4. ETIMEDOUT → concurrent-fragments reduced from 4 → 2"
echo "     Railway's outbound connections throttle at high concurrency"
echo ""
echo "  5. FASTSTART → -movflags faststart moves moov atom to file start"
echo "     Video starts playing immediately on mobile without full download"
echo ""
if [ $FAIL -eq 0 ]; then echo -e "${G}  ✓ All done!${N}"; else echo -e "${R}  ✗ $FAIL issue(s)${N}"; fi