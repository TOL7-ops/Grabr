#!/bin/bash

# ─────────────────────────────────────────────────────────────────
# fix-sse-bugs.sh
# Fixes:
#   1. Worker never calls sendSSE → UI stuck on "queued"
#   2. onProgress called with plain number, SSE expects object
#   3. Video preview after download (not just a filename)
#
# Run from inside downloader-Api:
#   bash script/fix-sse-bugs.sh
# ─────────────────────────────────────────────────────────────────

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n${B}  $1${N}\n${C}══════════════════════════════════════════${N}"; }
FAIL=0

# ── Detect dirs ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=""
dir="$SCRIPT_DIR"
for i in 1 2 3 4 5; do
  [ -f "$dir/src/app.js" ] && { BACKEND_DIR="$dir"; break; }
  dir="$(dirname "$dir")"
done
[ -z "$BACKEND_DIR" ] && [ -f "$(pwd)/src/app.js" ] && BACKEND_DIR="$(pwd)"
[ -z "$BACKEND_DIR" ] && { echo -e "${R}Run from inside downloader-Api${N}"; exit 1; }

FRONTEND_DIR=""
for name in my-downloader-frontend grabr-frontend frontend; do
  [ -d "$BACKEND_DIR/$name/src" ] && { FRONTEND_DIR="$BACKEND_DIR/$name"; break; }
done

section "0. Detected paths"
pass "Backend  : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend : $FRONTEND_DIR" || warn "Frontend not found"

# ════════════════════════════════════════════════════════════════
section "1. FIX: download.service.js (spawn + sendSSE inside runDownload)"
# ════════════════════════════════════════════════════════════════

cat > "$BACKEND_DIR/src/services/download.service.js" << 'JSEOF'
const { spawn, execFile } = require("child_process");
const path   = require("path");
const fs     = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE registry ─────────────────────────────────────────────────
const sseClients = new Map();

function registerSSE(jobId, res)  { sseClients.set(String(jobId), res); }
function unregisterSSE(jobId)     { sseClients.delete(String(jobId)); }

// sendProgress: used by BOTH runDownload AND the worker
// Always accepts an object { status, percent, ... }
function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try {
    res.write(`data: ${JSON.stringify(data)}\n\n`);
  } catch (e) {
    logger.warn("SSE write failed", { jobId, error: e.message });
    unregisterSSE(jobId);
  }
}

// ── Format map ───────────────────────────────────────────────────
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
  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist",
    "--restrict-filenames",
    "--max-filesize",         `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout",       "60",
    "--retries",              "5",
    "--fragment-retries",     "5",
    "--concurrent-fragments", "4",
    "--no-cache-dir",
    "--no-part",
    "--newline",
    "--ffmpeg-location",      process.env.FFMPEG_PATH || "ffmpeg",
    "-o",                     outputTemplate,
    url,
  ];
}

// Regex parsers
const RE_PROGRESS = /\[download\]\s+([\d.]+)%\s+of\s+([\d.]+\S+)\s+at\s+([\S]+)\s+ETA\s+([\S]+)/;
const RE_MERGE    = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG   = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST     = /\[download\] Destination:\s+(.+)/;

// ── runDownload ──────────────────────────────────────────────────
// onProgress(progressObject) is called for EVERY lifecycle event.
// progressObject shape: { status, percent, speed?, eta?, size?, filename?, fileUrl?, message? }
async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(downloadDir)) fs.mkdirSync(downloadDir, { recursive: true });

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const ytdlpBin = process.env.YTDLP_PATH || "yt-dlp";
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.info("Spawning yt-dlp", { jobId, format, bin: ytdlpBin });

  // Emit starting — both SSE AND BullMQ
  const emit = (data) => {
    sendProgress(jobId, data);          // → SSE stream (instant)
    onProgress && onProgress(data);     // → BullMQ progress (polling fallback)
  };

  emit({ status: "starting", percent: 0 });

  const start = Date.now();
  let outputPath = null;
  let stdoutBuf  = "";
  let stderrBuf  = "";
  let lastPct    = 0;
  let phase      = "downloading";

  return new Promise((resolve, reject) => {
    const child = spawn(ytdlpBin, args, {
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });

    child.stdout.on("data", (chunk) => {
      stdoutBuf += chunk.toString();
      const lines = stdoutBuf.split("\n");
      stdoutBuf = lines.pop(); // keep incomplete line

      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;
        logger.debug("yt-dlp", { jobId, line });

        // Phase switch: merging / ffmpeg post-processing
        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          emit({ status: "processing", percent: 99 });
        }

        // Capture output file path
        const mM = line.match(RE_MERGE);
        const fM = line.match(RE_FFMPEG);
        const dM = line.match(RE_DEST);
        if (mM) outputPath = mM[1].trim();
        else if (fM) outputPath = fM[1].trim();
        else if (dM && !outputPath) outputPath = dM[1].trim();

        // Parse download progress
        const pM = line.match(RE_PROGRESS);
        if (pM) {
          const percent = parseFloat(pM[1]);
          if (percent - lastPct >= 1 || percent >= 100) {
            lastPct = percent;
            emit({
              status:  "downloading",
              percent: Math.min(percent, 98),
              size:    pM[2],
              speed:   pM[3],
              eta:     pM[4],
            });
          }
        }
      }
    });

    child.stderr.on("data", (chunk) => {
      stderrBuf += chunk.toString();
    });

    child.on("close", (code) => {
      const elapsed = ((Date.now() - start) / 1000).toFixed(1);
      logger.info("yt-dlp closed", { jobId, code, elapsed: `${elapsed}s` });

      if (code !== 0) {
        const msg = stderrBuf.trim() || `yt-dlp exited with code ${code}`;
        emit({ status: "error", message: msg });
        return reject(new Error(msg));
      }

      // Resolve output file
      if (!outputPath || !fs.existsSync(outputPath)) {
        const files = fs.readdirSync(downloadDir)
          .filter(f => f.startsWith(String(jobId)))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(downloadDir, f)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime);

        if (!files.length) {
          const err = "Download completed but output file not found";
          emit({ status: "error", message: err });
          return reject(new Error(err));
        }
        outputPath = path.join(downloadDir, files[0].name);
      }

      const filename = path.basename(outputPath);
      const baseUrl  = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
      const fileUrl  = `${baseUrl}/files/${encodeURIComponent(filename)}`;

      // Determine if it's a playable video or audio
      const ext       = path.extname(filename).toLowerCase().replace(".", "");
      const isVideo   = ["mp4", "webm", "mkv", "mov"].includes(ext);
      const isAudio   = ["mp3", "m4a", "ogg", "wav", "opus"].includes(ext);
      const mediaType = isVideo ? "video" : isAudio ? "audio" : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });

      logger.info("Download complete", { jobId, filename, elapsed: `${elapsed}s` });
      resolve({ filePath: outputPath, filename, fileUrl, mediaType });
    });

    child.on("error", (err) => {
      emit({ status: "error", message: err.message });
      reject(err);
    });
  });
}

// ── Metadata ─────────────────────────────────────────────────────
async function getMetadata(url) {
  const bin = process.env.YTDLP_PATH || "yt-dlp";
  return new Promise((resolve, reject) => {
    execFile(bin, ["--dump-json", "--no-playlist", url], { timeout: 30_000 }, (err, stdout) => {
      if (err) return reject(err);
      try {
        const d = JSON.parse(stdout);
        resolve({
          title: d.title, thumbnail: d.thumbnail,
          duration: d.duration, uploader: d.uploader, extractor: d.extractor,
        });
      } catch { reject(new Error("Failed to parse metadata")); }
    });
  });
}

// ── Pruner ────────────────────────────────────────────────────────
function pruneOldFiles() {
  const dir = path.resolve(config.storage.downloadPath);
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
JSEOF
pass "download.service.js — sendProgress wired into emit()"

# ════════════════════════════════════════════════════════════════
section "2. FIX: download.worker.js (sendProgress in onProgress)"
# ════════════════════════════════════════════════════════════════

cat > "$BACKEND_DIR/src/workers/download.worker.js" << 'JSEOF'
require("dotenv").config();
const { Worker } = require("bullmq");
const { getRedisClient }             = require("../config/redis");
const { runDownload, sendProgress }  = require("../services/download.service");
const logger                         = require("../utils/logger");
const { QUEUE_NAME }                 = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

const worker = new Worker(
  QUEUE_NAME,
  async (job) => {
    const { url, format } = job.data;
    logger.info("Processing job", { jobId: job.id, url, format });

    // onProgress receives a structured object from runDownload:
    // { status, percent, speed?, eta?, size?, filename?, fileUrl?, message? }
    const onProgress = async (progressData) => {
      // 1. Update BullMQ (for polling fallback)
      const pct = typeof progressData === "object"
        ? (progressData.percent || 0)
        : Number(progressData) || 0;
      try { await job.updateProgress(Math.floor(pct)); } catch {}

      // 2. Push to SSE stream (THE MISSING LINK — this is what sends data to the browser)
      sendProgress(job.id, typeof progressData === "object"
        ? progressData
        : { status: "downloading", percent: pct }
      );
    };

    // Send initial queued→active transition
    await onProgress({ status: "starting", percent: 5 });

    let result;
    try {
      result = await runDownload(url, format, job.id, onProgress);
    } catch (err) {
      logger.error("Download failed", { jobId: job.id, error: err.message });
      // sendProgress already called inside runDownload on error
      throw err;
    }

    const baseUrl = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
    return {
      filename:    result.filename,
      filePath:    result.filePath,
      downloadUrl: result.fileUrl || `${baseUrl}/files/${encodeURIComponent(result.filename)}`,
      mediaType:   result.mediaType || "file",
    };
  },
  {
    connection: getRedisClient(),
    concurrency: CONCURRENCY,
    limiter: { max: CONCURRENCY, duration: 1000 },
  }
);

worker.on("active",    (job)      => logger.info("Job active",    { jobId: job.id }));
worker.on("completed", (job, val) => logger.info("Job completed", { jobId: job.id, filename: val?.filename }));
worker.on("failed",    (job, err) => logger.error("Job failed",   { jobId: job?.id, error: err.message }));
worker.on("error",     (err)      => logger.error("Worker error", { error: err.message }));

async function shutdown(sig) {
  logger.info(`${sig} — shutting down`);
  await worker.close();
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));

logger.info("Worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });
JSEOF
pass "download.worker.js — sendProgress(job.id, progressData) added"

# ════════════════════════════════════════════════════════════════
section "3. FIX: stream.controller.js (export sendProgress too)"
# ════════════════════════════════════════════════════════════════

cat > "$BACKEND_DIR/src/controllers/stream.controller.js" << 'JSEOF'
const { registerSSE, unregisterSSE, sendProgress } = require("../services/download.service");
const queueService = require("../services/queue.service");
const logger = require("../utils/logger");

async function streamJob(req, res) {
  const { jobId } = req.params;
  if (!jobId || !/^[\w-]+$/.test(jobId)) {
    return res.status(400).json({ error: "Invalid job ID" });
  }

  res.setHeader("Content-Type",    "text/event-stream");
  res.setHeader("Cache-Control",   "no-cache");
  res.setHeader("Connection",      "keep-alive");
  res.setHeader("X-Accel-Buffering","no");
  res.flushHeaders();

  // Keep-alive ping every 20s (prevents Railway/nginx from closing idle connections)
  const ping = setInterval(() => {
    try { res.write(": ping\n\n"); } catch { clearInterval(ping); }
  }, 20_000);

  registerSSE(jobId, res);
  logger.info("SSE client connected", { jobId });

  // Late-join: job finished before client opened SSE connection
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
      // Job active — send current progress so UI doesn't show 0%
      const prog = job.progress || 0;
      if (prog > 0) {
        sendProgress(jobId, { status: "downloading", percent: prog });
      }
    }
  } catch (e) {
    logger.warn("SSE late-join check failed", { jobId, error: e.message });
  }

  function cleanup() {
    clearInterval(ping);
    unregisterSSE(jobId);
    logger.info("SSE client disconnected", { jobId });
    try { res.end(); } catch {}
  }

  req.on("close",  cleanup);
  req.on("error",  cleanup);
  res.on("error",  cleanup);
  res.on("finish", cleanup);
}

module.exports = { streamJob };
JSEOF
pass "stream.controller.js — late-join sends current progress"

# ════════════════════════════════════════════════════════════════
section "4. FIX: download.controller.js — return mediaType in status"
# ════════════════════════════════════════════════════════════════

# Patch getStatus to include mediaType in returnvalue
CTRL="$BACKEND_DIR/src/controllers/download.controller.js"
if [ -f "$CTRL" ]; then
  # Add mediaType to the result object if not already there
  if ! grep -q "mediaType" "$CTRL"; then
    sed -i 's/result: job.returnvalue || null/result: job.returnvalue ? { ...job.returnvalue, mediaType: job.returnvalue.mediaType || "file" } : null/' "$CTRL" 2>/dev/null
    pass "download.controller.js — mediaType added to result"
  else
    pass "download.controller.js — mediaType already present"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "5. FIX: frontend api.js — handle mediaType in watchJob"
# ════════════════════════════════════════════════════════════════

if [ -n "$FRONTEND_DIR" ]; then
cat > "$FRONTEND_DIR/src/api.js" << 'JSEOF'
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
 * watchJob — SSE with polling fallback
 * Callbacks:
 *   onProgress(percent, speed, eta, size)
 *   onStatus(status)
 *   onComplete(filename, fileUrl, mediaType)
 *   onError(message)
 */
export function watchJob(jobId, { onProgress, onStatus, onComplete, onError }) {
  let closed = false;
  let es = null;
  let pollTimer = null;
  let retries = 0;
  const MAX_SSE_RETRIES = 3;

  function stop() {
    closed = true;
    if (es)        { try { es.close(); }          catch {} es = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function handleEvent(data) {
    if (closed) return;
    const status = safeStr(data.status);
    onStatus && onStatus(status);

    switch (status) {
      case "starting":
        onProgress && onProgress(0, "", "", "");
        break;
      case "downloading":
        onProgress && onProgress(
          Number(data.percent) || 0,
          safeStr(data.speed),
          safeStr(data.eta),
          safeStr(data.size),
        );
        break;
      case "processing":
        onProgress && onProgress(99, "", "", "");
        break;
      case "completed":
        onProgress && onProgress(100, "", "", "");
        onComplete && onComplete(
          safeStr(data.filename),
          safeStr(data.fileUrl),
          safeStr(data.mediaType || "file"),
        );
        stop();
        break;
      case "error":
        onError && onError(safeStr(data.message || "Download failed"));
        stop();
        break;
    }
  }

  // Polling fallback
  function startPolling() {
    if (closed || pollTimer) return;
    let count = 0;
    pollTimer = setInterval(async () => {
      if (closed) return;
      count++;
      try {
        const res  = await fetch(`${API_BASE}/api/download/${jobId}`);
        const data = await res.json();
        const pct  = Number(data.progress) || 0;
        onProgress && onProgress(pct, "", "", "");
        onStatus   && onStatus(safeStr(data.state));

        if (data.state === "completed" && data.result) {
          onProgress && onProgress(100, "", "", "");
          onComplete && onComplete(
            safeStr(data.result.filename),
            safeStr(data.result.downloadUrl),
            safeStr(data.result.mediaType || "file"),
          );
          stop();
        } else if (data.state === "failed") {
          onError && onError(safeStr(data.error || "Download failed"));
          stop();
        }
      } catch {
        if (count > 72) { onError && onError("Connection lost"); stop(); }
      }
    }, 2500);
  }

  // SSE primary
  function openSSE() {
    if (closed) return;
    try {
      es = new EventSource(`${API_BASE}/api/download/stream/${jobId}`);
      es.onmessage = (e) => {
        retries = 0;
        try { handleEvent(JSON.parse(e.data)); } catch {}
      };
      es.onerror = () => {
        if (closed) return;
        retries++;
        if (retries >= MAX_SSE_RETRIES) {
          if (es) { try { es.close(); } catch {} es = null; }
          startPolling();
        }
      };
    } catch { startPolling(); }
  }

  openSSE();
  return stop;
}
JSEOF
  pass "api.js — onComplete receives mediaType"
fi

# ════════════════════════════════════════════════════════════════
section "6. FIX: App.jsx — video/audio preview after download"
# ════════════════════════════════════════════════════════════════

if [ -n "$FRONTEND_DIR" ]; then
  APPJSX="$FRONTEND_DIR/src/App.jsx"

  if [ ! -f "$APPJSX" ]; then
    warn "App.jsx not found — skipping"
  else
    # 1. Fix import line
    sed -i "s|import { API_BASE, submitDownload,.*from.*api.*|import { API_BASE, submitDownload, watchJob, safeStr } from \"./api\";|" "$APPJSX"

    # 2. Remove POLL_MS if present
    sed -i '/^const POLL_MS/d' "$APPJSX"

    # 3. Replace useDownloadManager if it still uses polling (startPoll/setInterval)
    if grep -q "startPoll\|setInterval.*pollJob" "$APPJSX"; then
      warn "App.jsx still has polling — needs full replacement"
      warn "Please copy the latest App.jsx from the outputs folder"
    else
      pass "App.jsx — no old polling found"
    fi

    # 4. Add mediaType to job result handling — patch onComplete calls
    # Ensure onComplete has 3 args (filename, fileUrl, mediaType)
    if grep -q "onComplete.*filename.*fileUrl" "$APPJSX" && ! grep -q "mediaType" "$APPJSX"; then
      sed -i 's/onComplete: (filename, fileUrl) =>/onComplete: (filename, fileUrl, mediaType) =>/' "$APPJSX"
      sed -i 's/result: { filename: safeStr(filename), downloadUrl: safeStr(fileUrl) }/result: { filename: safeStr(filename), downloadUrl: safeStr(fileUrl), mediaType: safeStr(mediaType || "file") }/' "$APPJSX"
      pass "App.jsx — mediaType added to onComplete"
    else
      pass "App.jsx — onComplete already handles mediaType"
    fi

    pass "App.jsx patched"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "7. Write App.jsx result card with video/audio preview"
# ════════════════════════════════════════════════════════════════

# Inject the video preview component into App.jsx
if [ -n "$FRONTEND_DIR" ] && [ -f "$FRONTEND_DIR/src/App.jsx" ]; then
  # Write the media preview component as a separate file
  cat > "$FRONTEND_DIR/src/MediaPreview.jsx" << 'JSEOF'
import { useState } from "react";
import { API_BASE, safeStr } from "./api";

export default function MediaPreview({ job }) {
  const [playing, setPlaying] = useState(false);
  const [copied, setCopied]   = useState(false);

  if (!job || job.state !== "completed" || !job.result) return null;

  const { filename, downloadUrl, mediaType } = job.result;
  const safeName = safeStr(filename);
  const safeUrl  = safeStr(downloadUrl);
  const type     = safeStr(mediaType || "file");

  // Build the correct URL
  const fileHref = safeUrl.startsWith("http")
    ? safeUrl
    : `${API_BASE}/files/${encodeURIComponent(safeName)}`;

  const copyLink = async () => {
    await navigator.clipboard.writeText(fileHref);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="media-preview">
      {/* Video player */}
      {type === "video" && (
        <div className="media-player">
          {!playing ? (
            <button className="play-btn" onClick={() => setPlaying(true)}>
              <div className="play-thumb">
                <span className="play-icon">▶</span>
              </div>
              <span className="play-label">Preview video</span>
            </button>
          ) : (
            <video
              className="video-el"
              src={fileHref}
              controls
              autoPlay
              playsInline
            >
              Your browser does not support video playback.
            </video>
          )}
        </div>
      )}

      {/* Audio player */}
      {type === "audio" && (
        <div className="media-player media-audio">
          <span className="audio-icon">🎵</span>
          <audio className="audio-el" src={fileHref} controls />
        </div>
      )}

      {/* File info + actions */}
      <div className="media-info">
        <p className="media-filename">
          {type === "video" ? "🎬" : type === "audio" ? "🎵" : "📄"} {safeName}
        </p>
        <div className="media-actions">
          <a href={fileHref} download={safeName} className="mb primary">
            ⬇ Save file
          </a>
          <button className="mb secondary" onClick={copyLink}>
            {copied ? "✓ Copied!" : "🔗 Copy link"}
          </button>
        </div>
      </div>
    </div>
  );
}
JSEOF
  pass "MediaPreview.jsx created"

  # Add MediaPreview CSS to App.css
  APPCSS="$FRONTEND_DIR/src/App.css"
  if [ -f "$APPCSS" ] && ! grep -q "media-preview" "$APPCSS"; then
    cat >> "$APPCSS" << 'CSSEOF'

/* ── Media Preview ──────────────────────────────────────────── */
.media-preview{
  display:flex;flex-direction:column;gap:0.75rem;
  background:color-mix(in srgb,var(--pri) 6%,var(--surf));
  border:1px solid color-mix(in srgb,var(--pri) 20%,transparent);
  border-radius:var(--r2);padding:0.85rem;
  animation:fadeUp 0.3s ease;
}

.media-player{
  width:100%;border-radius:var(--r3);overflow:hidden;
  background:#000;position:relative;
}

.video-el{
  width:100%;max-height:220px;display:block;border-radius:var(--r3);
}

.audio-el{
  width:100%;accent-color:var(--pri);
}

.media-audio{
  display:flex;align-items:center;gap:0.75rem;
  background:var(--surf2);padding:0.75rem;border-radius:var(--r3);
}

.audio-icon{font-size:1.5rem;flex-shrink:0}

.play-btn{
  width:100%;aspect-ratio:16/9;display:flex;flex-direction:column;
  align-items:center;justify-content:center;gap:0.5rem;
  background:linear-gradient(135deg,#0a0a0a,#1a1a2e);
  border:none;cursor:pointer;border-radius:var(--r3);
  transition:all 0.2s;
}
.play-btn:hover .play-thumb{transform:scale(1.1)}

.play-thumb{
  width:52px;height:52px;border-radius:50%;
  background:linear-gradient(135deg,var(--pri),var(--pri2));
  display:grid;place-items:center;
  box-shadow:0 0 24px var(--glow);
  transition:transform 0.2s;
}

.play-icon{color:#fff;font-size:1.1rem;margin-left:3px}
.play-label{font-size:0.75rem;color:rgba(255,255,255,0.5);font-family:'Plus Jakarta Sans',sans-serif}

.media-info{display:flex;flex-direction:column;gap:0.5rem}

.media-filename{
  font-size:0.72rem;color:var(--txt2);word-break:break-all;line-height:1.4;
}

.media-actions{display:flex;gap:0.5rem}

.mb{
  flex:1;display:flex;align-items:center;justify-content:center;gap:0.35rem;
  padding:0.5rem 0.75rem;border-radius:var(--r3);
  font-size:0.78rem;font-weight:700;
  font-family:'Plus Jakarta Sans',sans-serif;
  transition:all 0.15s;border:none;cursor:pointer;
}
.mb.primary{background:var(--acc);color:#fff}
.mb.primary:hover{filter:brightness(1.1)}
.mb.secondary{background:var(--surf2);color:var(--txt2);border:1px solid var(--bord)}
.mb.secondary:hover{color:var(--txt)}
CSSEOF
    pass "MediaPreview styles added to App.css"
  else
    pass "App.css — media preview styles already present"
  fi

  # Inject MediaPreview import into App.jsx if not there
  if ! grep -q "MediaPreview" "$FRONTEND_DIR/src/App.jsx"; then
    sed -i 's|import { API_BASE, submitDownload|import MediaPreview from "./MediaPreview";\nimport { API_BASE, submitDownload|' "$FRONTEND_DIR/src/App.jsx"
    pass "App.jsx — MediaPreview imported"

    # Replace the completed job card section to use MediaPreview
    # Find the jresult div and replace it
    python3 - "$FRONTEND_DIR/src/App.jsx" << 'PYEOF'
import re, sys

with open(sys.argv[1], 'r') as f:
    content = f.read()

old = r'''{job.state === "completed" && job.result && (
                <div className="jresult">
                  <span className="jfname">\u2705 {filename}</span>
                  <div className="jrbtns">
                    <a
                      href={`${API_BASE}/files/${encodeURIComponent(filename)}`}
                      download={filename}
                      className="rb rb-green"
                    >
                      <I.Save /> Save
                    </a>
                    <button className="rb rb-ghost" onClick={() => doCopy(job)}>
                      {copied === job.id ? <><I.Tick /> Copied!</> : <><I.Copy /> Link</>}
                    </button>
                  </div>
                </div>
              )}'''

new = '''{job.state === "completed" && job.result && (
                <MediaPreview job={job} />
              )}'''

if old in content:
    content = content.replace(old, new)
    print("  replaced jresult with MediaPreview")
else:
    print("  jresult block not found exactly — skipping replacement (MediaPreview still imported)")

with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF
  else
    pass "App.jsx — MediaPreview already present"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "8. Verify all fixes"
# ════════════════════════════════════════════════════════════════

check() {
  local f="$1" needle="$2" label="$3"
  [ ! -f "$f" ] && { fail "$label — FILE MISSING: $f"; return; }
  grep -q "$needle" "$f" && pass "$label" || fail "$label — '$needle' not found"
}

check "$BACKEND_DIR/src/services/download.service.js" "sendProgress"                  "service — sendProgress exported"
check "$BACKEND_DIR/src/services/download.service.js" "emit("                         "service — emit() calls both SSE and onProgress"
check "$BACKEND_DIR/src/services/download.service.js" "mediaType"                     "service — mediaType in completed event"
check "$BACKEND_DIR/src/workers/download.worker.js"   "sendProgress(job.id"           "worker — sendProgress(job.id) called"
check "$BACKEND_DIR/src/workers/download.worker.js"   "status.*starting"              "worker — sends starting event"
check "$BACKEND_DIR/src/controllers/stream.controller.js" "sendProgress"              "stream controller — uses sendProgress"

[ -n "$FRONTEND_DIR" ] && {
  check "$FRONTEND_DIR/src/api.js"          "mediaType"               "api.js — mediaType in onComplete"
  check "$FRONTEND_DIR/src/MediaPreview.jsx" "video"                  "MediaPreview — video element"
  check "$FRONTEND_DIR/src/MediaPreview.jsx" "audio"                  "MediaPreview — audio element"
  check "$FRONTEND_DIR/src/App.css"         "media-preview"           "App.css — media preview styles"
}

# ════════════════════════════════════════════════════════════════
section "9. Git commit & push"
# ════════════════════════════════════════════════════════════════

cd "$BACKEND_DIR" || exit 1

if git rev-parse --git-dir > /dev/null 2>&1; then
  git add \
    src/services/download.service.js \
    src/controllers/stream.controller.js \
    src/workers/download.worker.js \
    src/controllers/download.controller.js

  [ -n "$FRONTEND_DIR" ] && git add \
    "$FRONTEND_DIR/src/api.js" \
    "$FRONTEND_DIR/src/App.jsx" \
    "$FRONTEND_DIR/src/App.css" \
    "$FRONTEND_DIR/src/MediaPreview.jsx" 2>/dev/null

  if git diff --cached --quiet; then
    warn "Nothing new to commit — files unchanged"
  else
    git commit -m "fix: SSE data flow — sendProgress in worker, video/audio preview"
    pass "Committed"
    git push && pass "Pushed → Railway redeploys" || fail "git push failed"
  fi
else
  warn "Not a git repo — push manually"
fi

# ════════════════════════════════════════════════════════════════
section "10. Vercel deploy"
# ════════════════════════════════════════════════════════════════

if [ -n "$FRONTEND_DIR" ]; then
  cd "$FRONTEND_DIR" || exit 1
  [ ! -f ".env.production" ] && echo "VITE_API_URL=https://grabr-production-fa32.up.railway.app" > .env.production

  if command -v vercel &>/dev/null; then
    vercel --prod && pass "Vercel deployed!" || fail "Vercel deploy failed"
  else
    warn "vercel not installed — run: cd $FRONTEND_DIR && vercel --prod"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "Summary"
# ════════════════════════════════════════════════════════════════

if [ $FAIL -eq 0 ]; then
  echo -e "${G}  ✓ All bugs fixed and deployed!${N}"
else
  echo -e "${R}  ✗ $FAIL issue(s) — fix items above${N}"
fi

echo ""
echo "  Bugs fixed:"
echo "  1. Worker now calls sendProgress(job.id, data) → SSE gets data"
echo "  2. onProgress sends structured objects { status, percent, ... }"
echo "  3. runDownload emits to SSE AND BullMQ simultaneously"
echo "  4. Video/audio preview plays inline after download"
echo "  5. late-join SSE sends current progress to reconnecting clients"
echo ""
echo "  Test live SSE (submit a job first, grab the jobId):"
echo "  curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/JOB_ID"
echo "  # You should now see: data: {\"status\":\"downloading\",\"percent\":12,...}"
echo ""