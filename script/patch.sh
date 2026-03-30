#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# patch-worker.sh
# The ONLY reason UI shows queued/0% and nothing downloads:
#   Worker never calls sendProgress() → SSE gets no data
#   Worker onProgress(pct) sends plain number → runDownload ignored it
#
# Patches exactly 3 files, commits, pushes.
# Run: bash script/patch-worker.sh
# ─────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n${B}  $1${N}\n${C}══════════════════════════════════════════${N}"; }
FAIL=0

# ── Find dirs ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=""; dir="$SCRIPT_DIR"
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

section "0. Paths"
pass "Backend  : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend : $FRONTEND_DIR"

# ════════════════════════════════════════════════════════════════
section "1. PATCH: download.worker.js"
# THE FIX: import sendProgress, call it on every progress event
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/workers/download.worker.js" << 'JSEOF'
require("dotenv").config();
const { Worker }                     = require("bullmq");
const { getRedisClient }             = require("../config/redis");
const { runDownload, sendProgress }  = require("../services/download.service");
const logger                         = require("../utils/logger");
const { QUEUE_NAME }                 = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

const worker = new Worker(QUEUE_NAME, async (job) => {
  const { url, format } = job.data;
  logger.info("Job started", { jobId: job.id, url, format });

  /*
   * onProgress is called by runDownload's emit() on every event.
   * progressData is always an object: { status, percent, speed?, eta?, ... }
   *
   * Two things MUST happen here:
   *   1. job.updateProgress(pct)   → BullMQ (enables polling fallback)
   *   2. sendProgress(jobId, data) → SSE stream (what the browser actually sees)
   *
   * Previously only #1 happened — that's why the UI was stuck.
   */
  const onProgress = async (progressData) => {
    const pct = typeof progressData === "object"
      ? Math.floor(progressData.percent || 0)
      : Math.floor(Number(progressData) || 0);

    // 1. BullMQ progress
    try { await job.updateProgress(pct); } catch {}

    // 2. SSE — CRITICAL: this is what sends data to the browser
    sendProgress(String(job.id), typeof progressData === "object"
      ? progressData
      : { status: "downloading", percent: pct }
    );
  };

  let result;
  try {
    result = await runDownload(url, format, job.id, onProgress);
  } catch (err) {
    logger.error("Download failed", { jobId: job.id, error: err.message });
    throw err;
  }

  const baseUrl = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
  return {
    filename:    result.filename,
    filePath:    result.filePath,
    downloadUrl: result.fileUrl || `${baseUrl}/files/${encodeURIComponent(result.filename)}`,
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

async function shutdown(sig) {
  logger.info(`${sig} — shutting down`);
  await worker.close();
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));

logger.info("Worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });
JSEOF
pass "download.worker.js — sendProgress(job.id, data) now called"

# ════════════════════════════════════════════════════════════════
section "2. PATCH: download.service.js"
# Ensure emit() calls BOTH sendProgress AND onProgress
# Ensure spawn is used, --newline flag present
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/services/download.service.js" << 'JSEOF'
const { spawn, execFile } = require("child_process");
const path   = require("path");
const fs     = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE registry ─────────────────────────────────────────────────
const sseClients = new Map();

function registerSSE(jobId, res) {
  sseClients.set(String(jobId), res);
  logger.info("SSE client registered", { jobId, total: sseClients.size });
}

function unregisterSSE(jobId) {
  sseClients.delete(String(jobId));
}

function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) {
    // No SSE client connected — that's OK, worker still calls this
    return;
  }
  try {
    res.write(`data: ${JSON.stringify(data)}\n\n`);
  } catch (e) {
    logger.warn("SSE write failed", { jobId, error: e.message });
    unregisterSSE(jobId);
  }
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

logger.info("Binaries", { ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN });

// ── Filename sanitizer ────────────────────────────────────────────
function sanitizeFilename(raw) {
  return raw
    .replace(/[^\w.-]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 200);
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
    "--newline",             // one progress line per chunk — critical for real-time
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
    catch (e) { throw new Error(`Cannot create dir ${downloadDir}: ${e.message}`); }
  }
  try { fs.accessSync(downloadDir, fs.constants.W_OK); }
  catch { throw new Error(`No write permission: ${downloadDir}`); }

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.info("Spawning yt-dlp", { jobId, bin: YTDLP_BIN, dir: downloadDir });

  /*
   * emit() is the single source of truth for progress.
   * It pushes to:
   *   A. sendProgress(jobId, data) → SSE registry → browser EventSource
   *   B. onProgress(data, pct)    → worker → job.updateProgress + sendProgress again
   *
   * Note: sendProgress is called here AND in the worker.
   * Calling it here too means progress works even without a worker onProgress callback.
   */
  const emit = (data) => {
    // Direct SSE push (works if browser has SSE open)
    sendProgress(String(jobId), data);
    // Also notify worker callback (which calls sendProgress again — harmless duplicate)
    if (onProgress) {
      const pct = typeof data === "object" ? (data.percent || 0) : Number(data) || 0;
      onProgress(data, pct);
    }
  };

  emit({ status: "starting", percent: 5 });

  const start = Date.now();
  let outputPath = null;
  let stdoutBuf  = "";
  let stderrBuf  = "";
  let lastPct    = 0;
  let phase      = "downloading";

  return new Promise((resolve, reject) => {
    const child = spawn(YTDLP_BIN, args, {
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });

    child.stdout.on("data", chunk => {
      stdoutBuf += chunk.toString();
      const lines = stdoutBuf.split("\n");
      stdoutBuf = lines.pop(); // keep incomplete line

      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;

        // Phase: merging
        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          emit({ status: "processing", percent: 99 });
        }

        // Capture output path
        const mM = line.match(RE_MERGE);
        const fM = line.match(RE_FFMPEG);
        const dM = line.match(RE_DEST);
        if (mM) outputPath = mM[1].trim();
        else if (fM) outputPath = fM[1].trim();
        else if (dM && !outputPath) outputPath = dM[1].trim();

        // Parse progress
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

    child.stderr.on("data", chunk => {
      stderrBuf += chunk.toString();
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
      const rawName  = path.basename(outputPath);
      const ext      = path.extname(rawName);
      const baseName = path.basename(rawName, ext);
      const cleanName = sanitizeFilename(baseName) + ext;
      const cleanPath = path.join(downloadDir, cleanName);

      if (rawName !== cleanName && !fs.existsSync(cleanPath)) {
        try { fs.renameSync(outputPath, cleanPath); outputPath = cleanPath; }
        catch { /* keep original */ }
      }

      const filename  = path.basename(outputPath);
      const baseUrl   = config.baseUrl.replace(/\/$/, "");
      const fileUrl   = `${baseUrl}/files/${encodeURIComponent(filename)}`;
      const mediaType = [".mp4",".webm",".mkv",".mov"].includes(ext.toLowerCase()) ? "video"
                      : [".mp3",".m4a",".ogg",".wav",".opus"].includes(ext.toLowerCase()) ? "audio"
                      : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });
      logger.info("Complete", { jobId, filename, elapsed: `${elapsed}s`, fileUrl });
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
    try { if (now - fs.statSync(full).mtimeMs > maxMs) fs.unlinkSync(full); } catch {}
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles, registerSSE, unregisterSSE, sendProgress };
JSEOF
pass "download.service.js — emit() calls both SSE and onProgress"

# ════════════════════════════════════════════════════════════════
section "3. PATCH: stream.controller.js"
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

  res.setHeader("Content-Type",     "text/event-stream");
  res.setHeader("Cache-Control",    "no-cache");
  res.setHeader("Connection",       "keep-alive");
  res.setHeader("X-Accel-Buffering","no");
  res.flushHeaders();

  // Keep-alive ping every 20s
  const ping = setInterval(() => {
    try { res.write(": ping\n\n"); } catch { clearInterval(ping); }
  }, 20_000);

  registerSSE(jobId, res);

  // Late-join: job already finished before SSE connected
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
      // Send current progress if job is active
      const pct = job.progress || 0;
      if (pct > 0) sendProgress(jobId, { status: "downloading", percent: pct });
    }
  } catch (e) {
    logger.warn("SSE late-join failed", { jobId, error: e.message });
  }

  function cleanup() {
    clearInterval(ping);
    unregisterSSE(jobId);
    try { res.end(); } catch {}
  }

  req.on("close",  cleanup);
  req.on("error",  cleanup);
  res.on("error",  cleanup);
  res.on("finish", cleanup);
}

module.exports = { streamJob };
JSEOF
pass "stream.controller.js"

# ════════════════════════════════════════════════════════════════
section "4. Verify the 3 critical connections"
# ════════════════════════════════════════════════════════════════
echo ""

# Check 1: worker imports sendProgress
grep -q "sendProgress" "$BACKEND_DIR/src/workers/download.worker.js" \
  && pass "worker.js imports and calls sendProgress" \
  || fail "worker.js missing sendProgress"

# Check 2: worker onProgress calls sendProgress
grep -q "sendProgress(String(job.id)" "$BACKEND_DIR/src/workers/download.worker.js" \
  && pass "worker.js calls sendProgress(job.id, data)" \
  || fail "worker.js not calling sendProgress correctly"

# Check 3: service exports sendProgress
grep -q "sendProgress" "$BACKEND_DIR/src/services/download.service.js" | grep -q "module.exports" 2>/dev/null
grep -q "module.exports.*sendProgress" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service exports sendProgress" \
  || fail "service does not export sendProgress"

# Check 4: service uses spawn not execFile for download
grep -q "spawn(YTDLP_BIN" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service uses spawn() for download" \
  || fail "service not using spawn()"

# Check 5: --newline flag present
grep -q '"--newline"' "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service has --newline flag" \
  || fail "service missing --newline flag"

# Check 6: emit calls both sendProgress and onProgress
grep -q "sendProgress(String(jobId)" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service emit() calls sendProgress directly" \
  || fail "service emit() not calling sendProgress"

echo ""

# ════════════════════════════════════════════════════════════════
section "5. Git commit and push"
# ════════════════════════════════════════════════════════════════

# Find git root
GIT_ROOT=""
dir="$BACKEND_DIR"
for i in 1 2 3 4 5; do
  [ -d "$dir/.git" ] && { GIT_ROOT="$dir"; break; }
  dir="$(dirname "$dir")"
done

if [ -z "$GIT_ROOT" ]; then
  fail "No git repo found"
  echo ""
  echo "  Copy files manually and push:"
  echo "  cd YOUR_REPO_ROOT"
  echo "  git add src/workers/download.worker.js src/services/download.service.js src/controllers/stream.controller.js"
  echo "  git commit -m 'fix: SSE data flow — worker calls sendProgress'"
  echo "  git push"
else
  pass "Git root: $GIT_ROOT"
  cd "$GIT_ROOT" || exit 1
  git add \
    "$BACKEND_DIR/src/workers/download.worker.js" \
    "$BACKEND_DIR/src/services/download.service.js" \
    "$BACKEND_DIR/src/controllers/stream.controller.js"

  if git diff --cached --quiet; then
    warn "Files unchanged in git — force push with empty commit to trigger Railway redeploy:"
    echo "    git commit --allow-empty -m 'redeploy: trigger Railway rebuild'"
    echo "    git push"
  else
    git commit -m "fix: worker calls sendProgress — SSE now sends real data to browser"
    pass "Committed"
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    git push origin "$BRANCH" \
      && pass "Pushed → Railway worker redeploys" \
      || { git push --set-upstream origin "$BRANCH" && pass "Pushed (upstream set)"; }
  fi
fi

# ════════════════════════════════════════════════════════════════
section "6. Deploy frontend"
# ════════════════════════════════════════════════════════════════
if [ -n "$FRONTEND_DIR" ]; then
  cd "$FRONTEND_DIR" || exit 1
  [ ! -f ".env.production" ] && echo "VITE_API_URL=https://grabr-production-fa32.up.railway.app" > .env.production

  if command -v vercel &>/dev/null; then
    vercel whoami &>/dev/null 2>&1 || vercel login
    vercel --prod --yes && pass "Vercel deployed" || warn "vercel deploy failed — run manually"
  else
    warn "vercel not installed — run: npm i -g vercel && cd $FRONTEND_DIR && vercel --prod"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "Summary"
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${B}  The single root cause:${N}"
echo "  worker.js had onProgress = async (pct) => { job.updateProgress(pct) }"
echo "  It ONLY updated BullMQ. It NEVER called sendProgress()."
echo "  So the SSE stream had an open connection but received zero data."
echo ""
echo -e "${B}  The fix:${N}"
echo "  worker.js now imports sendProgress from download.service"
echo "  onProgress now calls BOTH job.updateProgress AND sendProgress(job.id, data)"
echo ""
echo -e "${B}  After Railway deploys the new worker (~2 min):${N}"
echo "  1. Submit a job in the UI"
echo "  2. In another terminal, watch SSE:"
echo "     curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/JOB_ID"
echo "  3. You should see:"
echo '     data: {"status":"starting","percent":5}'
echo '     data: {"status":"downloading","percent":12,"speed":"2.1MiB/s","eta":"00:30"}'
echo '     data: {"status":"downloading","percent":25,...}'
echo '     data: {"status":"completed","percent":100,"filename":"...","fileUrl":"..."}'
echo ""
if [ $FAIL -eq 0 ]; then echo -e "${G}  ✓ All done!${N}"; else echo -e "${R}  ✗ $FAIL issue(s)${N}"; fi