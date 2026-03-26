#!/bin/bash

# ─────────────────────────────────────────────────────────────────
# fix-download-service.sh
# Diagnoses and auto-fixes the FORMAT_MAP + buildArgs in
# src/services/download.service.js
#
# Run from your project root:
#   bash fix-download-service.sh "https://youtube.com/watch?v=..."
# ─────────────────────────────────────────────────────────────────

PROJECT_DIR="$(pwd)"
SERVICE_FILE="$PROJECT_DIR/src/services/download.service.js"
YTDLP_BIN="${YTDLP_PATH:-$(which yt-dlp 2>/dev/null)}"
FFMPEG_BIN="${FFMPEG_PATH:-$(which ffmpeg 2>/dev/null)}"
TEST_URL="${1:-https://www.youtube.com/watch?v=dQw4w9WgXcQ}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "${GREEN}  ✓ $1${NC}"; }
fail() { echo -e "${RED}  ✗ $1${NC}"; }
warn() { echo -e "${YELLOW}  ! $1${NC}"; }
section() { echo -e "\n${CYAN}══════════════════════════════════════${NC}\n${CYAN}  $1${NC}\n${CYAN}══════════════════════════════════════${NC}"; }

# load .env cleanly (strip \r)
if [ -f "$PROJECT_DIR/.env" ]; then
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d '\r')
    val=$(echo "$val" | tr -d '\r')
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    export "$key=$val"
  done < "$PROJECT_DIR/.env"
  YTDLP_BIN="${YTDLP_PATH:-$YTDLP_BIN}"
  FFMPEG_BIN="${FFMPEG_PATH:-$FFMPEG_BIN}"
fi

# ── 1. CHECK BINARIES ─────────────────────────
section "1. Binary verification"
[ -z "$YTDLP_BIN" ]  && { fail "yt-dlp not found. Run: pip3 install yt-dlp"; exit 1; }
[ ! -f "$YTDLP_BIN" ] && { fail "YTDLP_PATH=$YTDLP_BIN does not exist"; exit 1; }
[ -z "$FFMPEG_BIN" ]  && { fail "ffmpeg not found. Run: sudo apt install ffmpeg -y"; exit 1; }
pass "yt-dlp  : $YTDLP_BIN ($(\"$YTDLP_BIN\" --version 2>/dev/null))"
pass "ffmpeg  : $FFMPEG_BIN"

# ── 2. PROBE VIDEO FORMATS ────────────────────
section "2. Probing available formats for URL"
echo "  URL: $TEST_URL"
echo ""

FORMATS=$("$YTDLP_BIN" --list-formats "$TEST_URL" 2>&1)
if echo "$FORMATS" | grep -q "ERROR"; then
  fail "Could not fetch formats:"
  echo "$FORMATS" | grep "ERROR"
  exit 1
fi

echo "$FORMATS" | grep -E "^[0-9]+" | head -30
echo ""

# Find best video+audio combo
HAS_MP4_VIDEO=$(echo "$FORMATS" | grep -E "^[0-9]+" | grep "mp4" | grep -v "audio only" | head -1)
HAS_M4A_AUDIO=$(echo "$FORMATS" | grep -E "^[0-9]+" | grep "m4a" | grep "audio only" | head -1)
HAS_WEBM_VIDEO=$(echo "$FORMATS" | grep -E "^[0-9]+" | grep "webm" | grep -v "audio only" | head -1)
HAS_ANY_AUDIO=$(echo "$FORMATS"  | grep -E "^[0-9]+" | grep "audio only" | head -1)

echo "  mp4 video stream  : ${HAS_MP4_VIDEO:-(none)}"
echo "  m4a audio stream  : ${HAS_M4A_AUDIO:-(none)}"
echo "  webm video stream : ${HAS_WEBM_VIDEO:-(none)}"
echo "  any audio stream  : ${HAS_ANY_AUDIO:-(none)}"

# Pick the right format selector for THIS video
if [ -n "$HAS_MP4_VIDEO" ] && [ -n "$HAS_M4A_AUDIO" ]; then
  BEST_FORMAT="bestvideo[ext=mp4]+bestaudio[ext=m4a]"
  pass "Will use: bestvideo[ext=mp4]+bestaudio[ext=m4a]"
elif [ -n "$HAS_MP4_VIDEO" ] && [ -n "$HAS_ANY_AUDIO" ]; then
  BEST_FORMAT="bestvideo[ext=mp4]+bestaudio"
  pass "Will use: bestvideo[ext=mp4]+bestaudio"
elif [ -n "$HAS_ANY_AUDIO" ]; then
  BEST_FORMAT="bestvideo+bestaudio"
  warn "No mp4 video — using: bestvideo+bestaudio (will merge to mp4)"
else
  BEST_FORMAT="best"
  warn "No separate audio stream — using: best (single stream)"
fi

# ── 3. LIVE DOWNLOAD TEST ─────────────────────
section "3. Live download test"
TEST_DIR=$(mktemp -d)
echo "  Format   : $BEST_FORMAT --merge-output-format mp4"
echo "  Output   : $TEST_DIR"
echo "  (downloading — this may take 30s...)"
echo ""

"$YTDLP_BIN" \
  -f "$BEST_FORMAT" \
  --merge-output-format mp4 \
  --no-playlist \
  --restrict-filenames \
  --ffmpeg-location "$FFMPEG_BIN" \
  -o "$TEST_DIR/test_%(title)s.%(ext)s" \
  "$TEST_URL" \
  > "$TEST_DIR/stdout.log" 2> "$TEST_DIR/stderr.log"

EXIT=$?
cat "$TEST_DIR/stdout.log" | grep -E "\[download\]|\[Merger\]|\[ffmpeg\]" | tail -10

if [ $EXIT -ne 0 ]; then
  fail "yt-dlp failed (exit $EXIT)"
  echo "  stderr: $(cat $TEST_DIR/stderr.log | tail -5)"
  rm -rf "$TEST_DIR"
  exit 1
fi

OUTPUT_MP4=$(ls "$TEST_DIR"/*.mp4 2>/dev/null | head -1)
OUTPUT_WEBM=$(ls "$TEST_DIR"/*.webm 2>/dev/null | head -1)
OUTPUT_ANY=$(ls "$TEST_DIR"/test_* 2>/dev/null | grep -v "\.log" | head -1)

if [ -n "$OUTPUT_MP4" ]; then
  SIZE=$(du -h "$OUTPUT_MP4" | cut -f1)
  pass "Output file: $(basename $OUTPUT_MP4) ($SIZE)"

  # Check audio stream
  AUDIO=$("$FFMPEG_BIN" -i "$OUTPUT_MP4" 2>&1 | grep "Audio:")
  if [ -n "$AUDIO" ]; then
    pass "Audio stream confirmed: $AUDIO"
    HAS_AUDIO_AND_MP4=true
  else
    fail "No audio stream in output file"
    HAS_AUDIO_AND_MP4=false
  fi
elif [ -n "$OUTPUT_WEBM" ]; then
  fail "Output is .webm — ffmpeg merge to mp4 failed"
  echo "  stderr: $(cat $TEST_DIR/stderr.log | tail -5)"
  HAS_AUDIO_AND_MP4=false
elif [ -n "$OUTPUT_ANY" ]; then
  warn "Output: $(basename $OUTPUT_ANY) — not mp4"
  HAS_AUDIO_AND_MP4=false
else
  fail "No output file produced"
  echo "  stdout: $(cat $TEST_DIR/stdout.log | tail -5)"
  rm -rf "$TEST_DIR"
  exit 1
fi

rm -rf "$TEST_DIR"

# ── 4. PATCH download.service.js ──────────────
section "4. Patching src/services/download.service.js"

if [ ! -f "$SERVICE_FILE" ]; then
  fail "File not found: $SERVICE_FILE"
  exit 1
fi

# Backup
cp "$SERVICE_FILE" "${SERVICE_FILE}.bak"
pass "Backup saved: ${SERVICE_FILE}.bak"

# Write the corrected file wholesale
cat > "$SERVICE_FILE" << 'JSEOF'
const { execFile } = require("child_process");
const path = require("path");
const fs = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// Each entry is an array — no string-splitting, no hidden space bugs.
const FORMAT_MAP = {
  mp4: [
    "-f", "bestvideo+bestaudio/best",
    "--merge-output-format", "mp4",
  ],
  mp3: [
    "-f", "bestaudio/best",
    "--extract-audio",
    "--audio-format", "mp3",
  ],
  webm: [
    "-f", "bestvideo+bestaudio/best",
    "--merge-output-format", "webm",
  ],
  m4a: [
    "-f", "bestaudio/best",
    "--extract-audio",
    "--audio-format", "m4a",
  ],
  "720p": [
    "-f", "bestvideo[height<=720]+bestaudio/best[height<=720]",
    "--merge-output-format", "mp4",
  ],
  "1080p": [
    "-f", "bestvideo[height<=1080]+bestaudio/best[height<=1080]",
    "--merge-output-format", "mp4",
  ],
  "480p": [
    "-f", "bestvideo[height<=480]+bestaudio/best[height<=480]",
    "--merge-output-format", "mp4",
  ],
  "360p": [
    "-f", "bestvideo[height<=360]+bestaudio/best[height<=360]",
    "--merge-output-format", "mp4",
  ],
  best: [
    "-f", "bestvideo+bestaudio/best",
    "--merge-output-format", "mp4",
  ],
};

/**
 * Builds a safe yt-dlp argument array. Uses execFile — no shell, no injection.
 */
function buildArgs(url, format, outputTemplate) {
  const ytdlpPath = process.env.YTDLP_PATH || "yt-dlp";
  const ffmpegPath = process.env.FFMPEG_PATH || "ffmpeg";
  const formatFlags = FORMAT_MAP[format] || FORMAT_MAP.best;

  return [
    ...formatFlags,
    "--no-playlist",
    "--restrict-filenames",
    "--max-filesize", `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout", "30",
    "--retries", "3",
    "--ffmpeg-location", ffmpegPath,
    "-o", outputTemplate,
    url,
  ];
}

/**
 * Executes a yt-dlp download and returns the output file path.
 */
async function runDownload(url, format, jobId) {
  const downloadDir = path.resolve(config.storage.downloadPath);

  if (!fs.existsSync(downloadDir)) {
    fs.mkdirSync(downloadDir, { recursive: true });
  }

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const ytdlpBin = process.env.YTDLP_PATH || "yt-dlp";
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.debug("Running yt-dlp", { jobId, bin: ytdlpBin, args });

  return new Promise((resolve, reject) => {
    const child = execFile(ytdlpBin, args, { timeout: 300_000 }, (err, stdout, stderr) => {
      if (err) {
        logger.error("yt-dlp failed", { jobId, stderr, code: err.code });
        return reject(new Error(stderr || err.message));
      }

      // Priority: merger output > ffmpeg output > download destination
      const mergeMatch  = stdout.match(/\[Merger\] Merging formats into "(.+?)"/);
      const ffmpegMatch = stdout.match(/\[ffmpeg\] Destination: (.+)/);
      const dlMatch     = stdout.match(/\[download\] Destination: (.+)/g);
      const lastDl      = dlMatch ? dlMatch[dlMatch.length - 1].replace("[download] Destination: ", "") : null;

      const rawPath = (mergeMatch && mergeMatch[1]) ||
                      (ffmpegMatch && ffmpegMatch[1]) ||
                      lastDl;

      if (!rawPath) {
        // Fallback: newest file with jobId prefix
        const files = fs.readdirSync(downloadDir)
          .filter((f) => f.startsWith(String(jobId)))
          .map((f) => ({ name: f, mtime: fs.statSync(path.join(downloadDir, f)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime);

        if (!files.length) {
          return reject(new Error("Download completed but output file not found"));
        }
        const filename = files[0].name;
        return resolve({ filePath: path.join(downloadDir, filename), filename });
      }

      const filePath = rawPath.trim();
      const filename = path.basename(filePath);
      resolve({ filePath, filename });
    });

    child.stdout.on("data", (d) => logger.debug("yt-dlp stdout", { jobId, data: d.trim() }));
    child.stderr.on("data", (d) => logger.debug("yt-dlp stderr", { jobId, data: d.trim() }));
  });
}

/**
 * Extracts video metadata without downloading.
 */
async function getMetadata(url) {
  const ytdlpBin = process.env.YTDLP_PATH || "yt-dlp";
  return new Promise((resolve, reject) => {
    execFile(ytdlpBin, ["--dump-json", "--no-playlist", url], (err, stdout) => {
      if (err) return reject(err);
      try {
        const data = JSON.parse(stdout);
        resolve({
          title: data.title,
          thumbnail: data.thumbnail,
          duration: data.duration,
          uploader: data.uploader,
          extractor: data.extractor,
        });
      } catch (e) {
        reject(new Error("Failed to parse metadata JSON"));
      }
    });
  });
}

/**
 * Removes files older than MAX_FILE_AGE_HOURS.
 */
function pruneOldFiles() {
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(downloadDir)) return;

  const maxAgeMs = config.storage.maxFileAgeHours * 60 * 60 * 1000;
  const now = Date.now();

  fs.readdirSync(downloadDir).forEach((file) => {
    const fullPath = path.join(downloadDir, file);
    try {
      const { mtimeMs } = fs.statSync(fullPath);
      if (now - mtimeMs > maxAgeMs) {
        fs.unlinkSync(fullPath);
        logger.info("Pruned old file", { file });
      }
    } catch (e) {
      logger.warn("Could not prune file", { file, error: e.message });
    }
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles };
JSEOF

pass "download.service.js rewritten"

# ── 5. VERIFY PATCH ───────────────────────────
section "5. Verifying patch"

DUP=$(grep -c "^  mp4:" "$SERVICE_FILE" 2>/dev/null || echo 0)
[ "$DUP" -gt 1 ] && fail "Still has duplicate mp4 key" || pass "No duplicate mp4 key"

grep -q "merge-output-format" "$SERVICE_FILE" \
  && pass "--merge-output-format present" \
  || fail "--merge-output-format MISSING"

grep -q "ffmpeg-location" "$SERVICE_FILE" \
  && pass "--ffmpeg-location present" \
  || fail "--ffmpeg-location MISSING"

grep -q 'FORMAT_MAP\[format\]' "$SERVICE_FILE" \
  && pass "FORMAT_MAP lookup correct" \
  || fail "FORMAT_MAP lookup missing"

grep -q 'process.env.YTDLP_PATH' "$SERVICE_FILE" \
  && pass "YTDLP_PATH from env" \
  || fail "YTDLP_PATH not read from env"

# ── 6. SUMMARY ────────────────────────────────
section "Done"
echo ""
echo "  download.service.js has been patched."
echo "  Backup: ${SERVICE_FILE}.bak"
echo ""
echo "  Restart your worker now:"
echo "    npm run worker"
echo ""
echo "  Then test:"
echo "    curl -X POST http://localhost:3000/api/download \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"url\":\"$TEST_URL\",\"format\":\"mp4\"}'"
echo ""