#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# fix-youtube-streaming.sh
# Fix 1: Dockerfile — copy cookies/, use binary yt-dlp, correct Node path
# Fix 2: JS runtime flag nodejs → node
# Fix 3: Progress stuck at 5% — onProgress called with number not object
# Fix 4: Progress regex — handle all yt-dlp output formats
# Run: bash script/fix-youtube-streaming.sh
# ─────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37b'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n\033[0;36m══════════════════════════════════════════\033[0m\n\033[1;37m  $1\033[0m\n\033[0;36m══════════════════════════════════════════\033[0m"; }
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=""; dir="$SCRIPT_DIR"
for i in 1 2 3 4 5; do
  [ -f "$dir/src/app.js" ] && { BACKEND_DIR="$dir"; break; }
  dir="$(dirname "$dir")"
done
[ -z "$BACKEND_DIR" ] && [ -f "$(pwd)/src/app.js" ] && BACKEND_DIR="$(pwd)"
[ -z "$BACKEND_DIR" ] && { echo "Run from inside downloader-Api"; exit 1; }

FRONTEND_DIR=""
for name in my-downloader-frontend grabr-frontend frontend; do
  [ -d "$BACKEND_DIR/$name/src" ] && { FRONTEND_DIR="$BACKEND_DIR/$name"; break; }
done

section "0. Paths"
pass "Backend : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend: $FRONTEND_DIR"

# ════════════════════════════════════════════════════════════════
section "1. Check cookies"
# ════════════════════════════════════════════════════════════════
COOKIES_DIR="$BACKEND_DIR/cookies"
COOKIES_FILE="$COOKIES_DIR/youtube.txt"

if [ -f "$COOKIES_FILE" ]; then
  LINES=$(wc -l < "$COOKIES_FILE")
  pass "cookies/youtube.txt exists ($LINES lines)"
else
  fail "cookies/youtube.txt NOT FOUND"
  echo ""
  warn "You need YouTube cookies to bypass bot detection."
  warn "Steps:"
  warn "  1. Install Chrome extension: 'Get cookies.txt LOCALLY'"
  warn "  2. Go to youtube.com while logged in"
  warn "  3. Click extension → Export → save as: $COOKIES_FILE"
  warn "  4. Run this script again"
  mkdir -p "$COOKIES_DIR"
  echo "# Add your YouTube cookies here" > "$COOKIES_FILE"
  warn "Created empty placeholder — replace with real cookies"
fi

# ════════════════════════════════════════════════════════════════
section "2. FIX Dockerfile — binary yt-dlp + copy cookies + node runtime"
# ════════════════════════════════════════════════════════════════
# Problems in old Dockerfile:
# - pip yt-dlp gets outdated version
# - node-slim has no full Node.js binary path for yt-dlp
# - cookies/ directory never copied
# - --js-runtimes nodejs wrong (should be node)

cat > "$BACKEND_DIR/Dockerfile" << 'EOF'
FROM node:20 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production \
    YTDLP_PATH=/usr/local/bin/yt-dlp \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    DOWNLOAD_PATH=/tmp/downloads \
    PORT=3000

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip ffmpeg curl wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Verify ffmpeg
RUN which ffmpeg && ffmpeg -version 2>&1 | head -1

# Install yt-dlp as binary (not pip) — always latest, more reliable
RUN wget -q "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" \
    -O /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp \
    && yt-dlp --version

# Tell yt-dlp where Node.js binary is for JS runtime
# The flag is "--js-runtimes node" (NOT "nodejs")
# Full path ensures it's found even if PATH differs
RUN mkdir -p /root/.config/yt-dlp && \
    NODE_BIN=$(which node) && \
    echo "--js-runtimes node:${NODE_BIN}" > /root/.config/yt-dlp/config && \
    echo "--retries 5"                   >> /root/.config/yt-dlp/config && \
    echo "--socket-timeout 60"           >> /root/.config/yt-dlp/config && \
    echo "--no-cache-dir"                >> /root/.config/yt-dlp/config && \
    cat /root/.config/yt-dlp/config

# Verify yt-dlp can find node runtime
RUN yt-dlp --version && echo "yt-dlp config OK"

# Create writable download dir
RUN mkdir -p /tmp/downloads && chmod 777 /tmp/downloads

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY src/ ./src/

# CRITICAL: copy cookies so YouTube bot check passes
COPY cookies/ ./cookies/

RUN mkdir -p logs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]

FROM base AS worker
CMD ["node", "src/workers/download.worker.js"]
EOF
pass "Dockerfile — binary yt-dlp, cookies copied, node runtime with full path"

# ════════════════════════════════════════════════════════════════
section "3. FIX download.service.js — runtime flag + progress streaming"
# ════════════════════════════════════════════════════════════════
# Problems:
# - "--js-runtimes nodejs" wrong → should be "node"  
# - onProgress(0) called with number not object → UI stuck at 5%
# - emit() and onProgress() calling pattern inconsistent

cat > "$BACKEND_DIR/src/services/download.service.js" << 'JSEOF'
const { spawn, execFile } = require("child_process");
const path   = require("path");
const fs     = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE registry ──────────────────────────────────────────────────
const sseClients = new Map();

function registerSSE(jobId, res) {
  sseClients.set(String(jobId), res);
  logger.info("SSE registered", { jobId, clients: sseClients.size });
}
function unregisterSSE(jobId) {
  sseClients.delete(String(jobId));
}
function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) {
    logger.warn("SSE write failed", { jobId });
    unregisterSSE(jobId);
  }
}

// ── Binary resolution ─────────────────────────────────────────────
function resolveBin(envKey, candidates) {
  const v = process.env[envKey];
  if (v && fs.existsSync(v)) return v;
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return candidates[0];
}
const YTDLP_BIN  = resolveBin("YTDLP_PATH",  ["/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp", "yt-dlp"]);
const FFMPEG_BIN = resolveBin("FFMPEG_PATH",  ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "ffmpeg"]);
// Node.js binary full path — needed for yt-dlp JS runtime
const NODE_BIN   = process.execPath || resolveBin("", ["/usr/local/bin/node", "/usr/bin/node", "node"]);

logger.info("Binaries", { ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN, node: NODE_BIN });

// ── Filename sanitizer ────────────────────────────────────────────
function sanitizeFilename(raw) {
  return raw.replace(/[^\w.-]+/g, "_").replace(/_+/g, "_")
            .replace(/^_+|_+$/g, "").slice(0, 200);
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
  // Cookies: check /app/cookies/youtube.txt (inside Docker)
  // and local path (for dev)
  const cookiesPaths = [
    "/app/cookies/youtube.txt",
    path.join(__dirname, "../../cookies/youtube.txt"),
  ];
  const cookiesFile = cookiesPaths.find(p => fs.existsSync(p));
  const cookiesArgs = cookiesFile ? ["--cookies", cookiesFile] : [];

  if (cookiesFile) logger.info("Using cookies", { path: cookiesFile });
  else logger.warn("No cookies file found — YouTube may block bot");

  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist",
    "--restrict-filenames",
    // CORRECT flag: "node" not "nodejs" — with full path to binary
    "--js-runtimes",          `node:${NODE_BIN}`,
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

// ── Progress regexes ──────────────────────────────────────────────
// yt-dlp outputs several formats — handle all of them:
// [download]  42.3% of   10.00MiB at    1.23MiB/s ETA 00:05
// [download]  42.3% of ~  10.00MiB at    1.23MiB/s ETA 00:05 (frag 3/7)
// [download] 100% of    3.29MiB in 00:00:00 at 4.14MiB/s
const RE_PROGRESS_FULL = /\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\S+)\s+at\s+([\d.]+\S+)\s+ETA\s+([\d:]+)/;
const RE_PROGRESS_DONE = /\[download\]\s+100%\s+of\s+~?\s*([\d.]+\S+)\s+in\s+([\d:]+)/;
const RE_FRAG          = /\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\S+).*\(frag\s+(\d+)\/(\d+)\)/;
const RE_MERGE         = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG        = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST          = /\[download\] Destination:\s+(.+)/;

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

  // emit: single function that pushes to BOTH SSE and BullMQ via onProgress
  // Always sends objects — never plain numbers
  const emit = (data) => {
    // Direct SSE push
    sendProgress(String(jobId), data);
    // Also call worker callback for BullMQ progress
    if (onProgress) {
      const pct = typeof data === "object" ? (data.percent || 0) : Number(data) || 0;
      try { onProgress(data, pct); } catch {}
    }
  };

  // Send starting event — as object, never plain number
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
      stdoutBuf = lines.pop();

      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;
        logger.debug("yt-dlp", { jobId, line });

        // Phase switch
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

        // Parse progress — try all regex variants
        let percent = null, size = "", speed = "", eta = "";

        const fullM = line.match(RE_PROGRESS_FULL);
        const doneM = line.match(RE_PROGRESS_DONE);
        const fragM = line.match(RE_FRAG);

        if (fullM) {
          percent = parseFloat(fullM[1]);
          size    = fullM[2];
          speed   = fullM[3];
          eta     = fullM[4];
        } else if (fragM) {
          // Fragment download: calculate % from frag count
          const frag  = parseInt(fragM[3]);
          const total = parseInt(fragM[4]);
          percent = Math.round((frag / total) * 100);
          size    = fragM[2];
          speed   = "";
          eta     = "";
        } else if (doneM) {
          percent = 100;
          size    = doneM[1];
          speed   = "";
          eta     = "0:00";
        }

        if (percent !== null && (percent - lastPct >= 1 || percent >= 100)) {
          lastPct = percent;
          emit({
            status:  "downloading",
            percent: Math.min(percent, 98),
            size,
            speed,
            eta,
          });
        }
      }
    });

    child.stderr.on("data", chunk => {
      const text = chunk.toString();
      stderrBuf += text;
      // Log warnings in real time so they show in Railway logs
      text.split("\n").forEach(line => {
        if (line.trim()) logger.debug("yt-dlp stderr", { jobId, line: line.trim() });
      });
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
      const rawName   = path.basename(outputPath);
      const ext       = path.extname(rawName);
      const cleanName = sanitizeFilename(path.basename(rawName, ext)) + ext;
      const cleanPath = path.join(downloadDir, cleanName);
      if (rawName !== cleanName && !fs.existsSync(cleanPath)) {
        try { fs.renameSync(outputPath, cleanPath); outputPath = cleanPath; } catch {}
      }

      const filename  = path.basename(outputPath);
      const baseUrl   = config.baseUrl.replace(/\/$/, "");
      const fileUrl   = `${baseUrl}/files/${encodeURIComponent(filename)}`;
      const mediaType = [".mp4",".webm",".mkv",".mov"].includes(ext.toLowerCase()) ? "video"
                      : [".mp3",".m4a",".ogg",".wav",".opus"].includes(ext.toLowerCase()) ? "audio"
                      : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });
      logger.info("Complete", { jobId, filename, fileUrl, elapsed: `${elapsed}s` });
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
    execFile(YTDLP_BIN,
      ["--dump-json", "--no-playlist", `--js-runtimes`, `node:${NODE_BIN}`, url],
      { timeout: 30_000 },
      (err, stdout) => {
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
pass "download.service.js — node runtime, cookies, multi-regex progress, emit() fixed"

# ════════════════════════════════════════════════════════════════
section "4. Verify"
# ════════════════════════════════════════════════════════════════
grep -q "node:\${NODE_BIN}" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service — correct --js-runtimes node:PATH flag" \
  || fail "service — runtime flag wrong"

grep -q "RE_FRAG\|RE_PROGRESS_DONE" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service — multiple progress regex patterns" \
  || fail "service — missing extended progress regex"

grep -q "cookiesPaths" "$BACKEND_DIR/src/services/download.service.js" \
  && pass "service — cookies path resolution" \
  || fail "service — cookies path missing"

grep -q "COPY cookies" "$BACKEND_DIR/Dockerfile" \
  && pass "Dockerfile — cookies/ copied into image" \
  || fail "Dockerfile — cookies/ NOT copied"

grep -q "node:\${NODE_BIN}\|node:/" "$BACKEND_DIR/Dockerfile" \
  && pass "Dockerfile — Node.js runtime configured" \
  || fail "Dockerfile — Node.js runtime not configured"

[ -f "$BACKEND_DIR/cookies/youtube.txt" ] \
  && pass "cookies/youtube.txt exists" \
  || fail "cookies/youtube.txt MISSING — YouTube will block downloads"

# ════════════════════════════════════════════════════════════════
section "5. Git commit and push"
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
    "$BACKEND_DIR/Dockerfile" \
    "$BACKEND_DIR/src/services/download.service.js" \
    "$BACKEND_DIR/cookies/"
  if git diff --cached --quiet; then
    git commit --allow-empty -m "fix: youtube runtime, cookies, progress streaming"
  else
    git commit -m "fix: js-runtime node:PATH, cookies in Docker, multi-regex progress"
  fi
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  git push origin "$BRANCH" \
    && pass "Pushed → Railway rebuilds Docker image (~3 min)" \
    || { git push --set-upstream origin "$BRANCH" && pass "Pushed"; }
else
  warn "No git repo — push manually"
fi

# ════════════════════════════════════════════════════════════════
section "Summary"
# ════════════════════════════════════════════════════════════════
echo ""
echo "  Fixes:"
echo "  1. Dockerfile: COPY cookies/ ./cookies/ — YouTube cookies now in image"
echo "  2. Dockerfile: Node.js full path in yt-dlp config (--js-runtimes node:/path)"
echo "  3. Dockerfile: yt-dlp binary (not pip) — always latest"
echo "  4. service: --js-runtimes node:\${NODE_BIN} (not 'nodejs')"
echo "  5. service: cookies auto-detected at /app/cookies/youtube.txt"
echo "  6. service: emit() always sends objects, never plain numbers"
echo "  7. service: 3 regex patterns for progress (normal, fragment, done)"
echo ""
echo "  After Railway rebuild (~3 min), test YouTube:"
echo "  curl -X POST https://grabr-production-fa32.up.railway.app/api/download \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"url\":\"https://youtu.be/dQw4w9WgXcQ\",\"format\":\"mp4\"}'"
echo ""
if [ $FAIL -eq 0 ]; then echo -e "${G}  ✓ All done!${N}"; else echo -e "${R}  ✗ $FAIL issue(s)${N}"; fi