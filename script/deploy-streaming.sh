#!/bin/bash

# ─────────────────────────────────────────────────────────────────
# deploy-streaming.sh
# Copies all streaming files to the right places, verifies them,
# then commits to git and redeploys the frontend to Vercel.
#
# Run from inside downloader-Api:
#   bash script/deploy-streaming.sh
# ─────────────────────────────────────────────────────────────────

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n${B}  $1${N}\n${C}══════════════════════════════════════════${N}"; }
FAIL=0

# ── Auto-detect dirs ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=""
dir="$SCRIPT_DIR"
for i in 1 2 3 4 5; do
  [ -f "$dir/src/app.js" ] && { BACKEND_DIR="$dir"; break; }
  dir="$(dirname "$dir")"
done
[ -z "$BACKEND_DIR" ] && [ -f "$(pwd)/src/app.js" ] && BACKEND_DIR="$(pwd)"

if [ -z "$BACKEND_DIR" ]; then
  echo -e "${R}Cannot find backend. Run from inside downloader-Api.${N}"
  exit 1
fi

FRONTEND_DIR=""
for name in my-downloader-frontend grabr-frontend frontend; do
  [ -d "$BACKEND_DIR/$name/src" ] && { FRONTEND_DIR="$BACKEND_DIR/$name"; break; }
done

section "0. Paths"
pass "Backend  : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend : $FRONTEND_DIR" || warn "Frontend not found — skipping frontend steps"

# ── 1. Write backend files ──────────────────────────────────────
section "1. Writing backend files"

# ── download.service.js ─────────────────────────────────────────
cat > "$BACKEND_DIR/src/services/download.service.js" << 'JSEOF'
const { spawn, execFile } = require("child_process");
const path = require("path");
const fs = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE client registry ──────────────────────────────────────────
const sseClients = new Map();
function registerSSE(jobId, res)  { sseClients.set(String(jobId), res); }
function unregisterSSE(jobId)     { sseClients.delete(String(jobId)); }
function sendSSE(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) { logger.warn("SSE write failed", { jobId, error: e.message }); unregisterSSE(jobId); }
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
    "--no-playlist", "--restrict-filenames",
    "--max-filesize",        `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout",      "60",
    "--retries",             "5",
    "--fragment-retries",    "5",
    "--concurrent-fragments","4",
    "--no-cache-dir",
    "--no-part",
    "--newline",
    "--ffmpeg-location",     process.env.FFMPEG_PATH || "ffmpeg",
    "-o",                    outputTemplate,
    url,
  ];
}

const RE_PROGRESS = /\[download\]\s+([\d.]+)%\s+of\s+([\d.]+\S+)\s+at\s+([\S]+)\s+ETA\s+([\S]+)/;
const RE_MERGE    = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG   = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST     = /\[download\] Destination:\s+(.+)/;

async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(downloadDir)) fs.mkdirSync(downloadDir, { recursive: true });

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const ytdlpBin = process.env.YTDLP_PATH || "yt-dlp";
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.info("Spawning yt-dlp", { jobId, format });
  sendSSE(jobId, { status: "starting", percent: 0 });
  onProgress && onProgress(0);

  const start = Date.now();
  let outputPath = null, stdoutBuf = "", stderrBuf = "", lastPct = 0, phase = "downloading";

  return new Promise((resolve, reject) => {
    const child = spawn(ytdlpBin, args, { env: { ...process.env, PYTHONUNBUFFERED: "1" } });

    child.stdout.on("data", (chunk) => {
      stdoutBuf += chunk.toString();
      const lines = stdoutBuf.split("\n");
      stdoutBuf = lines.pop();

      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;

        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          sendSSE(jobId, { status: "processing", percent: 99 });
          onProgress && onProgress(99);
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
            sendSSE(jobId, { status: "downloading", percent, size: pM[2], speed: pM[3], eta: pM[4] });
            onProgress && onProgress(Math.min(Math.floor(percent), 98));
          }
        }
      }
    });

    child.stderr.on("data", (chunk) => { stderrBuf += chunk.toString(); });

    child.on("close", (code) => {
      const elapsed = ((Date.now() - start) / 1000).toFixed(1);
      logger.info("yt-dlp closed", { jobId, code, elapsed: `${elapsed}s` });

      if (code !== 0) {
        const msg = stderrBuf.trim() || `yt-dlp exited with code ${code}`;
        sendSSE(jobId, { status: "error", message: msg });
        return reject(new Error(msg));
      }

      if (!outputPath || !fs.existsSync(outputPath)) {
        const files = fs.readdirSync(downloadDir)
          .filter(f => f.startsWith(String(jobId)))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(downloadDir, f)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime);
        if (!files.length) {
          const err = "Download completed but output file not found";
          sendSSE(jobId, { status: "error", message: err });
          return reject(new Error(err));
        }
        outputPath = path.join(downloadDir, files[0].name);
      }

      const filename = path.basename(outputPath);
      const baseUrl  = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
      const fileUrl  = `${baseUrl}/files/${encodeURIComponent(filename)}`;

      sendSSE(jobId, { status: "completed", percent: 100, filename, fileUrl });
      onProgress && onProgress(100);
      logger.info("Download complete", { jobId, filename, elapsed: `${elapsed}s` });
      resolve({ filePath: outputPath, filename });
    });

    child.on("error", (err) => {
      sendSSE(jobId, { status: "error", message: err.message });
      reject(err);
    });
  });
}

async function getMetadata(url) {
  const bin = process.env.YTDLP_PATH || "yt-dlp";
  return new Promise((resolve, reject) => {
    execFile(bin, ["--dump-json", "--no-playlist", url], { timeout: 30_000 }, (err, stdout) => {
      if (err) return reject(err);
      try {
        const d = JSON.parse(stdout);
        resolve({ title: d.title, thumbnail: d.thumbnail, duration: d.duration, uploader: d.uploader, extractor: d.extractor });
      } catch { reject(new Error("Failed to parse metadata")); }
    });
  });
}

function pruneOldFiles() {
  const dir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(dir)) return;
  const maxMs = config.storage.maxFileAgeHours * 3600 * 1000;
  const now = Date.now();
  fs.readdirSync(dir).forEach(f => {
    const full = path.join(dir, f);
    try { if (now - fs.statSync(full).mtimeMs > maxMs) { fs.unlinkSync(full); logger.info("Pruned", { f }); } }
    catch (e) { logger.warn("Prune failed", { f, error: e.message }); }
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles, registerSSE, unregisterSSE, sendSSE };
JSEOF
pass "src/services/download.service.js"

# ── stream.controller.js ────────────────────────────────────────
cat > "$BACKEND_DIR/src/controllers/stream.controller.js" << 'JSEOF'
const { registerSSE, unregisterSSE } = require("../services/download.service");
const queueService = require("../services/queue.service");
const logger = require("../utils/logger");

async function streamJob(req, res) {
  const { jobId } = req.params;
  if (!jobId || !/^[\w-]+$/.test(jobId)) return res.status(400).json({ error: "Invalid job ID" });

  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();

  const ping = setInterval(() => { try { res.write(": ping\n\n"); } catch { clearInterval(ping); } }, 20_000);

  registerSSE(jobId, res);

  // Late-join: job already done before client connected
  try {
    const job = await queueService.getJob(jobId);
    if (job) {
      const state = await job.getState();
      if (state === "completed" && job.returnvalue) {
        const { filename, downloadUrl } = job.returnvalue;
        res.write(`data: ${JSON.stringify({ status: "completed", percent: 100, filename, fileUrl: downloadUrl })}\n\n`);
        cleanup(); return;
      }
      if (state === "failed") {
        res.write(`data: ${JSON.stringify({ status: "error", message: job.failedReason || "Download failed" })}\n\n`);
        cleanup(); return;
      }
    }
  } catch (e) { logger.warn("SSE late-join check failed", { jobId, error: e.message }); }

  function cleanup() {
    clearInterval(ping);
    unregisterSSE(jobId);
    try { res.end(); } catch {}
  }

  req.on("close", cleanup);
  req.on("error", cleanup);
  res.on("error", cleanup);
  res.on("finish", cleanup);
}

module.exports = { streamJob };
JSEOF
pass "src/controllers/stream.controller.js"

# ── download.routes.js ──────────────────────────────────────────
cat > "$BACKEND_DIR/src/routes/download.routes.js" << 'JSEOF'
const express = require("express");
const router = express.Router();
const controller = require("../controllers/download.controller");
const { streamJob } = require("../controllers/stream.controller");
const { downloadLimiter } = require("../middlewares/rateLimiter.middleware");

router.get("/queue/metrics", controller.getQueueMetrics);
router.get("/stream/:jobId", streamJob);
router.post("/", downloadLimiter, controller.createDownload);
router.get("/:id", controller.getStatus);

module.exports = router;
JSEOF
pass "src/routes/download.routes.js"

# ── download.worker.js ──────────────────────────────────────────
cat > "$BACKEND_DIR/src/workers/download.worker.js" << 'JSEOF'
require("dotenv").config();
const { Worker } = require("bullmq");
const { getRedisClient } = require("../config/redis");
const { runDownload } = require("../services/download.service");
const logger = require("../utils/logger");
const { QUEUE_NAME } = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

const worker = new Worker(
  QUEUE_NAME,
  async (job) => {
    const { url, format } = job.data;
    logger.info("Processing job", { jobId: job.id, url, format });

    const onProgress = async (pct) => { try { await job.updateProgress(pct); } catch {} };
    await onProgress(5);

    let result;
    try {
      result = await runDownload(url, format, job.id, onProgress);
    } catch (err) {
      logger.error("Download failed", { jobId: job.id, error: err.message });
      throw err;
    }

    await onProgress(100);
    const baseUrl = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
    return {
      filename:    result.filename,
      filePath:    result.filePath,
      downloadUrl: `${baseUrl}/files/${encodeURIComponent(result.filename)}`,
    };
  },
  { connection: getRedisClient(), concurrency: CONCURRENCY, limiter: { max: CONCURRENCY, duration: 1000 } }
);

worker.on("active",    (job)      => logger.info("Job active",    { jobId: job.id }));
worker.on("completed", (job, val) => logger.info("Job completed", { jobId: job.id, filename: val?.filename }));
worker.on("failed",    (job, err) => logger.error("Job failed",   { jobId: job?.id, error: err.message }));
worker.on("error",     (err)      => logger.error("Worker error", { error: err.message }));

async function shutdown(sig) { logger.info(`${sig} — shutting down`); await worker.close(); process.exit(0); }
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));

logger.info("Worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });
JSEOF
pass "src/workers/download.worker.js"

# ── 2. Write frontend files ─────────────────────────────────────
section "2. Writing frontend files"

if [ -z "$FRONTEND_DIR" ]; then
  warn "No frontend dir found — skipping frontend file writes"
else
  # ── api.js ──────────────────────────────────────────────────
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
    return { ok: false, error: safeStr(err?.message || "Network error — check your connection") };
  }
}

export function watchJob(jobId, { onProgress, onStatus, onComplete, onError }) {
  let closed = false;
  let es = null;
  let pollTimer = null;
  let retries = 0;
  const MAX_RETRIES = 3;

  function stop() {
    closed = true;
    if (es)        { try { es.close(); }          catch {} es = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function handleEvent(data) {
    if (closed) return;
    onStatus && onStatus(safeStr(data.status));
    switch (data.status) {
      case "starting":     onProgress && onProgress(0, "", "", ""); break;
      case "downloading":
        onProgress && onProgress(Number(data.percent)||0, safeStr(data.speed), safeStr(data.eta), safeStr(data.size));
        break;
      case "processing":   onProgress && onProgress(99, "", "", ""); break;
      case "completed":
        onProgress && onProgress(100, "", "", "");
        onComplete && onComplete(safeStr(data.filename), safeStr(data.fileUrl));
        stop(); break;
      case "error":
        onError && onError(safeStr(data.message));
        stop(); break;
    }
  }

  function startPolling() {
    if (closed || pollTimer) return;
    let count = 0;
    pollTimer = setInterval(async () => {
      if (closed) { clearInterval(pollTimer); return; }
      count++;
      try {
        const res  = await fetch(`${API_BASE}/api/download/${jobId}`);
        const data = await res.json();
        const pct  = Number(data.progress) || 0;
        onProgress && onProgress(pct, "", "", "");
        onStatus   && onStatus(safeStr(data.state));
        if (data.state === "completed" && data.result) {
          onProgress && onProgress(100, "", "", "");
          onComplete && onComplete(safeStr(data.result.filename), safeStr(data.result.downloadUrl));
          stop();
        } else if (data.state === "failed") {
          onError && onError(safeStr(data.error || "Download failed"));
          stop();
        }
      } catch {
        if (count > 72) { onError && onError("Connection lost after 3 minutes"); stop(); }
      }
    }, 2500);
  }

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
        if (retries >= MAX_RETRIES) {
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
  pass "src/api.js"

  # ── Patch App.jsx import line ────────────────────────────────
  APPJSX="$FRONTEND_DIR/src/App.jsx"
  if [ -f "$APPJSX" ]; then
    # Fix import to use watchJob instead of pollJob
    sed -i "s/import { API_BASE, submitDownload, pollJob }.*/import { API_BASE, submitDownload, watchJob, safeStr as apiSafeStr } from \".\/api\";/" "$APPJSX" 2>/dev/null
    # Remove old POLL_MS constant
    sed -i '/^const POLL_MS/d' "$APPJSX" 2>/dev/null
    pass "src/App.jsx imports patched"
  else
    warn "App.jsx not found — skipping patch"
  fi
fi

# ── 3. Verify files ─────────────────────────────────────────────
section "3. Verifying written files"

check() {
  local f="$1" needle="$2" label="$3"
  if [ ! -f "$f" ]; then fail "$label — FILE MISSING"; return; fi
  grep -q "$needle" "$f" && pass "$label" || fail "$label — '$needle' not found in file"
}

check "$BACKEND_DIR/src/services/download.service.js" "spawn"            "download.service — uses spawn"
check "$BACKEND_DIR/src/services/download.service.js" "sseClients"       "download.service — SSE registry"
check "$BACKEND_DIR/src/services/download.service.js" "newline"          "download.service — --newline flag"
check "$BACKEND_DIR/src/services/download.service.js" "concurrent-fragments" "download.service — --concurrent-fragments"
check "$BACKEND_DIR/src/controllers/stream.controller.js" "text/event-stream"  "stream.controller — SSE headers"
check "$BACKEND_DIR/src/controllers/stream.controller.js" "flushHeaders"       "stream.controller — flushHeaders"
check "$BACKEND_DIR/src/controllers/stream.controller.js" "registerSSE"        "stream.controller — registerSSE"
check "$BACKEND_DIR/src/routes/download.routes.js"    "stream/:jobId"    "routes — /stream/:jobId"
check "$BACKEND_DIR/src/workers/download.worker.js"   "onProgress"       "worker — onProgress callback"

[ -n "$FRONTEND_DIR" ] && {
  check "$FRONTEND_DIR/src/api.js" "watchJob"    "api.js — watchJob export"
  check "$FRONTEND_DIR/src/api.js" "EventSource" "api.js — EventSource"
  check "$FRONTEND_DIR/src/api.js" "startPolling" "api.js — polling fallback"
}

# ── 4. Git commit ───────────────────────────────────────────────
section "4. Git commit & push"

cd "$BACKEND_DIR" || { fail "Cannot cd to backend"; exit 1; }

if ! git rev-parse --git-dir > /dev/null 2>&1; then
  warn "Not a git repo — skipping git steps"
else
  git add \
    src/services/download.service.js \
    src/controllers/stream.controller.js \
    src/routes/download.routes.js \
    src/workers/download.worker.js

  [ -n "$FRONTEND_DIR" ] && git add \
    "$FRONTEND_DIR/src/api.js" \
    "$FRONTEND_DIR/src/App.jsx" 2>/dev/null

  if git diff --cached --quiet; then
    warn "No changes to commit — files already up to date"
  else
    git commit -m "feat: SSE streaming progress — spawn, no polling, speed+ETA display"
    pass "Committed"
    git push && pass "Pushed to Railway" || fail "git push failed — check your remote"
  fi
fi

# ── 5. Vercel deploy ─────────────────────────────────────────────
section "5. Vercel frontend deploy"

if [ -n "$FRONTEND_DIR" ]; then
  cd "$FRONTEND_DIR" || { fail "Cannot cd to frontend"; exit 1; }

  # Make sure .env.production has the Railway URL
  if [ ! -f ".env.production" ] || ! grep -q "VITE_API_URL" ".env.production"; then
    echo "VITE_API_URL=https://grabr-production-fa32.up.railway.app" > .env.production
    pass "Created .env.production"
  fi

  if command -v vercel &>/dev/null; then
    echo "  Running: vercel --prod"
    vercel --prod && pass "Vercel deployed!" || fail "Vercel deploy failed"
  else
    warn "vercel CLI not found — run manually:"
    warn "  cd $FRONTEND_DIR && vercel --prod"
  fi
else
  warn "No frontend dir found — deploy manually"
fi

# ── Summary ──────────────────────────────────────────────────────
section "Summary"

if [ $FAIL -eq 0 ]; then
  echo -e "${G}  ✓ All done! SSE streaming is live.${N}"
  echo ""
  echo "  What changed:"
  echo "  • Backend: execFile → spawn (real-time stdout)"
  echo "  • Backend: /api/download/stream/:jobId SSE endpoint"
  echo "  • Backend: --newline --concurrent-fragments 4 --no-part flags"
  echo "  • Frontend: EventSource instead of setInterval polling"
  echo "  • Frontend: shows speed + ETA on download cards"
  echo ""
  echo "  Test SSE directly:"
  echo "  curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/1"
else
  echo -e "${R}  ✗ $FAIL failure(s) — fix items above${N}"
fi
echo ""