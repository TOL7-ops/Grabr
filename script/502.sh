#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# fix-502.sh — Fixes 502 crash on Railway startup
# Cause: embedded worker tries Redis with wrong config → process crashes
# Fix:   Redis config supports REDIS_URL + worker wrapped in try/catch
# Run:   bash script/fix-502.sh
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
pass "Backend : $BACKEND_DIR"

# ════════════════════════════════════════════════════════════════
section "1. FIX: config/redis.js — support REDIS_URL (Railway format)"
# ════════════════════════════════════════════════════════════════
# Railway injects a single REDIS_URL like:
#   redis://default:password@host.railway.internal:6379
# The old config used separate host/port which is wrong
cat > "$BACKEND_DIR/src/config/redis.js" << 'EOF'
const Redis  = require("ioredis");
const logger = require("../utils/logger");

let client = null;

function getRedisClient() {
  if (client) return client;

  const url  = process.env.REDIS_URL;
  const host = process.env.REDIS_HOST || "localhost";
  const port = parseInt(process.env.REDIS_PORT, 10) || 6379;
  const pass = process.env.REDIS_PASSWORD || undefined;

  const baseOpts = {
    maxRetriesPerRequest: null,   // required by BullMQ
    enableReadyCheck:     false,
    lazyConnect:          false,
    retryStrategy: (times) => {
      if (times > 10) return null; // stop retrying after 10 attempts
      return Math.min(times * 500, 3000);
    },
  };

  // Prefer REDIS_URL (Railway native format) over separate host/port
  if (url) {
    logger.info("Redis: connecting via REDIS_URL");
    client = new Redis(url, baseOpts);
  } else {
    logger.info("Redis: connecting via host/port", { host, port });
    client = new Redis({ host, port, password: pass, ...baseOpts });
  }

  client.on("connect", () => logger.info("Redis connected"));
  client.on("ready",   () => logger.info("Redis ready"));
  client.on("error",   err => logger.error("Redis error", { error: err.message }));
  client.on("close",   ()  => logger.warn("Redis connection closed"));

  return client;
}

module.exports = { getRedisClient };
EOF
pass "config/redis.js — REDIS_URL support added"

# ════════════════════════════════════════════════════════════════
section "2. FIX: server.js — worker in try/catch so crash doesn't kill API"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/server.js" << 'EOF'
require("dotenv").config();
const app    = require("./app");
const config = require("./config");
const logger = require("./utils/logger");
const { pruneOldFiles } = require("./services/download.service");

const server = app.listen(config.port, () => {
  logger.info("Server started", {
    port:      config.port,
    env:       config.nodeEnv,
    baseUrl:   config.baseUrl,
    runWorker: process.env.RUN_WORKER,
    redisUrl:  process.env.REDIS_URL ? "set" : "not set",
  });
});

pruneOldFiles();
const pruneInterval = setInterval(pruneOldFiles, 60 * 60 * 1000);

// ── Embedded worker ───────────────────────────────────────────────
// WHY: API and worker must share the same Node.js process to share
//      the sseClients Map. Separate Railway services = separate Maps
//      = worker can't push to SSE = only pings forever.
//
// HOW: set RUN_WORKER=true in Railway → API service → Variables
//      Worker starts in same process → shares sseClients → SSE works
//
// SAFE: wrapped in try/catch so a worker crash doesn't kill the API
if (process.env.RUN_WORKER === "true") {
  try {
    logger.info("Starting embedded worker...");
    require("./workers/download.worker");
    logger.info("Embedded worker started OK");
  } catch (err) {
    // Log but don't crash — API stays up even if worker fails
    logger.error("Embedded worker failed to start", {
      error: err.message,
      stack: err.stack,
    });
  }
}

async function shutdown(signal) {
  logger.info(`${signal} — shutting down`);
  clearInterval(pruneInterval);
  server.close(() => {
    logger.info("HTTP server closed");
    process.exit(0);
  });
  setTimeout(() => { logger.error("Forced shutdown"); process.exit(1); }, 10_000);
}

process.on("SIGTERM",            () => shutdown("SIGTERM"));
process.on("SIGINT",             () => shutdown("SIGINT"));
process.on("uncaughtException",  err => {
  logger.error("Uncaught exception", { error: err.message });
  process.exit(1);
});
process.on("unhandledRejection", reason => {
  logger.error("Unhandled rejection", { reason: String(reason) });
  process.exit(1);
});
EOF
pass "server.js — worker in try/catch, won't crash API on error"

# ════════════════════════════════════════════════════════════════
section "3. FIX: download.worker.js — handle Redis errors gracefully"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/workers/download.worker.js" << 'EOF'
require("dotenv").config();
const { Worker }                     = require("bullmq");
const { getRedisClient }             = require("../config/redis");
const { runDownload, sendProgress }  = require("../services/download.service");
const logger                         = require("../utils/logger");
const { QUEUE_NAME }                 = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

let worker;
try {
  worker = new Worker(QUEUE_NAME, async (job) => {
    const { url, format } = job.data;
    logger.info("Job started", { jobId: job.id, url, format });

    const onProgress = async (progressData) => {
      const pct = typeof progressData === "object"
        ? Math.floor(progressData.percent || 0)
        : Math.floor(Number(progressData) || 0);

      // 1. BullMQ progress (polling fallback)
      try { await job.updateProgress(pct); } catch {}

      // 2. SSE — sends data to browser via shared sseClients Map
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

    const baseUrl = (process.env.BASE_URL || config?.baseUrl || "http://localhost:3000").replace(/\/$/, "");
    return {
      filename:    result.filename,
      filePath:    result.filePath,
      downloadUrl: result.fileUrl || `${baseUrl}/files/${encodeURIComponent(result.filename)}`,
      mediaType:   result.mediaType || "file",
    };
  }, {
    connection:  getRedisClient(),
    concurrency: CONCURRENCY,
    limiter:     { max: CONCURRENCY, duration: 1000 },
  });

  worker.on("active",    j      => logger.info("Job active",    { jobId: j.id }));
  worker.on("completed", (j, v) => logger.info("Job completed", { jobId: j.id, file: v?.filename }));
  worker.on("failed",    (j, e) => logger.error("Job failed",   { jobId: j?.id, error: e.message }));
  worker.on("error",     e      => logger.error("Worker error", { error: e.message }));

  logger.info("Worker ready", { concurrency: CONCURRENCY, queue: QUEUE_NAME });

} catch (err) {
  logger.error("Worker init failed", { error: err.message });
  // Don't exit — if embedded, API still runs
  if (require.main === module) process.exit(1);
}

// Only set up shutdown handlers when run standalone
if (require.main === module) {
  async function shutdown(sig) {
    logger.info(`${sig} — shutting down worker`);
    if (worker) await worker.close();
    process.exit(0);
  }
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT",  () => shutdown("SIGINT"));
}

module.exports = worker;
EOF
pass "download.worker.js — safe init, won't crash API if Redis fails"

# ════════════════════════════════════════════════════════════════
section "4. FIX: queue.service.js — use REDIS_URL"
# ════════════════════════════════════════════════════════════════
cat > "$BACKEND_DIR/src/services/queue.service.js" << 'EOF'
const { Queue } = require("bullmq");
const { getRedisClient } = require("../config/redis");
const logger = require("../utils/logger");

const QUEUE_NAME = "downloads";
let queue = null;

function getQueue() {
  if (!queue) {
    queue = new Queue(QUEUE_NAME, {
      connection: getRedisClient(),
      defaultJobOptions: {
        attempts:     parseInt(process.env.JOB_ATTEMPTS, 10)     || 3,
        backoff:      { type: "exponential", delay: parseInt(process.env.JOB_BACKOFF_DELAY, 10) || 5000 },
        removeOnComplete: { count: 100 },
        removeOnFail:     { count: 200 },
      },
    });
  }
  return queue;
}

async function addDownloadJob(data) {
  const q = getQueue();
  const job = await q.add("download", data);
  logger.info("Job queued", { jobId: job.id, url: data.url });
  return job;
}

async function getJob(id) {
  return getQueue().getJob(id);
}

async function getQueueMetrics() {
  const q = getQueue();
  const [waiting, active, completed, failed, delayed] = await Promise.all([
    q.getWaitingCount(), q.getActiveCount(), q.getCompletedCount(),
    q.getFailedCount(),  q.getDelayedCount(),
  ]);
  return { waiting, active, completed, failed, delayed };
}

async function closeQueue() {
  if (queue) { await queue.close(); queue = null; }
}

module.exports = { addDownloadJob, getJob, getQueueMetrics, closeQueue, QUEUE_NAME };
EOF
pass "queue.service.js — uses getRedisClient() with REDIS_URL support"

# ════════════════════════════════════════════════════════════════
section "5. Verify Railway variables needed"
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${B}  Railway → API service → Variables must have ALL of these:${N}"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ RUN_WORKER    = true                                         │"
echo "  │ REDIS_URL     = \${{Redis.REDIS_URL}}                        │"
echo "  │ BASE_URL      = https://grabr-production-fa32.up.railway.app │"
echo "  │ DOWNLOAD_PATH = /tmp/downloads                               │"
echo "  │ NODE_ENV      = production                                   │"
echo "  │ YTDLP_PATH    = /usr/local/bin/yt-dlp                        │"
echo "  │ FFMPEG_PATH   = /usr/bin/ffmpeg                              │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${Y}  REDIS_URL must use Railway reference syntax: \${{Redis.REDIS_URL}}${N}"
echo "  NOT a hardcoded string — Railway fills it in at runtime"
echo ""

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
    "$BACKEND_DIR/src/config/redis.js" \
    "$BACKEND_DIR/src/server.js" \
    "$BACKEND_DIR/src/workers/download.worker.js" \
    "$BACKEND_DIR/src/services/queue.service.js"
  if git diff --cached --quiet; then
    git commit --allow-empty -m "fix: 502 — Redis URL, worker try/catch, embedded worker"
  else
    git commit -m "fix: 502 crash — REDIS_URL support, safe worker embed, try/catch"
  fi
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  git push origin "$BRANCH" \
    && pass "Pushed → Railway rebuilds" \
    || { git push --set-upstream origin "$BRANCH" && pass "Pushed"; }
else
  warn "No git repo — push manually"
fi

# ════════════════════════════════════════════════════════════════
section "7. After Railway redeploys — test sequence"
# ════════════════════════════════════════════════════════════════
echo ""
echo "  Wait ~2 min for Railway to redeploy, then:"
echo ""
echo "  1. Health check:"
echo "     curl https://grabr-production-fa32.up.railway.app/health"
echo "     # Must return 200 with {status:ok}"
echo ""
echo "  2. Debug path (confirms /tmp/downloads writable):"
echo "     curl https://grabr-production-fa32.up.railway.app/debug/path"
echo "     # Must show writable:true and RUN_WORKER:true"
echo ""
echo "  3. Submit job:"
echo "     curl -X POST https://grabr-production-fa32.up.railway.app/api/download \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"url\":\"https://youtu.be/dQw4w9WgXcQ\",\"format\":\"mp4\"}'"
echo ""
echo "  4. Watch SSE (replace JOB_ID):"
echo "     curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/JOB_ID"
echo "     # Must show: data: {\"status\":\"downloading\",\"percent\":12,...}"
echo ""
if [ $FAIL -eq 0 ]; then echo -e "${G}  ✓ All done!${N}"; else echo -e "${R}  ✗ $FAIL issue(s)${N}"; fi