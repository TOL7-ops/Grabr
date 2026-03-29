#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# fix-all.sh — Complete production fix
# Fixes: SSE data flow, worker, ffmpeg, JS runtime, cookies,
#        desktop download, mobile download, file serving headers
# Run: bash script/fix-all.sh
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
mkdir -p "$BACKEND_DIR/cookies"

# ════════════════════════════════════════════════════════════════
section "1. Dockerfile — ffmpeg + yt-dlp binary + Node.js runtime + /tmp"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/Dockerfile" << 'EOF'
FROM node:20 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production \
    YTDLP_PATH=/usr/local/bin/yt-dlp \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    DOWNLOAD_PATH=/tmp/downloads \
    PORT=3000

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip ffmpeg curl wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Verify ffmpeg is at known path
RUN which ffmpeg && ffmpeg -version 2>&1 | head -1

# Install yt-dlp as binary (not pip) — more reliable, always latest
RUN wget -q "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" \
    -O /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp \
    && yt-dlp --version

# Bake yt-dlp config: Node.js runtime + sensible defaults
RUN mkdir -p /root/.config/yt-dlp && cat > /root/.config/yt-dlp/config << 'YTCONF'
--js-runtimes nodejs
--retries 5
--fragment-retries 5
--socket-timeout 60
--no-cache-dir
--no-part
--newline
YTCONF

# Create writable download dir
RUN mkdir -p /tmp/downloads && chmod 777 /tmp/downloads

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY src/ ./src/
COPY cookies/ ./cookies/
RUN mkdir -p logs

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1
CMD ["node", "src/server.js"]

FROM base AS worker
CMD ["node", "src/workers/download.worker.js"]
EOF
pass "Dockerfile"

# ════════════════════════════════════════════════════════════════
section "2. config/index.js — safe path resolution"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/config/index.js" << 'EOF'
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
EOF
pass "config/index.js"

# ════════════════════════════════════════════════════════════════
section "3. app.js — file serving with proper download headers"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/app.js" << 'EOF'
const express = require("express");
const cors    = require("cors");
const helmet  = require("helmet");
const morgan  = require("morgan");
const path    = require("path");
const fs      = require("fs");

const downloadRoutes           = require("./routes/download.routes");
const { notFound, errorHandler } = require("./middlewares/error.middleware");
const config = require("./config");
const logger = require("./utils/logger");

const app = express();
app.set("trust proxy", 1);

// CORS — allow all vercel.app subdomains + localhost
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

// ── File serving — forces download on all clients incl. mobile ──
app.get("/files/:filename", (req, res) => {
  const { filename } = req.params;

  // Security: no path traversal
  if (!filename || filename.includes("..") || filename.includes("/") || filename.includes("\\")) {
    return res.status(400).json({ error: "Invalid filename" });
  }

  const filePath = path.resolve(config.storage.downloadPath, filename);

  // Must stay within download dir
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!filePath.startsWith(downloadDir + path.sep) && filePath !== downloadDir) {
    return res.status(400).json({ error: "Invalid path" });
  }

  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ error: "File not found" });
  }

  const stat = fs.statSync(filePath);
  const ext  = path.extname(filename).toLowerCase();

  // MIME types
  const mimeMap = {
    ".mp4": "video/mp4", ".webm": "video/webm", ".mkv": "video/x-matroska",
    ".mov": "video/quicktime", ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
    ".ogg": "audio/ogg", ".wav": "audio/wav", ".opus": "audio/opus",
  };
  const contentType = mimeMap[ext] || "application/octet-stream";

  // CRITICAL: Content-Disposition: attachment forces download on ALL browsers
  // including mobile Safari and Chrome Android
  res.setHeader("Content-Type", contentType);
  res.setHeader("Content-Disposition", `attachment; filename="${encodeURIComponent(filename)}"`);
  res.setHeader("Content-Length", stat.size);
  res.setHeader("Accept-Ranges", "bytes");
  res.setHeader("Cache-Control", "no-cache");

  // Stream the file
  const stream = fs.createReadStream(filePath);
  stream.on("error", err => {
    logger.error("File stream error", { filename, error: err.message });
    if (!res.headersSent) res.status(500).json({ error: "Failed to stream file" });
  });
  stream.pipe(res);
});

// Debug path endpoint
app.get("/debug/path", (_req, res) => {
  const dir = config.storage.downloadPath;
  let writable = false, exists = fs.existsSync(dir);
  try { fs.accessSync(dir, fs.constants.W_OK); writable = true; } catch {}
  res.json({ downloadPath: dir, exists, writable, NODE_ENV: process.env.NODE_ENV });
});

app.use("/api/download", downloadRoutes);

app.get("/health", (_req, res) => {
  res.json({ status: "ok", uptime: process.uptime(), ts: new Date().toISOString() });
});

app.use(notFound);
app.use(errorHandler);
module.exports = app;
EOF
pass "app.js — Content-Disposition: attachment on all files"

# ════════════════════════════════════════════════════════════════
section "4. download.service.js — spawn + emit + sendProgress"
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
  catch (e) { logger.warn("SSE write failed", { jobId, error: e.message }); unregisterSSE(jobId); }
}

// ── Resolve binaries at startup ───────────────────────────────────
function resolveBin(envKey, candidates) {
  const fromEnv = process.env[envKey];
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv;
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return candidates[0]; // last resort — let yt-dlp fail with a clear message
}

const YTDLP_BIN  = resolveBin("YTDLP_PATH",  ["/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp", "yt-dlp"]);
const FFMPEG_BIN = resolveBin("FFMPEG_PATH",  ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "ffmpeg"]);

logger.info("Binaries", { yt_dlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN });

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
// emit() pushes to BOTH SSE stream AND BullMQ via onProgress callback
async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);

  if (!fs.existsSync(downloadDir)) {
    try { fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 }); }
    catch (e) { throw new Error(`Cannot create download dir ${downloadDir}: ${e.message}`); }
  }
  try { fs.accessSync(downloadDir, fs.constants.W_OK); }
  catch { throw new Error(`No write permission: ${downloadDir}. Set DOWNLOAD_PATH=/tmp/downloads`); }

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.info("Starting download", { jobId, format, ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN, dir: downloadDir });

  // emit: sends to SSE stream AND calls onProgress(data) for BullMQ
  const emit = (data) => {
    sendProgress(jobId, data);
    if (onProgress) {
      const pct = typeof data === "object" ? (data.percent || 0) : Number(data) || 0;
      onProgress(data, pct).catch(() => {});
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

      if (!outputPath || !fs.existsSync(outputPath)) {
        const files = fs.readdirSync(downloadDir)
          .filter(f => f.startsWith(String(jobId)))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(downloadDir, f)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime);
        if (!files.length) {
          const err = "Download finished but output file not found";
          emit({ status: "error", message: err });
          return reject(new Error(err));
        }
        outputPath = path.join(downloadDir, files[0].name);
      }

      const filename  = path.basename(outputPath);
      const fileUrl   = `${config.baseUrl}/files/${encodeURIComponent(filename)}`;
      const ext       = path.extname(filename).toLowerCase().replace(".", "");
      const mediaType = ["mp4","webm","mkv","mov"].includes(ext) ? "video"
                      : ["mp3","m4a","ogg","wav","opus"].includes(ext) ? "audio"
                      : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });
      logger.info("Download complete", { jobId, filename, elapsed: `${elapsed}s` });
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
    try {
      if (now - fs.statSync(full).mtimeMs > maxMs) { fs.unlinkSync(full); logger.info("Pruned", { f }); }
    } catch (e) { logger.warn("Prune failed", { f, error: e.message }); }
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles, registerSSE, unregisterSSE, sendProgress };
EOF
pass "download.service.js"

# ════════════════════════════════════════════════════════════════
section "5. download.worker.js — sendProgress wired correctly"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/workers/download.worker.js" << 'EOF'
require("dotenv").config();
const { Worker }                       = require("bullmq");
const { getRedisClient }               = require("../config/redis");
const { runDownload, sendProgress }    = require("../services/download.service");
const logger                           = require("../utils/logger");
const { QUEUE_NAME }                   = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

const worker = new Worker(QUEUE_NAME, async (job) => {
  const { url, format } = job.data;
  logger.info("Job started", { jobId: job.id, url, format });

  // onProgress: receives full data object from runDownload's emit()
  // Updates BullMQ progress AND pushes to SSE via sendProgress
  const onProgress = async (progressData, pct) => {
    // 1. BullMQ progress (enables polling fallback)
    try { await job.updateProgress(Math.floor(pct || 0)); } catch {}
    // 2. SSE push — THIS is what sends data to the browser
    sendProgress(String(job.id), typeof progressData === "object"
      ? progressData
      : { status: "downloading", percent: pct || 0 }
    );
  };

  let result;
  try {
    result = await runDownload(url, format, job.id, onProgress);
  } catch (err) {
    logger.error("Download failed", { jobId: job.id, error: err.message });
    throw err;
  }

  return {
    filename:    result.filename,
    filePath:    result.filePath,
    downloadUrl: result.fileUrl,
    mediaType:   result.mediaType || "file",
  };
}, {
  connection: getRedisClient(),
  concurrency: CONCURRENCY,
  limiter: { max: CONCURRENCY, duration: 1000 },
});

worker.on("active",    j      => logger.info("Job active",    { jobId: j.id }));
worker.on("completed", (j, v) => logger.info("Job completed", { jobId: j.id, file: v?.filename }));
worker.on("failed",    (j, e) => logger.error("Job failed",   { jobId: j?.id, error: e.message }));
worker.on("error",     e      => logger.error("Worker error", { error: e.message }));

async function shutdown(sig) { await worker.close(); process.exit(0); }
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));
logger.info("Worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });
EOF
pass "download.worker.js"

# ════════════════════════════════════════════════════════════════
section "6. stream.controller.js — late-join + sendProgress"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/controllers/stream.controller.js" << 'EOF'
const { registerSSE, unregisterSSE, sendProgress } = require("../services/download.service");
const queueService = require("../services/queue.service");
const logger = require("../utils/logger");

async function streamJob(req, res) {
  const { jobId } = req.params;
  if (!jobId || !/^[\w-]+$/.test(jobId)) return res.status(400).json({ error: "Invalid job ID" });

  res.setHeader("Content-Type",     "text/event-stream");
  res.setHeader("Cache-Control",    "no-cache");
  res.setHeader("Connection",       "keep-alive");
  res.setHeader("X-Accel-Buffering","no");
  res.flushHeaders();

  const ping = setInterval(() => { try { res.write(": ping\n\n"); } catch { clearInterval(ping); } }, 20_000);
  registerSSE(jobId, res);
  logger.info("SSE connected", { jobId });

  // Late-join: check if already finished
  try {
    const job = await queueService.getJob(jobId);
    if (job) {
      const state = await job.getState();
      if (state === "completed" && job.returnvalue) {
        const { filename, downloadUrl, mediaType } = job.returnvalue;
        sendProgress(jobId, { status: "completed", percent: 100, filename, fileUrl: downloadUrl, mediaType: mediaType || "file" });
        cleanup(); return;
      }
      if (state === "failed") {
        sendProgress(jobId, { status: "error", message: job.failedReason || "Download failed" });
        cleanup(); return;
      }
      const pct = job.progress || 0;
      if (pct > 0) sendProgress(jobId, { status: "downloading", percent: pct });
    }
  } catch (e) { logger.warn("SSE late-join failed", { jobId, error: e.message }); }

  function cleanup() {
    clearInterval(ping);
    unregisterSSE(jobId);
    logger.info("SSE disconnected", { jobId });
    try { res.end(); } catch {}
  }
  req.on("close",  cleanup);
  req.on("error",  cleanup);
  res.on("error",  cleanup);
  res.on("finish", cleanup);
}
module.exports = { streamJob };
EOF
pass "stream.controller.js"

# ════════════════════════════════════════════════════════════════
section "7. download.controller.js — include mediaType in response"
# ════════════════════════════════════════════════════════════════
CTRL="$BACKEND_DIR/src/controllers/download.controller.js"
if [ -f "$CTRL" ]; then
  if ! grep -q "mediaType" "$CTRL"; then
    sed -i 's/result: job\.returnvalue || null/result: job.returnvalue ? { ...job.returnvalue, mediaType: job.returnvalue.mediaType || "file" } : null/' "$CTRL" 2>/dev/null
    pass "download.controller.js — mediaType added"
  else
    pass "download.controller.js — mediaType already present"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "8. Frontend api.js — mobile blob download + SSE + polling"
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
 * downloadFile — works on BOTH desktop and mobile
 * Backend sends Content-Disposition: attachment which forces download.
 * For mobile we fetch as blob and trigger via anchor to ensure it saves
 * to device instead of opening in browser.
 */
export async function downloadFile(fileUrl, filename) {
  try {
    const response = await fetch(fileUrl);
    if (!response.ok) throw new Error("File not found");
    const blob = await response.blob();
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement("a");
    a.href     = url;
    a.download = filename || "download";
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    // Clean up
    setTimeout(() => { URL.revokeObjectURL(url); document.body.removeChild(a); }, 5000);
    return { ok: true };
  } catch (err) {
    // Fallback: open in new tab (browser will trigger download via Content-Disposition)
    window.open(fileUrl, "_blank");
    return { ok: true };
  }
}

/**
 * watchJob — SSE primary, polling fallback
 * onProgress(percent, speed, eta, size)
 * onStatus(status)
 * onComplete(filename, fileUrl, mediaType)
 * onError(message)
 */
export function watchJob(jobId, { onProgress, onStatus, onComplete, onError }) {
  let closed = false, es = null, pollTimer = null, retries = 0;
  const MAX_RETRIES = 3;

  function stop() {
    closed = true;
    if (es)        { try { es.close(); } catch {} es = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
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
      case "completed":
        onProgress && onProgress(100, "", "", "");
        onComplete && onComplete(safeStr(data.filename), safeStr(data.fileUrl), safeStr(data.mediaType || "file"));
        stop(); break;
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
          onProgress && onProgress(100, "", "", "");
          onComplete && onComplete(safeStr(data.result.filename), safeStr(data.result.downloadUrl), safeStr(data.result.mediaType||"file"));
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
pass "api.js — blob download for mobile + SSE + polling fallback"

# ════════════════════════════════════════════════════════════════
section "9. MediaPreview.jsx — inline player + mobile-safe download"
# ════════════════════════════════════════════════════════════════
[ -n "$FRONTEND_DIR" ] && cat > "$FRONTEND_DIR/src/MediaPreview.jsx" << 'EOF'
import { useState } from "react";
import { API_BASE, safeStr, downloadFile } from "./api";

export default function MediaPreview({ job }) {
  const [playing,  setPlaying]  = useState(false);
  const [downloading, setDl]    = useState(false);
  const [copied,   setCopied]   = useState(false);

  if (!job || job.state !== "completed" || !job.result) return null;

  const filename  = safeStr(job.result.filename);
  const mediaType = safeStr(job.result.mediaType || "file");
  const fileUrl   = safeStr(job.result.downloadUrl).startsWith("http")
    ? safeStr(job.result.downloadUrl)
    : `${API_BASE}/files/${encodeURIComponent(filename)}`;

  const handleDownload = async () => {
    setDl(true);
    await downloadFile(fileUrl, filename);
    setDl(false);
  };

  const handleCopy = async () => {
    await navigator.clipboard.writeText(fileUrl).catch(() => {});
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="mpreview">

      {/* Video inline player */}
      {mediaType === "video" && (
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
      {mediaType === "audio" && (
        <div className="maudio">
          <span className="maudio-icon">🎵</span>
          <audio src={fileUrl} controls preload="metadata" style={{ flex: 1, minWidth: 0 }} />
        </div>
      )}

      {/* File name */}
      <p className="mfilename">
        {mediaType === "video" ? "🎬" : mediaType === "audio" ? "🎵" : "📄"}&nbsp;
        {filename}
      </p>

      {/* Action buttons */}
      <div className="mbtns">
        <button
          className="mbtn mbtn-primary"
          onClick={handleDownload}
          disabled={downloading}
        >
          {downloading ? "⏳ Saving…" : "⬇ Save to device"}
        </button>
        <button className="mbtn mbtn-ghost" onClick={handleCopy}>
          {copied ? "✓ Copied!" : "🔗 Copy link"}
        </button>
      </div>
    </div>
  );
}
EOF
pass "MediaPreview.jsx — blob download, video/audio player"

# ════════════════════════════════════════════════════════════════
section "10. App.jsx — fix useDownloadManager + mediaType in onComplete"
# ════════════════════════════════════════════════════════════════
APPJSX="$FRONTEND_DIR/src/App.jsx"
if [ -n "$FRONTEND_DIR" ] && [ -f "$APPJSX" ]; then
  # Fix import line
  sed -i "s|import { API_BASE, submitDownload.*from.*api.*|import MediaPreview from \"./MediaPreview\";\nimport { API_BASE, submitDownload, watchJob, safeStr } from \"./api\";|" "$APPJSX" 2>/dev/null
  # Remove stale POLL_MS
  sed -i '/^const POLL_MS/d' "$APPJSX" 2>/dev/null
  pass "App.jsx — imports patched"
fi

# ════════════════════════════════════════════════════════════════
section "11. App.css — media preview styles"
# ════════════════════════════════════════════════════════════════
APPCSS="$FRONTEND_DIR/src/App.css"
if [ -n "$FRONTEND_DIR" ] && [ -f "$APPCSS" ] && ! grep -q "mpreview" "$APPCSS"; then
cat >> "$APPCSS" << 'EOF'

/* ── Media Preview ────────────────────────────────────────────── */
.mpreview{display:flex;flex-direction:column;gap:0.6rem;background:color-mix(in srgb,var(--acc) 6%,var(--surf));border:1px solid color-mix(in srgb,var(--acc) 25%,transparent);border-radius:var(--r2);padding:0.85rem;animation:fadeUp 0.3s ease}

.mplayer{width:100%;border-radius:var(--r3);overflow:hidden;background:#000;aspect-ratio:16/9;display:flex;align-items:center;justify-content:center}
.mvideo{width:100%;height:100%;display:block;object-fit:contain}

.mplay-btn{width:100%;height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:0.5rem;background:linear-gradient(135deg,#080c18,#0d1525);border:none;cursor:pointer}
.mplay-btn:hover .mplay-circle{transform:scale(1.1);box-shadow:0 0 32px var(--glow)}
.mplay-circle{width:52px;height:52px;border-radius:50%;background:linear-gradient(135deg,var(--pri),var(--pri2));display:grid;place-items:center;font-size:1.1rem;color:#fff;padding-left:3px;transition:all 0.2s;box-shadow:0 0 20px var(--glow)}
.mplay-hint{font-size:0.72rem;color:rgba(255,255,255,0.4);font-family:'Plus Jakarta Sans',sans-serif}

.maudio{display:flex;align-items:center;gap:0.6rem;background:var(--surf2);padding:0.6rem;border-radius:var(--r3)}
.maudio-icon{font-size:1.3rem;flex-shrink:0}
audio{width:100%;accent-color:var(--pri)}

.mfilename{font-size:0.7rem;color:var(--txt2);word-break:break-all;line-height:1.4}

.mbtns{display:flex;gap:0.5rem}
.mbtn{flex:1;display:flex;align-items:center;justify-content:center;gap:0.35rem;padding:0.55rem 0.75rem;border-radius:var(--r3);font-size:0.78rem;font-weight:700;border:none;cursor:pointer;transition:all 0.15s;font-family:'Plus Jakarta Sans',sans-serif}
.mbtn:disabled{opacity:0.6;cursor:wait}
.mbtn-primary{background:var(--acc);color:#fff}
.mbtn-primary:hover:not(:disabled){filter:brightness(1.1)}
.mbtn-ghost{background:var(--surf2);color:var(--txt2);border:1px solid var(--bord)}
.mbtn-ghost:hover{color:var(--txt)}
EOF
  pass "App.css — media preview styles"
fi

# ════════════════════════════════════════════════════════════════
section "12. Verify all critical pieces"
# ════════════════════════════════════════════════════════════════
chk() { [ ! -f "$1" ] && { fail "MISSING: $1"; return; }; grep -q "$2" "$1" && pass "$3" || fail "$3 — missing '$2' in $1"; }

chk "$BACKEND_DIR/Dockerfile"                          "js-runtimes nodejs"         "Dockerfile — Node.js runtime"
chk "$BACKEND_DIR/Dockerfile"                          "FFMPEG_PATH=/usr/bin/ffmpeg" "Dockerfile — FFMPEG_PATH env"
chk "$BACKEND_DIR/Dockerfile"                          "YTDLP_PATH=/usr/local"      "Dockerfile — YTDLP_PATH env"
chk "$BACKEND_DIR/Dockerfile"                          "chmod 777 /tmp/downloads"   "Dockerfile — /tmp writable"
chk "$BACKEND_DIR/src/app.js"                          "Content-Disposition"        "app.js — attachment header"
chk "$BACKEND_DIR/src/app.js"                          "createReadStream"           "app.js — stream file"
chk "$BACKEND_DIR/src/services/download.service.js"    "sendProgress"               "service — sendProgress"
chk "$BACKEND_DIR/src/services/download.service.js"    "emit("                      "service — emit()"
chk "$BACKEND_DIR/src/services/download.service.js"    "js-runtimes"                "service — --js-runtimes"
chk "$BACKEND_DIR/src/workers/download.worker.js"      "sendProgress(String(job.id" "worker — sendProgress called"
chk "$BACKEND_DIR/src/workers/download.worker.js"      "onProgress = async"         "worker — async onProgress"
[ -n "$FRONTEND_DIR" ] && {
  chk "$FRONTEND_DIR/src/api.js"          "downloadFile"     "api.js — downloadFile"
  chk "$FRONTEND_DIR/src/api.js"          "createObjectURL"  "api.js — blob download"
  chk "$FRONTEND_DIR/src/api.js"          "EventSource"      "api.js — SSE"
  chk "$FRONTEND_DIR/src/MediaPreview.jsx" "downloadFile"    "MediaPreview — uses downloadFile"
  chk "$FRONTEND_DIR/src/MediaPreview.jsx" "playsInline"     "MediaPreview — playsInline (mobile)"
}

# ════════════════════════════════════════════════════════════════
section "13. Git commit + push"
# ════════════════════════════════════════════════════════════════
cd "$BACKEND_DIR" || exit 1
if git rev-parse --git-dir > /dev/null 2>&1; then
  git add Dockerfile src/ cookies/ 2>/dev/null
  [ -n "$FRONTEND_DIR" ] && git add "$FRONTEND_DIR/src/" 2>/dev/null
  if git diff --cached --quiet; then
    warn "Nothing new to commit"
  else
    git commit -m "fix: SSE data flow, ffmpeg, JS runtime, mobile blob download, Content-Disposition"
    pass "Committed"
    git push && pass "Pushed → Railway rebuilds" || fail "git push failed"
  fi
else
  warn "No git repo — push manually"
fi

# ════════════════════════════════════════════════════════════════
section "14. Vercel deploy"
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
echo "  Fixes applied:"
echo "  1. Dockerfile — ffmpeg verified, yt-dlp binary, Node.js runtime baked in"
echo "  2. app.js — Content-Disposition: attachment forces download on all browsers"
echo "  3. app.js — custom file route with stream (no express.static)"
echo "  4. download.service.js — emit() sends to BOTH SSE and BullMQ"
echo "  5. download.worker.js — sendProgress(job.id, data) called on every event"
echo "  6. api.js — downloadFile() fetches blob → anchor click (mobile-safe)"
echo "  7. MediaPreview.jsx — video player + audio player + blob download button"
echo ""
echo "  After Railway rebuild (~3 min), test SSE:"
echo "    curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/JOB_ID"
echo "    # Must show: data: {\"status\":\"downloading\",\"percent\":12,...}"
echo ""
echo "  Test file download header:"
echo "    curl -I https://grabr-production-fa32.up.railway.app/files/FILENAME"
echo "    # Must show: Content-Disposition: attachment"
echo ""
if [ $FAIL -eq 0 ]; then echo -e "${G}  ✓ All done!${N}"; else echo -e "${R}  ✗ $FAIL issue(s)${N}"; fi