#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# fix-cors-and-sse.sh
# Fix 1: CORS — allow ALL vercel.app subdomains (grab-wine, grabr-blue, etc.)
# Fix 2: SSE — embed worker inside API process (RUN_WORKER=true)
#         so sseClients Map is shared in same Node.js process
# Run: bash script/fix-cors-and-sse.sh
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
pass "Backend  : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend : $FRONTEND_DIR"

# ════════════════════════════════════════════════════════════════
section "1. FIX CORS — allow all *.vercel.app domains"
# ════════════════════════════════════════════════════════════════
# The error: grab-wine.vercel.app blocked because CORS_ORIGIN=grabr-blue.vercel.app
# Fix: allow ALL *.vercel.app subdomains via regex — no env var needed

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
EOF
pass "app.js — CORS allows ALL *.vercel.app subdomains"

# ════════════════════════════════════════════════════════════════
section "2. FIX SSE — embed worker inside API process"
# ════════════════════════════════════════════════════════════════
# WHY this fixes SSE:
#
# Two separate Railway services = two Node.js processes = two separate
# sseClients Maps in memory.
#
# Browser connects to API → registers in API's sseClients Map
# Worker calls sendProgress() → looks in WORKER's sseClients Map → EMPTY
# Result: only pings, no data
#
# Fix: RUN_WORKER=true makes worker run inside the API process
# They share the SAME sseClients Map → sendProgress finds the client → data flows

cat > "$BACKEND_DIR/src/server.js" << 'EOF'
require("dotenv").config();
const app    = require("./app");
const config = require("./config");
const logger = require("./utils/logger");
const { pruneOldFiles } = require("./services/download.service");

const server = app.listen(config.port, () => {
  logger.info("Server started", {
    port:    config.port,
    env:     config.nodeEnv,
    baseUrl: config.baseUrl,
    worker:  process.env.RUN_WORKER === "true" ? "embedded" : "external",
  });
});

pruneOldFiles();
const pruneInterval = setInterval(pruneOldFiles, 60 * 60 * 1000);

// ── Embedded worker ───────────────────────────────────────────────
// CRITICAL for SSE: API and worker must share the same Node.js process
// so they share the same sseClients Map in download.service.js
//
// Set RUN_WORKER=true in Railway → API service → Variables
// Then delete the separate worker service — you only need one service
if (process.env.RUN_WORKER === "true") {
  logger.info("Starting embedded worker (same process as API — SSE will work correctly)");
  require("./workers/download.worker");
}

async function shutdown(signal) {
  logger.info(`${signal} — shutting down`);
  clearInterval(pruneInterval);
  server.close(() => { logger.info("HTTP server closed"); process.exit(0); });
  setTimeout(() => { logger.error("Forced shutdown"); process.exit(1); }, 10_000);
}

process.on("SIGTERM",             () => shutdown("SIGTERM"));
process.on("SIGINT",              () => shutdown("SIGINT"));
process.on("uncaughtException",   err => { logger.error("Uncaught exception", { error: err.message }); process.exit(1); });
process.on("unhandledRejection",  reason => { logger.error("Unhandled rejection", { reason }); process.exit(1); });
EOF
pass "server.js — embedded worker with RUN_WORKER=true"

# ════════════════════════════════════════════════════════════════
section "3. Verify fixes"
# ════════════════════════════════════════════════════════════════
grep -q "vercel\.app" "$BACKEND_DIR/src/app.js" \
  && pass "app.js — vercel.app regex present" \
  || fail "app.js — vercel.app regex missing"

grep -q "app.options" "$BACKEND_DIR/src/app.js" \
  && pass "app.js — OPTIONS preflight handler present" \
  || fail "app.js — OPTIONS preflight missing"

grep -q "RUN_WORKER" "$BACKEND_DIR/src/server.js" \
  && pass "server.js — RUN_WORKER check present" \
  || fail "server.js — RUN_WORKER check missing"

grep -q "require.*download.worker" "$BACKEND_DIR/src/server.js" \
  && pass "server.js — worker require present" \
  || fail "server.js — worker require missing"

# ════════════════════════════════════════════════════════════════
section "4. Git commit and push"
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
    "$BACKEND_DIR/src/server.js"
  if git diff --cached --quiet; then
    warn "Nothing new to commit — forcing redeploy"
    git commit --allow-empty -m "redeploy: fix CORS + embed worker for SSE"
  else
    git commit -m "fix: CORS all vercel.app subdomains + embed worker in API process"
  fi
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  git push origin "$BRANCH" \
    && pass "Pushed → Railway redeploys" \
    || { git push --set-upstream origin "$BRANCH" && pass "Pushed"; }
else
  warn "No git repo found"
fi

# ════════════════════════════════════════════════════════════════
section "5. Deploy frontend"
# ════════════════════════════════════════════════════════════════
if [ -n "$FRONTEND_DIR" ]; then
  cd "$FRONTEND_DIR" || exit 1
  [ ! -f ".env.production" ] && \
    echo "VITE_API_URL=https://grabr-production-fa32.up.railway.app" > .env.production
  if command -v vercel &>/dev/null; then
    vercel whoami &>/dev/null 2>&1 || vercel login
    vercel --prod --yes && pass "Vercel deployed" || warn "Run manually: vercel --prod"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "6. ACTION REQUIRED on Railway"
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${B}  Do these 3 things in Railway dashboard:${N}"
echo ""
echo "  ① API service → Variables → add:"
echo -e "    ${G}RUN_WORKER = true${N}"
echo ""
echo "  ② API service → Variables → confirm:"
echo -e "    ${G}BASE_URL = https://grabr-production-fa32.up.railway.app${N}"
echo -e "    ${G}DOWNLOAD_PATH = /tmp/downloads${N}"
echo -e "    ${G}CORS_ORIGIN = https://grab-wine.vercel.app${N}  (or leave blank — not needed anymore)"
echo ""
echo "  ③ API service → Redeploy"
echo "     (after ~2 min, test below)"
echo ""
echo -e "${B}  After redeploy, test CORS:${N}"
echo "  curl -I -X OPTIONS https://grabr-production-fa32.up.railway.app/api/download \\"
echo "    -H 'Origin: https://grab-wine.vercel.app' \\"
echo "    -H 'Access-Control-Request-Method: POST'"
echo "  # Must show: access-control-allow-origin: https://grab-wine.vercel.app"
echo ""
echo -e "${B}  Test SSE works:${N}"
echo "  curl -X POST https://grabr-production-fa32.up.railway.app/api/download \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"url\":\"https://youtu.be/dQw4w9WgXcQ\",\"format\":\"mp4\"}'"
echo "  # Get jobId, then:"
echo "  curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/JOB_ID"
echo "  # Must show: data: {\"status\":\"downloading\",\"percent\":12,...}"
echo ""
if [ $FAIL -eq 0 ]; then echo -e "${G}  ✓ All done!${N}"; else echo -e "${R}  ✗ $FAIL issue(s)${N}"; fi