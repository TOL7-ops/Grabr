#!/bin/bash

# ─────────────────────────────────────────────────────────────────
# fix-railway-deps.sh
# Fixes:
#   1. ffmpeg not found on Railway PATH
#   2. yt-dlp missing JS runtime (needs node.js runtime)
#   3. YouTube bot detection (cookies from browser)
#   4. /tmp/downloads not writable (exists: false)
#
# Run from inside downloader-Api:
#   bash script/fix-railway-deps.sh
# ─────────────────────────────────────────────────────────────────

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n${B}  $1${N}\n${C}══════════════════════════════════════════${N}"; }
FAIL=0

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
pass "Backend : $BACKEND_DIR"

# ════════════════════════════════════════════════════════════════
section "1. FIX: Dockerfile — ffmpeg + node JS runtime + /tmp writability"
# ════════════════════════════════════════════════════════════════

cat > "$BACKEND_DIR/Dockerfile" << 'DEOF'
# ── Base image ────────────────────────────────────────────────────
# Use full node (not slim) so Node.js is available as yt-dlp JS runtime
FROM node:20 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production

# ── System deps ───────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    ffmpeg \
    curl \
    ca-certificates \
    wget \
    && rm -rf /var/lib/apt/lists/*

# ── Verify ffmpeg ─────────────────────────────────────────────────
RUN ffmpeg -version | head -1 && which ffmpeg

# ── Install yt-dlp (latest) ───────────────────────────────────────
# Use binary install instead of pip — more reliable, always latest
RUN wget -q "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" \
    -O /usr/local/bin/yt-dlp \
    && chmod a+rx /usr/local/bin/yt-dlp \
    && yt-dlp --version

# ── Tell yt-dlp to use Node.js as JS runtime ─────────────────────
# This fixes: "No supported JavaScript runtime could be found"
ENV YT_DLP_JS_RUNTIME=nodejs

# ── Create writable download directory ───────────────────────────
# /tmp is always writable — create subdir and set permissions
RUN mkdir -p /tmp/downloads && chmod 777 /tmp/downloads

# ── App setup ─────────────────────────────────────────────────────
WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY src/ ./src/

# Create logs dir (app dir is writable as root during build)
RUN mkdir -p logs

# ── Environment defaults ──────────────────────────────────────────
ENV YTDLP_PATH=/usr/local/bin/yt-dlp \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    DOWNLOAD_PATH=/tmp/downloads \
    PORT=3000

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]

# ── Worker stage ──────────────────────────────────────────────────
FROM base AS worker
CMD ["node", "src/workers/download.worker.js"]
DEOF
pass "Dockerfile — ffmpeg verified, yt-dlp binary, Node.js runtime, /tmp/downloads"

# ════════════════════════════════════════════════════════════════
section "2. FIX: download.service.js — pass --extractor-args for Node runtime"
# ════════════════════════════════════════════════════════════════

SVC="$BACKEND_DIR/src/services/download.service.js"
if [ -f "$SVC" ]; then
  # Check if js-runtimes flag already added
  if grep -q "js-runtimes\|extractor-args" "$SVC"; then
    pass "download.service.js — JS runtime args already present"
  else
    # Add --js-runtimes nodejs to buildArgs
    sed -i 's|"--no-playlist",|"--no-playlist",\n    "--js-runtimes", "nodejs",|' "$SVC" 2>/dev/null
    pass "download.service.js — --js-runtimes nodejs added"
  fi

  # Fix YTDLP_PATH and FFMPEG_PATH — use ENV defaults set in Dockerfile
  if grep -q "YTDLP_PATH.*||.*yt-dlp" "$SVC"; then
    pass "download.service.js — YTDLP_PATH fallback present"
  fi
  if grep -q "FFMPEG_PATH.*||.*ffmpeg" "$SVC"; then
    pass "download.service.js — FFMPEG_PATH fallback present"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "3. FIX: YouTube bot detection — PO token + cookies setup"
# ════════════════════════════════════════════════════════════════

# Create cookies directory
mkdir -p "$BACKEND_DIR/cookies"

# Create placeholder cookies file with instructions
cat > "$BACKEND_DIR/cookies/README.md" << 'EOF'
# YouTube Cookies

YouTube now requires authentication to download some videos on server IPs.

## How to export cookies:

1. Install Chrome extension: "Get cookies.txt LOCALLY"
   https://chrome.google.com/webstore/detail/get-cookiestxt-locally/

2. Go to https://www.youtube.com and make sure you're logged in

3. Click the extension → export cookies for youtube.com

4. Save the file as: cookies/youtube.txt

5. Commit and push — Railway will include it in the build

## Alternative: Use yt-dlp PO Token

See: https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies
EOF

# Create a yt-dlp config file that Railway will use
cat > "$BACKEND_DIR/yt-dlp.conf" << 'EOF'
# yt-dlp configuration for Railway deployment
# This file is read automatically by yt-dlp

# Use Node.js as JS runtime (fixes "No supported JavaScript runtime" error)
--js-runtimes nodejs

# Retry settings for server environments
--retries 5
--fragment-retries 5
--socket-timeout 60

# Performance
--concurrent-fragments 4
--no-cache-dir
--no-part

# If cookies/youtube.txt exists, use it
EOF

# Check if cookies file exists and add to conf if so
if [ -f "$BACKEND_DIR/cookies/youtube.txt" ]; then
  echo "--cookies /app/cookies/youtube.txt" >> "$BACKEND_DIR/yt-dlp.conf"
  pass "cookies/youtube.txt found — added to yt-dlp.conf"
else
  warn "cookies/youtube.txt not found — YouTube may block some downloads"
  warn "Export from Chrome and save as cookies/youtube.txt"
  echo "# --cookies /app/cookies/youtube.txt  ← uncomment after adding cookies" >> "$BACKEND_DIR/yt-dlp.conf"
fi

pass "yt-dlp.conf created"

# Update Dockerfile to copy yt-dlp.conf and cookies
if ! grep -q "yt-dlp.conf" "$BACKEND_DIR/Dockerfile"; then
  # Add COPY for conf and cookies before CMD
  sed -i 's|COPY src/ ./src/|COPY src/ ./src/\nCOPY yt-dlp.conf /root/.config/yt-dlp/config\nCOPY cookies/ /app/cookies/ 2>/dev/null \|\| true|' "$BACKEND_DIR/Dockerfile" 2>/dev/null
  pass "Dockerfile — yt-dlp.conf copied to /root/.config/yt-dlp/config"
fi

# ════════════════════════════════════════════════════════════════
section "4. FIX: download.service.js — use yt-dlp.conf and fix path defaults"
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
function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) { logger.warn("SSE write failed", { jobId, error: e.message }); unregisterSSE(jobId); }
}

// ── Resolve binaries ─────────────────────────────────────────────
// Dockerfile sets these as ENV defaults — never empty on Railway
function getBin(envKey, fallback) {
  const val = process.env[envKey] || fallback;
  // Verify it exists
  if (fs.existsSync(val)) return val;
  // Try which
  try {
    const { execSync } = require("child_process");
    const found = execSync(`which ${fallback} 2>/dev/null`, { encoding: "utf8" }).trim();
    if (found) return found;
  } catch {}
  return val; // return anyway — let yt-dlp fail with a clear error
}

const YTDLP_BIN  = getBin("YTDLP_PATH",  "/usr/local/bin/yt-dlp");
const FFMPEG_BIN = getBin("FFMPEG_PATH",  "/usr/bin/ffmpeg");

logger.info("Binaries resolved", { ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN });

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
  const cookiesPath = "/app/cookies/youtube.txt";
  const cookiesArgs = fs.existsSync(cookiesPath)
    ? ["--cookies", cookiesPath]
    : [];

  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist",
    "--restrict-filenames",
    "--js-runtimes",          "nodejs",          // fix: No JS runtime error
    "--max-filesize",         `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout",       "60",
    "--retries",              "5",
    "--fragment-retries",     "5",
    "--concurrent-fragments", "4",
    "--no-cache-dir",
    "--no-part",
    "--newline",
    "--ffmpeg-location",      FFMPEG_BIN,
    ...cookiesArgs,
    "-o",                     outputTemplate,
    url,
  ];
}

// ── Progress parsers ─────────────────────────────────────────────
const RE_PROGRESS = /\[download\]\s+([\d.]+)%\s+of\s+([\d.]+\S+)\s+at\s+([\S]+)\s+ETA\s+([\S]+)/;
const RE_MERGE    = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG   = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST     = /\[download\] Destination:\s+(.+)/;

// ── runDownload ──────────────────────────────────────────────────
async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);

  // Ensure directory exists and is writable
  if (!fs.existsSync(downloadDir)) {
    try {
      fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 });
      logger.info("Created download dir", { path: downloadDir });
    } catch (mkErr) {
      const msg = `Cannot create download directory: ${downloadDir} — ${mkErr.message}. Set DOWNLOAD_PATH=/tmp/downloads`;
      logger.error(msg);
      throw new Error(msg);
    }
  }

  // Write permission check
  try { fs.accessSync(downloadDir, fs.constants.W_OK); }
  catch { throw new Error(`No write permission on: ${downloadDir} — Set DOWNLOAD_PATH=/tmp/downloads`); }

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.info("Spawning yt-dlp", { jobId, format, bin: YTDLP_BIN, ffmpeg: FFMPEG_BIN, dir: downloadDir });

  const emit = (data) => {
    sendProgress(jobId, data);
    onProgress && onProgress(data);
  };

  emit({ status: "starting", percent: 0 });

  const start = Date.now();
  let outputPath = null, stdoutBuf = "", stderrBuf = "", lastPct = 0, phase = "downloading";

  return new Promise((resolve, reject) => {
    const child = spawn(YTDLP_BIN, args, {
      env: { ...process.env, PYTHONUNBUFFERED: "1", NODE_PATH: process.execPath },
    });

    child.stdout.on("data", (chunk) => {
      stdoutBuf += chunk.toString();
      const lines = stdoutBuf.split("\n");
      stdoutBuf = lines.pop();

      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;
        logger.debug("yt-dlp", { jobId, line });

        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          emit({ status: "processing", percent: 99 });
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
            emit({ status: "downloading", percent: Math.min(percent, 98), size: pM[2], speed: pM[3], eta: pM[4] });
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
        logger.error("yt-dlp error", { jobId, msg });
        emit({ status: "error", message: msg });
        return reject(new Error(msg));
      }

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

      const filename  = path.basename(outputPath);
      const baseUrl   = config.baseUrl.replace(/\/$/, "");
      const fileUrl   = `${baseUrl}/files/${encodeURIComponent(filename)}`;
      const ext       = path.extname(filename).toLowerCase().replace(".", "");
      const mediaType = ["mp4","webm","mkv","mov"].includes(ext) ? "video"
                      : ["mp3","m4a","ogg","wav","opus"].includes(ext) ? "audio"
                      : "file";

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
  return new Promise((resolve, reject) => {
    execFile(YTDLP_BIN, ["--dump-json", "--no-playlist", "--js-runtimes", "nodejs", url], { timeout: 30_000 }, (err, stdout) => {
      if (err) return reject(err);
      try {
        const d = JSON.parse(stdout);
        resolve({ title: d.title, thumbnail: d.thumbnail, duration: d.duration, uploader: d.uploader, extractor: d.extractor });
      } catch { reject(new Error("Failed to parse metadata")); }
    });
  });
}

// ── Pruner ───────────────────────────────────────────────────────
function pruneOldFiles() {
  const dir = config.storage.downloadPath;
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
pass "download.service.js — full rewrite with binary resolution + cookies"

# ════════════════════════════════════════════════════════════════
section "5. FIX: Dockerfile — copy yt-dlp.conf correctly"
# ════════════════════════════════════════════════════════════════

cat > "$BACKEND_DIR/Dockerfile" << 'DEOF'
FROM node:20 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production \
    YTDLP_PATH=/usr/local/bin/yt-dlp \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    DOWNLOAD_PATH=/tmp/downloads \
    PORT=3000

# ── System deps ───────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    ffmpeg \
    curl \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Verify ffmpeg path ────────────────────────────────────────────
RUN which ffmpeg && ffmpeg -version 2>&1 | head -1

# ── Install yt-dlp binary (latest release) ───────────────────────
RUN wget -q "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" \
    -O /usr/local/bin/yt-dlp \
    && chmod a+rx /usr/local/bin/yt-dlp \
    && yt-dlp --version

# ── Create yt-dlp config dir ─────────────────────────────────────
RUN mkdir -p /root/.config/yt-dlp /tmp/downloads /app/cookies \
    && chmod 777 /tmp/downloads

# ── Write yt-dlp config (Node.js as JS runtime) ───────────────────
RUN echo '--js-runtimes nodejs' > /root/.config/yt-dlp/config \
    && echo '--retries 5'       >> /root/.config/yt-dlp/config \
    && echo '--socket-timeout 60' >> /root/.config/yt-dlp/config \
    && echo '--no-cache-dir'    >> /root/.config/yt-dlp/config

# ── App setup ─────────────────────────────────────────────────────
WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY src/ ./src/
COPY cookies/ ./cookies/

RUN mkdir -p logs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]

# ── Worker stage ──────────────────────────────────────────────────
FROM base AS worker
CMD ["node", "src/workers/download.worker.js"]
DEOF
pass "Dockerfile — final version with all fixes"

# ════════════════════════════════════════════════════════════════
section "6. Create .dockerignore update"
# ════════════════════════════════════════════════════════════════

# Make sure cookies dir is NOT ignored
if [ -f "$BACKEND_DIR/.dockerignore" ]; then
  # Remove cookies from dockerignore if present
  sed -i '/^cookies/d' "$BACKEND_DIR/.dockerignore"
  pass ".dockerignore — cookies/ not ignored"
fi

# ════════════════════════════════════════════════════════════════
section "7. Print YouTube cookies instructions"
# ════════════════════════════════════════════════════════════════

echo ""
echo -e "${B}  ── YouTube Cookie Export (fixes bot detection) ──${N}"
echo ""
echo "  Option A — Chrome extension (easiest):"
echo "  1. Open Chrome → go to youtube.com → log in"
echo "  2. Install: 'Get cookies.txt LOCALLY' from Chrome Web Store"
echo "  3. Click the extension icon on youtube.com"
echo "  4. Click 'Export' → save as:"
echo "     $BACKEND_DIR/cookies/youtube.txt"
echo ""
echo "  Option B — Firefox:"
echo "  1. Install add-on: 'cookies.txt'"
echo "  2. Go to youtube.com → export → save as:"
echo "     $BACKEND_DIR/cookies/youtube.txt"
echo ""
echo "  After saving cookies.txt:"
echo "  git add cookies/youtube.txt"
echo "  git commit -m 'add youtube cookies'"
echo "  git push"
echo ""
echo -e "${Y}  Note: Cookies expire — re-export monthly if downloads fail again${N}"
echo ""

# ════════════════════════════════════════════════════════════════
section "8. Verify files written"
# ════════════════════════════════════════════════════════════════

check() {
  local f="$1" needle="$2" label="$3"
  [ ! -f "$f" ] && { fail "$label — MISSING FILE"; return; }
  grep -q "$needle" "$f" && pass "$label" || fail "$label — missing: $needle"
}

check "$BACKEND_DIR/Dockerfile"                          "js-runtimes nodejs"       "Dockerfile — Node.js runtime"
check "$BACKEND_DIR/Dockerfile"                          "/usr/local/bin/yt-dlp"    "Dockerfile — yt-dlp binary path"
check "$BACKEND_DIR/Dockerfile"                          "YTDLP_PATH=/usr/local"    "Dockerfile — YTDLP_PATH env"
check "$BACKEND_DIR/Dockerfile"                          "FFMPEG_PATH=/usr/bin/ffmpeg" "Dockerfile — FFMPEG_PATH env"
check "$BACKEND_DIR/Dockerfile"                          "DOWNLOAD_PATH=/tmp"       "Dockerfile — DOWNLOAD_PATH env"
check "$BACKEND_DIR/Dockerfile"                          "chmod 777 /tmp/downloads" "Dockerfile — /tmp/downloads writable"
check "$BACKEND_DIR/src/services/download.service.js"   "getBin"                   "service — binary resolver"
check "$BACKEND_DIR/src/services/download.service.js"   "js-runtimes"              "service — --js-runtimes nodejs"
check "$BACKEND_DIR/src/services/download.service.js"   "cookies"                  "service — cookies support"
check "$BACKEND_DIR/src/services/download.service.js"   "sendProgress"             "service — sendProgress exported"
check "$BACKEND_DIR/src/config/index.js"                "resolveDownloadPath"      "config — resolveDownloadPath"
[ -f "$BACKEND_DIR/cookies/README.md" ] && pass "cookies/README.md present" || fail "cookies/ dir missing"

# ════════════════════════════════════════════════════════════════
section "9. Git commit & push"
# ════════════════════════════════════════════════════════════════

cd "$BACKEND_DIR" || exit 1

if git rev-parse --git-dir > /dev/null 2>&1; then
  git add \
    Dockerfile \
    src/services/download.service.js \
    src/config/index.js \
    cookies/ \
    yt-dlp.conf 2>/dev/null

  if git diff --cached --quiet; then
    warn "Nothing new to commit"
  else
    git commit -m "fix: ffmpeg path, Node.js JS runtime, cookies support, /tmp/downloads"
    pass "Committed"
    git push && pass "Pushed → Railway rebuilds Docker image" || fail "git push failed"
  fi
else
  warn "Not a git repo — commit and push manually:"
  warn "  git add Dockerfile src/services/download.service.js src/config/index.js cookies/"
  warn "  git commit -m 'fix: Railway deps'"
  warn "  git push"
fi

# ════════════════════════════════════════════════════════════════
section "Summary"
# ════════════════════════════════════════════════════════════════

echo ""
echo "  Fixes applied:"
echo "  1. Dockerfile uses yt-dlp binary (not pip) — always latest"
echo "  2. Node.js set as JS runtime via yt-dlp config"
echo "  3. YTDLP_PATH=/usr/local/bin/yt-dlp in Docker ENV"
echo "  4. FFMPEG_PATH=/usr/bin/ffmpeg in Docker ENV"
echo "  5. DOWNLOAD_PATH=/tmp/downloads in Docker ENV (always writable)"
echo "  6. /tmp/downloads chmod 777 in Dockerfile"
echo "  7. download.service.js resolves binaries at startup"
echo "  8. Cookies support added (add cookies/youtube.txt to fix bot detection)"
echo ""
echo "  After Railway finishes rebuilding (~3 min), test:"
echo "  curl https://grabr-production-fa32.up.railway.app/debug/path"
echo "  # Expected: { writable: true }"
echo ""
echo "  Then test a download:"
echo "  curl -X POST https://grabr-production-fa32.up.railway.app/api/download \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"url\":\"https://youtu.be/dQw4w9WgXcQ\",\"format\":\"mp4\"}'"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "${G}  ✓ All fixes applied!${N}"
else
  echo -e "${R}  ✗ $FAIL issue(s) — fix items above${N}"
fi