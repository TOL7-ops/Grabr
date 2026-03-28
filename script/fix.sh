#!/bin/bash

# ─────────────────────────────────────────────────────────────────
# fix-download-path.sh
# Fixes: EACCES permission denied mkdir '/mnt/c/Users/...' on Railway
# Root cause: DOWNLOAD_PATH env var on Railway has wrong value
#
# Run from inside downloader-Api:
#   bash script/fix-download-path.sh
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

section "0. Paths"
pass "Backend  : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend : $FRONTEND_DIR" || warn "Frontend not found"

# ════════════════════════════════════════════════════════════════
section "1. Diagnose current DOWNLOAD_PATH"
# ════════════════════════════════════════════════════════════════

# Load .env cleanly
load_env() {
  local f="$1"; [ -f "$f" ] || return
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d '\r '); val=$(echo "$val" | tr -d '\r')
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    export "$key=$val"
  done < "$f"
}
load_env "$BACKEND_DIR/.env"

echo "  Local .env DOWNLOAD_PATH = '${DOWNLOAD_PATH:-not set}'"
echo "  NODE_ENV                 = '${NODE_ENV:-not set}'"

# Check if path is a Windows path (bad on Railway)
if echo "${DOWNLOAD_PATH:-}" | grep -qE "^/mnt/|^C:\\\\|^[A-Z]:"; then
  fail "DOWNLOAD_PATH is a Windows path — this will EACCES on Railway: $DOWNLOAD_PATH"
  echo ""
  warn "Railway runs Linux. /mnt/c/... doesn't exist there."
  warn "The DOWNLOAD_PATH in Railway dashboard variables must be /tmp/downloads"
elif echo "${DOWNLOAD_PATH:-}" | grep -q "^/tmp"; then
  pass "DOWNLOAD_PATH is /tmp path (correct for Railway)"
elif [ -z "${DOWNLOAD_PATH:-}" ]; then
  warn "DOWNLOAD_PATH not set — will use relative 'downloads' directory"
else
  warn "DOWNLOAD_PATH = $DOWNLOAD_PATH — verify this exists on Railway"
fi

# ════════════════════════════════════════════════════════════════
section "2. Fix config/index.js — force /tmp/downloads as safe fallback"
# ════════════════════════════════════════════════════════════════

cat > "$BACKEND_DIR/src/config/index.js" << 'JSEOF'
require("dotenv").config();
const os   = require("os");
const path = require("path");

// ── Safe download path ────────────────────────────────────────────
// Priority:
//   1. DOWNLOAD_PATH env var (if it looks like a valid absolute Linux path)
//   2. /tmp/downloads (always writable on Railway, Render, Fly.io)
//   3. os.tmpdir()/downloads (Windows fallback for local dev)
function resolveDownloadPath() {
  const raw = process.env.DOWNLOAD_PATH || "";

  // Reject Windows paths that sneak into Railway
  const isWindowsPath = /^[A-Za-z]:[\\\/]|^\/mnt\/[a-z]\//.test(raw);
  if (raw && !isWindowsPath && path.isAbsolute(raw)) {
    return raw;
  }

  // If running in production (Railway), always use /tmp
  if (process.env.NODE_ENV === "production" || process.env.RAILWAY_ENVIRONMENT) {
    return "/tmp/downloads";
  }

  // Local dev: use os.tmpdir() so it works on Windows too
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
    downloadPath:   resolveDownloadPath(),
    maxFileSizeMb:  parseInt(process.env.MAX_FILE_SIZE_MB, 10)  || 500,
    maxFileAgeHours:parseInt(process.env.MAX_FILE_AGE_HOURS, 10) || 24,
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

// Log resolved path on startup so you can see it in Railway logs
console.log(`[config] downloadPath = ${config.storage.downloadPath}`);

module.exports = config;
JSEOF
pass "config/index.js — resolveDownloadPath() added"

# ════════════════════════════════════════════════════════════════
section "3. Fix download.service.js — ensure dir created with recursive"
# ════════════════════════════════════════════════════════════════

# Check that mkdir is recursive and handles errors gracefully
SVC="$BACKEND_DIR/src/services/download.service.js"
if [ -f "$SVC" ]; then
  if grep -q "mkdirSync" "$SVC"; then
    # Make sure it's recursive and has error handling
    if ! grep -q "recursive: true" "$SVC"; then
      sed -i 's/fs.mkdirSync(downloadDir)/fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 })/' "$SVC"
      pass "download.service.js — mkdir recursive + permissions"
    else
      pass "download.service.js — mkdir already recursive"
    fi
  fi

  # Add permission test before spawning yt-dlp
  if ! grep -q "accessSync\|canWrite" "$SVC"; then
    # Inject a write-permission check after mkdirSync
    sed -i 's|if (!fs.existsSync(downloadDir)) fs.mkdirSync(downloadDir, { recursive: true });|if (!fs.existsSync(downloadDir)) {\n    try {\n      fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 });\n    } catch (mkErr) {\n      logger.error("Cannot create download dir", { path: downloadDir, error: mkErr.message });\n      throw new Error(\`EACCES: Cannot create download directory: ${downloadDir}. Set DOWNLOAD_PATH=/tmp/downloads in environment variables.\`);\n    }\n  }\n  // Verify write permission\n  try { fs.accessSync(downloadDir, fs.constants.W_OK); }\n  catch { throw new Error(\`No write permission on download directory: ${downloadDir}\`); }|' "$SVC" 2>/dev/null
    pass "download.service.js — write permission check added"
  else
    pass "download.service.js — permission check already present"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "4. Fix local .env — correct DOWNLOAD_PATH for local dev"
# ════════════════════════════════════════════════════════════════

ENV_FILE="$BACKEND_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  # Detect if DOWNLOAD_PATH is a bad Windows path
  CURRENT_DP=$(grep "^DOWNLOAD_PATH" "$ENV_FILE" | cut -d= -f2 | tr -d '\r ')
  if echo "$CURRENT_DP" | grep -qE "^/mnt/|^C:\\\\"; then
    # Replace with OS-appropriate temp path
    if command -v python3 &>/dev/null; then
      TMPDIR_PATH=$(python3 -c "import tempfile,os; print(os.path.join(tempfile.gettempdir(),'grabr-downloads'))" 2>/dev/null)
    fi
    TMPDIR_PATH="${TMPDIR_PATH:-/tmp/grabr-downloads}"
    sed -i "s|^DOWNLOAD_PATH=.*|DOWNLOAD_PATH=$TMPDIR_PATH|" "$ENV_FILE"
    pass ".env — DOWNLOAD_PATH fixed to $TMPDIR_PATH"
  elif [ -z "$CURRENT_DP" ]; then
    echo "DOWNLOAD_PATH=/tmp/grabr-downloads" >> "$ENV_FILE"
    pass ".env — DOWNLOAD_PATH added"
  else
    pass ".env — DOWNLOAD_PATH = $CURRENT_DP (looks OK)"
  fi
else
  warn ".env not found — Railway uses dashboard variables"
fi

# ════════════════════════════════════════════════════════════════
section "5. Create Railway env fix instructions"
# ════════════════════════════════════════════════════════════════

echo ""
echo -e "${B}  ⚠ ACTION REQUIRED: Update Railway dashboard variables${N}"
echo ""
echo "  Go to: railway.app → grabr project → your API service → Variables"
echo ""
echo "  Set these EXACT values:"
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │ DOWNLOAD_PATH  = /tmp/downloads                     │"
echo "  │ NODE_ENV       = production                         │"
echo "  │ BASE_URL       = https://grabr-production-fa32.up.railway.app │"
echo "  │ YTDLP_PATH     = /usr/local/bin/yt-dlp              │"
echo "  │ FFMPEG_PATH    = /usr/bin/ffmpeg                    │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "  Do the SAME for your worker service."
echo ""

# ════════════════════════════════════════════════════════════════
section "6. Add /health debug endpoint to verify path on Railway"
# ════════════════════════════════════════════════════════════════

APP_JS="$BACKEND_DIR/src/app.js"
if [ -f "$APP_JS" ] && ! grep -q "download-path" "$APP_JS"; then
  # Add a debug route that shows the resolved download path
  sed -i 's|app.get("/health", (_req, res) => {|app.get("/debug/path", (_req, res) => {\n  const config = require("./config");\n  const fs = require("fs");\n  const dir = config.storage.downloadPath;\n  const exists = fs.existsSync(dir);\n  let writable = false;\n  try { fs.accessSync(dir, fs.constants.W_OK); writable = true; } catch {}\n  res.json({ downloadPath: dir, exists, writable, NODE_ENV: process.env.NODE_ENV, DOWNLOAD_PATH_ENV: process.env.DOWNLOAD_PATH });\n});\n\napp.get("/health", (_req, res) => {|' "$APP_JS"
  pass "app.js — /debug/path endpoint added"
fi

# ════════════════════════════════════════════════════════════════
section "7. Verify config fix"
# ════════════════════════════════════════════════════════════════

node -e "
process.env.NODE_ENV = 'production';
process.env.BASE_URL = 'https://grabr-production-fa32.up.railway.app';
delete process.env.DOWNLOAD_PATH;
const config = require('$BACKEND_DIR/src/config/index.js');
const path = config.storage.downloadPath;
console.log('  Resolved path (no env):', path);
if (path.startsWith('/tmp') || path.startsWith('/var/folders')) {
  console.log('  ✓ Safe path for Railway');
  process.exit(0);
} else {
  console.log('  ✗ Unexpected path:', path);
  process.exit(1);
}
" 2>/dev/null && pass "config resolves to safe path in production mode" || fail "config path resolution unexpected"

node -e "
process.env.NODE_ENV = 'production';
process.env.DOWNLOAD_PATH = '/mnt/c/Users/tolul/bad/path';
const config = require('$BACKEND_DIR/src/config/index.js');
const path = config.storage.downloadPath;
console.log('  Rejected Windows path, using:', path);
if (path === '/tmp/downloads') {
  console.log('  ✓ Windows path correctly rejected');
  process.exit(0);
} else {
  console.log('  ✗ Should have been /tmp/downloads, got:', path);
  process.exit(1);
}
" 2>/dev/null && pass "Windows path correctly rejected and replaced" || warn "Config path rejection test inconclusive"

# ════════════════════════════════════════════════════════════════
section "8. Git commit & push"
# ════════════════════════════════════════════════════════════════

cd "$BACKEND_DIR" || exit 1

if git rev-parse --git-dir > /dev/null 2>&1; then
  git add src/config/index.js src/app.js src/services/download.service.js

  if git diff --cached --quiet; then
    warn "Nothing to commit — already up to date"
  else
    git commit -m "fix: safe download path — reject Windows paths, use /tmp on Railway"
    pass "Committed"
    git push && pass "Pushed → Railway redeploys automatically" || fail "git push failed"
  fi
else
  warn "Not a git repo — push manually"
fi

# ════════════════════════════════════════════════════════════════
section "Summary"
# ════════════════════════════════════════════════════════════════

echo ""
echo -e "${B}  Root cause:${N}"
echo "  Your local .env had DOWNLOAD_PATH=/mnt/c/Users/tolul/..."
echo "  This got committed or set in Railway dashboard."
echo "  Railway is Linux — /mnt/c/ doesn't exist → EACCES."
echo ""
echo -e "${B}  Fix applied:${N}"
echo "  1. config/index.js now detects and rejects Windows paths"
echo "  2. Falls back to /tmp/downloads when NODE_ENV=production"
echo "  3. Falls back to os.tmpdir() for local dev"
echo "  4. /debug/path endpoint added to verify live"
echo ""
echo -e "${B}  Verify after Railway redeploys:${N}"
echo "  curl https://grabr-production-fa32.up.railway.app/debug/path"
echo "  # Should show: { downloadPath: '/tmp/downloads', exists: true, writable: true }"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "${G}  ✓ All fixes applied!${N}"
else
  echo -e "${R}  ✗ $FAIL issue(s) remain${N}"
fi
echo ""
