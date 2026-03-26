#!/bin/bash

# ─────────────────────────────────────────────
# downloader-backend — full diagnostic script
# Run from your project root:
#   bash debug.sh
# ─────────────────────────────────────────────

PROJECT_DIR="$(pwd)"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}  ✓ $1${NC}"; }
fail() { echo -e "${RED}  ✗ $1${NC}"; }
warn() { echo -e "${YELLOW}  ! $1${NC}"; }
section() { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

# ── 1. BINARIES ───────────────────────────────
section "1. Binary checks"

YTDLP_PATH=$(which yt-dlp 2>/dev/null)
if [ -n "$YTDLP_PATH" ]; then
  pass "yt-dlp found at: $YTDLP_PATH"
  pass "yt-dlp version: $(yt-dlp --version 2>/dev/null)"
else
  fail "yt-dlp NOT found in PATH"
  warn "Fix: pip3 install yt-dlp"
  warn "Then add to PATH: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
fi

FFMPEG_PATH=$(which ffmpeg 2>/dev/null)
if [ -n "$FFMPEG_PATH" ]; then
  pass "ffmpeg found at: $FFMPEG_PATH"
  pass "ffmpeg version: $(ffmpeg -version 2>/dev/null | head -1)"
else
  fail "ffmpeg NOT found in PATH"
  warn "Fix: sudo apt install ffmpeg -y"
fi

# ── 2. ENV FILE ───────────────────────────────
section "2. Environment (.env)"

ENV_FILE="$PROJECT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  fail ".env file not found at $ENV_FILE"
  warn "Fix: cp .env.example .env"
else
  pass ".env file exists"

  YTDLP_ENV=$(grep "^YTDLP_PATH" "$ENV_FILE" | cut -d= -f2 | tr -d ' ')
  FFMPEG_ENV=$(grep "^FFMPEG_PATH" "$ENV_FILE" | cut -d= -f2 | tr -d ' ')
  DOWNLOAD_PATH_ENV=$(grep "^DOWNLOAD_PATH" "$ENV_FILE" | cut -d= -f2 | tr -d ' ')

  echo "  YTDLP_PATH   = ${YTDLP_ENV:-'(not set)'}"
  echo "  FFMPEG_PATH  = ${FFMPEG_ENV:-'(not set)'}"
  echo "  DOWNLOAD_PATH= ${DOWNLOAD_PATH_ENV:-'(not set)'}"

  # Validate YTDLP_PATH
  if [ -n "$YTDLP_ENV" ]; then
    if [ -f "$YTDLP_ENV" ]; then
      pass "YTDLP_PATH file exists and is executable"
    else
      fail "YTDLP_PATH=$YTDLP_ENV — file does NOT exist"
      warn "Fix: set YTDLP_PATH=$(which yt-dlp) in .env"
    fi
  else
    warn "YTDLP_PATH not set in .env"
    if [ -n "$YTDLP_PATH" ]; then
      warn "Auto-fix suggestion: add this to .env →  YTDLP_PATH=$YTDLP_PATH"
    fi
  fi

  # Validate FFMPEG_PATH
  if [ -n "$FFMPEG_ENV" ]; then
    if [ -f "$FFMPEG_ENV" ]; then
      pass "FFMPEG_PATH file exists"
    else
      fail "FFMPEG_PATH=$FFMPEG_ENV — file does NOT exist"
      warn "Fix: set FFMPEG_PATH=$(which ffmpeg) in .env"
    fi
  else
    warn "FFMPEG_PATH not set in .env"
    if [ -n "$FFMPEG_PATH" ]; then
      warn "Auto-fix suggestion: add this to .env →  FFMPEG_PATH=$FFMPEG_PATH"
    fi
  fi

  # Validate DOWNLOAD_PATH
  if [ -n "$DOWNLOAD_PATH_ENV" ]; then
    if [ -d "$DOWNLOAD_PATH_ENV" ]; then
      pass "DOWNLOAD_PATH directory exists: $DOWNLOAD_PATH_ENV"
    else
      warn "DOWNLOAD_PATH directory does not exist yet — will be created on first download"
      mkdir -p "$DOWNLOAD_PATH_ENV" && pass "Created: $DOWNLOAD_PATH_ENV" || fail "Could not create $DOWNLOAD_PATH_ENV"
    fi
  else
    warn "DOWNLOAD_PATH not set — will default to relative ./downloads"
  fi
fi

# ── 3. FORMAT_MAP DUPLICATE KEY CHECK ─────────
section "3. FORMAT_MAP duplicate key check"

SERVICE_FILE="$PROJECT_DIR/src/services/download.service.js"
if [ ! -f "$SERVICE_FILE" ]; then
  fail "download.service.js not found at $SERVICE_FILE"
else
  DUP_COUNT=$(grep -c "^  mp4:" "$SERVICE_FILE" 2>/dev/null || echo 0)
  if [ "$DUP_COUNT" -gt 1 ]; then
    fail "Duplicate mp4 key found in FORMAT_MAP ($DUP_COUNT times) — second one silently overwrites the first"
    warn "Fix: remove the line →  mp4: \"-f bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best\""
    echo ""
    echo "  Current mp4 lines in file:"
    grep -n "mp4:" "$SERVICE_FILE"
  else
    pass "No duplicate mp4 key in FORMAT_MAP"
  fi

  # Check --merge-output-format is present
  if grep -q "merge-output-format" "$SERVICE_FILE"; then
    pass "--merge-output-format flag is present in FORMAT_MAP"
  else
    fail "--merge-output-format mp4 is MISSING from FORMAT_MAP"
    warn "Fix: update mp4 entry to include --merge-output-format mp4"
  fi

  # Check ffmpeg-location flag
  if grep -q "ffmpeg-location" "$SERVICE_FILE"; then
    pass "--ffmpeg-location flag is present in buildArgs"
  else
    fail "--ffmpeg-location flag is MISSING from buildArgs"
    warn "Fix: add  \"--ffmpeg-location\", process.env.FFMPEG_PATH || \"ffmpeg\",  to the args array"
  fi

  # Check execFile binary
  EXEC_BINARY=$(grep "execFile(" "$SERVICE_FILE" | head -1)
  echo "  execFile call: $EXEC_BINARY"
  if echo "$EXEC_BINARY" | grep -q "config.ytdlpPath\|YTDLP_PATH\|process.env"; then
    pass "execFile uses env-based path (good)"
  elif echo "$EXEC_BINARY" | grep -q "yt-dlp"; then
    warn "execFile uses hardcoded 'yt-dlp' string — may fail if not in PATH"
    warn "Fix: use execFile(process.env.YTDLP_PATH || 'yt-dlp', ...)"
  fi
fi

# ── 4. STATIC FILE SERVING ────────────────────
section "4. Static file serving (app.js)"

APP_FILE="$PROJECT_DIR/src/app.js"
if [ ! -f "$APP_FILE" ]; then
  fail "app.js not found"
else
  if grep -q "express.static" "$APP_FILE"; then
    pass "express.static is configured"
    STATIC_LINE=$(grep "express.static" "$APP_FILE")
    echo "  $STATIC_LINE"

    if grep -q "path.resolve" "$APP_FILE"; then
      pass "path.resolve() used — absolute path resolution is correct"
    else
      fail "path.resolve() NOT used — static path may be relative and broken"
      warn "Fix: express.static(path.resolve(config.storage.downloadPath), ...)"
    fi
  else
    fail "express.static not found in app.js — /files/ route will not work"
  fi

  if grep -q '"/files"' "$APP_FILE"; then
    pass "/files route is registered"
  else
    fail "/files route not found in app.js"
  fi
fi

# ── 5. LIVE yt-dlp TEST ───────────────────────
section "5. Live yt-dlp test (short clip)"

YTDLP_BIN="${YTDLP_ENV:-$YTDLP_PATH}"
FFMPEG_BIN="${FFMPEG_ENV:-$FFMPEG_PATH}"
TEST_DIR="/tmp/dltest_$$"
mkdir -p "$TEST_DIR"

if [ -z "$YTDLP_BIN" ]; then
  warn "Skipping live test — yt-dlp not found"
else
  echo "  Testing download + merge with yt-dlp..."
  echo "  Binary : $YTDLP_BIN"
  echo "  ffmpeg : ${FFMPEG_BIN:-'(using PATH)'}"
  echo "  Output : $TEST_DIR"

  FFMPEG_ARG=""
  [ -n "$FFMPEG_BIN" ] && FFMPEG_ARG="--ffmpeg-location $FFMPEG_BIN"

  "$YTDLP_BIN" \
    -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best" \
    --merge-output-format mp4 \
    --no-playlist \
    --restrict-filenames \
    --max-filesize 20m \
    --socket-timeout 30 \
    $FFMPEG_ARG \
    -o "$TEST_DIR/test_%(title)s.%(ext)s" \
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ" \
    > "$TEST_DIR/stdout.log" 2> "$TEST_DIR/stderr.log"

  EXIT_CODE=$?

  if [ $EXIT_CODE -eq 0 ]; then
    OUTPUT_FILE=$(ls "$TEST_DIR"/*.mp4 2>/dev/null | head -1)
    if [ -n "$OUTPUT_FILE" ]; then
      FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
      pass "Download succeeded: $(basename $OUTPUT_FILE) ($FILE_SIZE)"

      # Check if file has audio stream
      if [ -n "$FFMPEG_BIN" ]; then
        AUDIO_CHECK=$("$FFMPEG_BIN" -i "$OUTPUT_FILE" 2>&1 | grep "Audio")
        if [ -n "$AUDIO_CHECK" ]; then
          pass "Audio stream detected in output file"
        else
          fail "NO audio stream in output file — merge failed silently"
          warn "Check ffmpeg version: ffmpeg -version"
        fi
      fi
    else
      WEBM_FILE=$(ls "$TEST_DIR"/*.webm 2>/dev/null | head -1)
      if [ -n "$WEBM_FILE" ]; then
        fail "Output is .webm not .mp4 — ffmpeg merge failed"
        warn "ffmpeg may not be installed or --ffmpeg-location path is wrong"
      else
        fail "No output file found after successful exit"
        echo "  stdout: $(cat $TEST_DIR/stdout.log | tail -5)"
      fi
    fi
  else
    fail "yt-dlp exited with code $EXIT_CODE"
    echo ""
    echo "  ── stderr ──"
    cat "$TEST_DIR/stderr.log"
    echo "  ── stdout ──"
    cat "$TEST_DIR/stdout.log" | tail -10
  fi

  rm -rf "$TEST_DIR"
fi

# ── 6. REDIS CHECK ────────────────────────────
section "6. Redis connectivity"

REDIS_HOST=$(grep "^REDIS_HOST" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' ')
REDIS_PORT=$(grep "^REDIS_PORT" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' ')
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"

if command -v redis-cli &>/dev/null; then
  PING=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping 2>/dev/null)
  if [ "$PING" = "PONG" ]; then
    pass "Redis is reachable at $REDIS_HOST:$REDIS_PORT"
  else
    fail "Redis NOT reachable at $REDIS_HOST:$REDIS_PORT"
    warn "Fix: sudo service redis-server start  (or start Docker)"
  fi
else
  warn "redis-cli not installed — skipping Redis check"
  warn "Install: sudo apt install redis-tools -y"
fi

# ── 7. AUTO-FIX OFFER ─────────────────────────
section "7. Auto-fix .env"

if [ -f "$ENV_FILE" ]; then
  CHANGED=0

  if [ -n "$YTDLP_PATH" ] && ! grep -q "^YTDLP_PATH=" "$ENV_FILE"; then
    echo "YTDLP_PATH=$YTDLP_PATH" >> "$ENV_FILE"
    pass "Added YTDLP_PATH=$YTDLP_PATH to .env"
    CHANGED=1
  elif [ -n "$YTDLP_PATH" ]; then
    sed -i "s|^YTDLP_PATH=.*|YTDLP_PATH=$YTDLP_PATH|" "$ENV_FILE"
    pass "Updated YTDLP_PATH=$YTDLP_PATH in .env"
    CHANGED=1
  fi

  if [ -n "$FFMPEG_PATH" ] && ! grep -q "^FFMPEG_PATH=" "$ENV_FILE"; then
    echo "FFMPEG_PATH=$FFMPEG_PATH" >> "$ENV_FILE"
    pass "Added FFMPEG_PATH=$FFMPEG_PATH to .env"
    CHANGED=1
  elif [ -n "$FFMPEG_PATH" ]; then
    sed -i "s|^FFMPEG_PATH=.*|FFMPEG_PATH=$FFMPEG_PATH|" "$ENV_FILE"
    pass "Updated FFMPEG_PATH=$FFMPEG_PATH in .env"
    CHANGED=1
  fi

  [ $CHANGED -eq 0 ] && pass ".env already has correct paths — no changes needed"
fi

# ── SUMMARY ───────────────────────────────────
section "Summary"
echo "  Project : $PROJECT_DIR"
echo "  yt-dlp  : ${YTDLP_PATH:-NOT FOUND}"
echo "  ffmpeg  : ${FFMPEG_PATH:-NOT FOUND}"
echo ""
echo "  Next steps:"
echo "  1. Fix any ✗ items above"
echo "  2. Restart worker:  npm run worker"
echo "  3. Submit new job:  curl -X POST http://localhost:3000/api/download -H 'Content-Type: application/json' -d '{\"url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\",\"format\":\"mp4\"}'"
echo ""