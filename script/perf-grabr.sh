#!/bin/bash

URL="${1:-https://www.youtube.com/watch?v=dQw4w9WgXcQ}"

echo "══════════════════════════════════════════"
echo "   GRABR PERFORMANCE TRACE"
echo "══════════════════════════════════════════"
echo "URL: $URL"
echo ""

time_block() {
  LABEL=$1
  shift
  START=$(date +%s)

  OUTPUT=$("$@" 2>&1)
  EXIT_CODE=$?

  END=$(date +%s)
  DURATION=$((END - START))

  if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ $LABEL (${DURATION}s)"
  else
    echo "✗ $LABEL FAILED (${DURATION}s)"
    echo "$OUTPUT" | tail -5
  fi

  echo ""
}

# ─────────────────────────────────────────
# 1. DNS / Network latency
# ─────────────────────────────────────────
time_block "DNS + TCP connect" curl -o /dev/null -s -w "%{time_connect}s" "$URL"

# ─────────────────────────────────────────
# 2. yt-dlp metadata fetch
# ─────────────────────────────────────────
time_block "yt-dlp metadata" yt-dlp --dump-json --no-playlist "$URL" > /dev/null

# ─────────────────────────────────────────
# 3. format listing (platform stress)
# ─────────────────────────────────────────
time_block "yt-dlp list formats" yt-dlp --list-formats --no-playlist "$URL" > /dev/null

# ─────────────────────────────────────────
# 4. actual download (LIMITED)
# ─────────────────────────────────────────
echo "⚠ Running partial download (first 5MB)..."
START=$(date +%s)

yt-dlp \
  --no-playlist \
  --max-filesize 5M \
  --socket-timeout 15 \
  --retries 2 \
  -o "/tmp/test.%(ext)s" \
  "$URL" > /dev/null 2>&1

END=$(date +%s)
echo "Download test: $((END - START))s"
echo ""

# ─────────────────────────────────────────
# 5. ffmpeg merge test
# ─────────────────────────────────────────
echo "⚠ Testing ffmpeg speed..."

dd if=/dev/zero of=/tmp/test.mp4 bs=1M count=20 &>/dev/null

START=$(date +%s)
ffmpeg -y -i /tmp/test.mp4 -c copy /tmp/test_out.mp4 &>/dev/null
END=$(date +%s)

echo "ffmpeg copy: $((END - START))s"
echo ""

# ─────────────────────────────────────────
# 6. Railway API latency
# ─────────────────────────────────────────
API="${RAILWAY_URL:-https://grabr-production-fa32.up.railway.app}"

echo "Testing API: $API"

START=$(date +%s)

curl -s -X POST "$API/api/download" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$URL\",\"format\":\"mp4\"}" > /dev/null

END=$(date +%s)

echo "API submit time: $((END - START))s"
echo ""

echo "══════════════════════════════════════════"
echo "Done"
echo "══════════════════════════════════════════"