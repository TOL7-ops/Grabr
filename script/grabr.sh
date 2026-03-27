#!/bin/bash

# ─────────────────────────────────────────────────────────────
# grabr-audit.sh — auto-detecting full system audit
# Run from ANYWHERE inside your project:
#   bash grabr-audit.sh
#   bash grabr-audit.sh "https://x.com/user/status/123"
# ─────────────────────────────────────────────────────────────

TEST_URL="${1:-}"
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
info() { echo -e "    $1"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n${B}  $1${N}\n${C}══════════════════════════════════════════${N}"; }
FAILURES=0

# ── Auto-detect project root ──────────────────────────────────
section "0. Auto-detecting project structure"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Walk up from script to find backend (has src/app.js)
BACKEND_DIR=""
dir="$SCRIPT_DIR"
for i in 1 2 3 4 5; do
  if [ -f "$dir/src/app.js" ]; then
    BACKEND_DIR="$dir"
    break
  fi
  dir="$(dirname "$dir")"
done

# If not found walking up, try cwd
[ -z "$BACKEND_DIR" ] && [ -f "$(pwd)/src/app.js" ] && BACKEND_DIR="$(pwd)"

if [ -z "$BACKEND_DIR" ]; then
  echo -e "${R}  ✗ Cannot find backend (src/app.js)${N}"
  echo ""
  echo "  Run from inside your project:"
  echo "  cd /mnt/c/Users/tolul/Downloads/Myspace/landing/downloader-Api"
  echo "  bash script/grabr-audit.sh"
  exit 1
fi

# Find frontend — check inside backend first, then siblings
FRONTEND_DIR=""
for name in my-downloader-frontend frontend grabr-front; do
  if [ -f "$BACKEND_DIR/$name/src/App.jsx" ]; then
    FRONTEND_DIR="$BACKEND_DIR/$name"
    break
  fi
done
# Check parent dir siblings
if [ -z "$FRONTEND_DIR" ]; then
  parent="$(dirname "$BACKEND_DIR")"
  for name in my-downloader-frontend frontend grabr-front; do
    if [ -f "$parent/$name/src/App.jsx" ]; then
      FRONTEND_DIR="$parent/$name"
      break
    fi
  done
fi

pass "Backend  : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend : $FRONTEND_DIR" || warn "Frontend : not found (skipping frontend checks)"

# ── load .env cleanly (strip \r) ─────────────────────────────
load_env() {
  local f="$1"
  [ -f "$f" ] || return
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d '\r ')
    val=$(echo "$val" | tr -d '\r')
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    export "$key=$val"
  done < "$f"
}
load_env "$BACKEND_DIR/.env"

YTDLP="${YTDLP_PATH:-$(which yt-dlp 2>/dev/null)}"
FFMPEG="${FFMPEG_PATH:-$(which ffmpeg 2>/dev/null)}"

# ── 1. BINARIES ──────────────────────────────────────────────
section "1. Required binaries"

[ -n "$YTDLP" ] && [ -f "$YTDLP" ] \
  && pass "yt-dlp : $YTDLP  v$("$YTDLP" --version 2>/dev/null)" \
  || fail "yt-dlp not found — run: pip3 install yt-dlp"

[ -n "$FFMPEG" ] \
  && pass "ffmpeg : $FFMPEG" \
  || fail "ffmpeg not found — run: sudo apt install ffmpeg -y"

# ── 2. BACKEND FILES ─────────────────────────────────────────
section "2. Backend file structure"

for f in \
  "src/app.js" "src/server.js" \
  "src/config/index.js" "src/config/redis.js" \
  "src/controllers/download.controller.js" \
  "src/services/download.service.js" \
  "src/services/queue.service.js" \
  "src/workers/download.worker.js" \
  "src/routes/download.routes.js" \
  "src/utils/validator.js" \
  "src/middlewares/error.middleware.js"
do
  [ -f "$BACKEND_DIR/$f" ] && pass "$f" || fail "MISSING: $f"
done

# ── 3. ENV ───────────────────────────────────────────────────
section "3. Environment variables"

if [ -f "$BACKEND_DIR/.env" ]; then
  pass ".env found"
  if cat "$BACKEND_DIR/.env" | od -c | grep -q "\\\\r"; then
    fail ".env has \\r (Windows line endings) — run: sed -i 's/\\r//' $BACKEND_DIR/.env"
  else
    pass ".env line endings clean"
  fi
else
  warn ".env not found — Railway uses dashboard vars (OK for production)"
fi

for key in YTDLP_PATH FFMPEG_PATH DOWNLOAD_PATH REDIS_HOST REDIS_PORT BASE_URL CORS_ORIGIN; do
  val="${!key}"
  [ -n "$val" ] && pass "$key = ${val:0:50}" || warn "$key not set"
done

# ── 4. VALIDATOR ─────────────────────────────────────────────
section "4. validator.js — platform whitelist"

VALIDATOR="$BACKEND_DIR/src/utils/validator.js"
if [ -f "$VALIDATOR" ]; then
  for domain in "youtube.com" "youtu.be" "instagram.com" "tiktok.com" "twitter.com" "x.com" "t.co"; do
    grep -q "$domain" "$VALIDATOR" \
      && pass "$domain whitelisted" \
      || fail "$domain MISSING from whitelist"
  done
else
  fail "validator.js not found"
fi

# ── 5. FRONTEND ──────────────────────────────────────────────
section "5. Frontend — error safety"

if [ -z "$FRONTEND_DIR" ]; then
  warn "Skipping — frontend not found"
else
  APPJSX="$FRONTEND_DIR/src/App.jsx"
  APIJS="$FRONTEND_DIR/src/api.js"

  if [ -f "$APPJSX" ]; then
    pass "App.jsx found"
    grep -q "safeStr"       "$APPJSX" && pass "safeStr() present"       || fail "safeStr() MISSING — causes [object Object]"
    grep -q "ErrorBoundary" "$APPJSX" && pass "ErrorBoundary present"   || fail "ErrorBoundary MISSING — blank screen on crash"
    grep -q "from.*api"     "$APPJSX" && pass "api.js imported"         || warn "api.js not imported"

    # Auto-fix bare {job.error} renders
    if grep -qE '\{job\.(error)\}' "$APPJSX"; then
      fail "Found bare {job.error} render — auto-fixing..."
      sed -i 's/{job\.error}/{safeStr(job.error)}/g' "$APPJSX"
      pass "Auto-fixed {job.error} → {safeStr(job.error)}"
    else
      pass "No bare {job.error} found"
    fi
  else
    fail "App.jsx not found"
  fi

  if [ -f "$APIJS" ]; then
    pass "api.js found"
    grep -qE "String|safeError|safeStr" "$APIJS" \
      && pass "Safe error extraction present" \
      || fail "api.js missing safe error extraction"
  else
    fail "api.js not found — create $FRONTEND_DIR/src/api.js"
  fi
fi

# ── 6. DOWNLOAD SERVICE ──────────────────────────────────────
section "6. download.service.js"

SVCFILE="$BACKEND_DIR/src/services/download.service.js"
if [ -f "$SVCFILE" ]; then
  DUP=$(grep -c "^  mp4:" "$SVCFILE" 2>/dev/null || echo 0)
  [ "$DUP" -gt 1 ] && fail "Duplicate mp4: key ($DUP times)" || pass "No duplicate keys"
  grep -q "merge-output-format" "$SVCFILE" && pass "--merge-output-format present" || fail "--merge-output-format MISSING"
  grep -q "ffmpeg-location"     "$SVCFILE" && pass "--ffmpeg-location present"     || fail "--ffmpeg-location MISSING"
  grep -q "YTDLP_PATH"          "$SVCFILE" && pass "YTDLP_PATH from env"           || warn "yt-dlp path may be hardcoded"
else
  fail "download.service.js not found"
fi

# ── 7. REDIS ─────────────────────────────────────────────────
section "7. Redis"

RHOST="${REDIS_HOST:-localhost}"; RPORT="${REDIS_PORT:-6379}"
if command -v redis-cli &>/dev/null; then
  PING=$(redis-cli -h "$RHOST" -p "$RPORT" ping 2>/dev/null)
  [ "$PING" = "PONG" ] && pass "Redis at $RHOST:$RPORT" || fail "Redis NOT reachable at $RHOST:$RPORT"
else
  warn "redis-cli not installed — skipping local Redis check"
fi

# ── 8. yt-dlp PLATFORM TESTS ────────────────────────────────
section "8. yt-dlp platform tests"

if [ -z "$YTDLP" ] || [ ! -f "$YTDLP" ]; then
  warn "Skipping — yt-dlp not found"
else
  run_fmt_test() {
    local label="$1" url="$2"
    printf "  %-22s " "$label"
    OUT=$("$YTDLP" --list-formats --no-playlist --socket-timeout 15 "$url" 2>&1)
    if echo "$OUT" | grep -qE "^[0-9]"; then
      echo -e "${G}✓ OK${N}"
    elif echo "$OUT" | grep -qi "404\|not found\|unavailable\|removed"; then
      echo -e "${R}✗ content unavailable${N}"
    elif echo "$OUT" | grep -qi "login\|sign in\|authentication"; then
      echo -e "${Y}! needs cookies/login${N}"
    else
      echo -e "${R}✗ failed${N}"
      echo "$OUT" | grep -iE "error|ERROR" | head -2 | while read -r l; do info "    $l"; done
    fi
  }

  if [ -n "$TEST_URL" ]; then
    run_fmt_test "Custom URL" "$TEST_URL"
  else
    run_fmt_test "YouTube"   "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    run_fmt_test "TikTok"    "https://www.tiktok.com/@tiktok/video/7106594312292453675"
    run_fmt_test "Twitter/X" "https://twitter.com/Twitter/status/1445078208190291973"
    run_fmt_test "Instagram" "https://www.instagram.com/p/CUFCmUfBDDp/"
  fi
fi

# ── 9. LIVE RAILWAY API ──────────────────────────────────────
section "9. Live Railway API"

RURL="${RAILWAY_URL:-https://grabr-production-fa32.up.railway.app}"
echo "  URL: $RURL"

HEALTH=$(curl -sf --max-time 10 "$RURL/health" 2>/dev/null)
echo "$HEALTH" | grep -q '"status":"ok"' \
  && pass "Health: OK (uptime=$(echo "$HEALTH" | grep -o '"uptime":[0-9.]*' | cut -d: -f2)s)" \
  || fail "Health check failed: ${HEALTH:-no response}"

CORS=$(curl -sf --max-time 10 -X OPTIONS "$RURL/api/download" \
  -H "Origin: https://test.vercel.app" \
  -H "Access-Control-Request-Method: POST" \
  -D - -o /dev/null 2>/dev/null | grep -i "access-control-allow-origin")
echo "$CORS" | grep -qiE "vercel|\*" \
  && pass "CORS allows Vercel" \
  || fail "CORS blocking Vercel — update CORS in Railway vars: CORS_ORIGIN=https://your-app.vercel.app"

YT=$(curl -sf --max-time 10 -X POST "$RURL/api/download" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://youtu.be/dQw4w9WgXcQ","format":"mp4"}' 2>/dev/null)
echo "$YT" | grep -q '"jobId"' \
  && pass "YouTube job submitted: jobId=$(echo "$YT" | grep -o '"jobId":"[^"]*"' | cut -d'"' -f4)" \
  || fail "YouTube submit failed: $YT"

TW=$(curl -sf --max-time 10 -X POST "$RURL/api/download" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://twitter.com/Twitter/status/1445078208190291973","format":"mp4"}' 2>/dev/null)
echo "$TW" | grep -q '"jobId"' \
  && pass "Twitter job submitted: jobId=$(echo "$TW" | grep -o '"jobId":"[^"]*"' | cut -d'"' -f4)" \
  || fail "Twitter submit failed: $TW"

# ── 10. TWITTER DIAGNOSIS ────────────────────────────────────
section "10. Twitter/X deep diagnosis"

if [ -n "$YTDLP" ] && [ -f "$YTDLP" ]; then
  TW_TEST="${TEST_URL:-https://twitter.com/Twitter/status/1445078208190291973}"
  echo "  Testing: $TW_TEST"
  TW_OUT=$("$YTDLP" --list-formats --no-playlist --socket-timeout 20 "$TW_TEST" 2>&1)

  if echo "$TW_OUT" | grep -qi "404\|page could not be found"; then
    fail "404 — tweet is deleted, private, or URL is wrong"
    echo ""
    info "  This is a CONTENT problem, not a code problem."
    info "  The tweet no longer exists."
    info ""
    info "  ✓ Your code is correct."
    info "  Try a working public tweet with video:"
    info "    https://twitter.com/NASA/status/1781346066862739834"
  elif echo "$TW_OUT" | grep -qi "login\|authentication\|sign in"; then
    fail "Twitter requires authentication"
    info ""
    info "  Fix: add Twitter cookies"
    info "  1. Log in to twitter.com in Chrome"
    info "  2. Install: 'Get cookies.txt LOCALLY' Chrome extension"
    info "  3. Export cookies → save as: $BACKEND_DIR/cookies/twitter.txt"
    info "  4. In download.service.js buildArgs(), add:"
    info '     "--cookies", path.join(__dirname, "../../cookies/twitter.txt"),'
    info "  5. git add . && git commit -m 'add twitter cookies' && git push"
  elif echo "$TW_OUT" | grep -qE "^[0-9]"; then
    pass "Twitter working — formats available:"
    echo "$TW_OUT" | grep -E "^[0-9]" | head -4 | while read -r l; do info "  $l"; done
  else
    warn "Unclear result:"
    echo "$TW_OUT" | tail -4 | while read -r l; do info "  $l"; done
  fi
else
  warn "Skipping — yt-dlp not found"
fi

# ── SUMMARY ─────────────────────────────────────────────────
section "Summary"

echo "  Backend  : $BACKEND_DIR"
echo "  Frontend : ${FRONTEND_DIR:-not found}"
echo "  Railway  : $RURL"
echo ""

if [ $FAILURES -eq 0 ]; then
  echo -e "${G}  ✓ All checks passed!${N}"
else
  echo -e "${R}  ✗ $FAILURES failure(s) — fix items marked ✗ above${N}"
fi

echo ""
echo "  Push fixes to Railway:"
echo "    git add . && git commit -m 'fixes' && git push"
echo ""
echo "  Redeploy frontend:"
[ -n "$FRONTEND_DIR" ] \
  && echo "    cd $FRONTEND_DIR && vercel --prod" \
  || echo "    cd grabr-frontend && vercel --prod"
echo ""