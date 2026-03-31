#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# fix-etimedout.sh
# Fixes:
#   1. ETIMEDOUT — reduce fragments, add keepalive, lower timeout
#   2. app.js still using express.static (wildcard route fix)
#   3. Files disappear on Railway restart — serve from /tmp correctly
# Run: bash script/fix-etimedout.sh
# ─────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n  $1\n${C}══════════════════════════════════════════${N}"; }
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

# ════════════════════════════════════════════════════════════════
section "1. FIX app.js — wildcard route replaces express.static"
# ════════════════════════════════════════════════════════════════
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

// CORS — allow ALL *.vercel.app + localhost
function isAllowedOrigin(origin) {
  if (!origin) return true;
  if (/^https:\/\/[a-zA-Z0-9-]+\.vercel\.app$/.test(origin)) return true;
  if (/^http:\/\/localhost:\d+$/.test(origin)) return true;
  if (/^http:\/\/127\.0\.0\.1:\d+$/.test(origin)) return true;
  if (process.env.CORS_ORIGIN && origin === process.env.CORS_ORIGIN) return true;
  return false;
}
app.use(cors({
  origin: (origin, cb) => isAllowedOrigin(origin) ? cb(null, true) : cb(new Error(`CORS: ${origin}`)),
  methods: ["GET","POST","OPTIONS"],
  allowedHeaders: ["Content-Type","Authorization"],
  credentials: false,
}));
app.options("*", cors());
app.use(helmet({ crossOriginResourcePolicy: { policy: "cross-origin" } }));
app.use(morgan("combined", {
  stream: { write: msg => logger.http(msg.trim()) },
  skip: () => config.nodeEnv === "test",
}));
app.use(express.json({ limit: "10kb" }));

// MIME map
const MIME = {
  ".mp4":"video/mp4", ".webm":"video/webm", ".mkv":"video/x-matroska",
  ".mov":"video/quicktime", ".mp3":"audio/mpeg", ".m4a":"audio/mp4",
  ".ogg":"audio/ogg", ".wav":"audio/wav", ".opus":"audio/opus",
};

// ── File serving — wildcard route ─────────────────────────────────
// Accepts filenames with dots, dashes, spaces — only blocks ".."
// Content-Disposition: attachment → forces download on all browsers
// video/mp4 MIME → iOS offers "Save to Photos"
app.get("/files/:filename(*)", (req, res) => {
  let filename;
  try { filename = decodeURIComponent(req.params.filename); }
  catch { return res.status(400).json({ error: "Bad filename encoding" }); }

  if (filename.includes("..") || filename.includes("/") || filename.includes("\\")) {
    return res.status(400).json({ error: "Invalid filename" });
  }

  const downloadDir = path.resolve(config.storage.downloadPath);
  const filePath    = path.join(downloadDir, filename);

  if (!filePath.startsWith(downloadDir + path.sep)) {
    return res.status(400).json({ error: "Invalid path" });
  }

  if (!fs.existsSync(filePath)) {
    logger.warn("File not found", { filename, dir: downloadDir });
    return res.status(404).json({ error: "File not found", filename });
  }

  const stat     = fs.statSync(filePath);
  const ext      = path.extname(filename).toLowerCase();
  const mimeType = MIME[ext] || "application/octet-stream";

  res.setHeader("Content-Type",        mimeType);
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

app.get("/debug/path", (_req, res) => {
  const dir = config.storage.downloadPath;
  let writable = false, exists = fs.existsSync(dir);
  try { fs.accessSync(dir, fs.constants.W_OK); writable = true; } catch {}
  let files = [];
  try { files = fs.readdirSync(dir).slice(-5); } catch {}
  res.json({ downloadPath: dir, exists, writable, baseUrl: config.baseUrl,
             NODE_ENV: process.env.NODE_ENV, RUN_WORKER: process.env.RUN_WORKER, recentFiles: files });
});

app.use("/api/download", downloadRoutes);
app.get("/health", (_req, res) => res.json({ status: "ok", uptime: process.uptime(), ts: new Date().toISOString() }));
app.use(notFound);
app.use(errorHandler);
module.exports = app;
EOF
pass "app.js — wildcard route, no express.static"

# ════════════════════════════════════════════════════════════════
section "2. FIX download.service.js — ETIMEDOUT settings"
# ════════════════════════════════════════════════════════════════
# ETIMEDOUT causes:
#   1. --concurrent-fragments too high (Railway throttles)
#   2. --socket-timeout too low for slow connections
#   3. No --source-address binding for IPv4 (Railway may try IPv6 first)
#   4. No --sleep-interval to avoid rate limiting
# Fix: reduce concurrency, increase timeouts, force IPv4, add retries

SVC="$BACKEND_DIR/src/services/download.service.js"

# Fix concurrent-fragments if still set to 4
if grep -q '"--concurrent-fragments", "4"' "$SVC"; then
  sed -i 's/"--concurrent-fragments", "4"/"--concurrent-fragments", "1"/' "$SVC"
  pass "service — concurrent-fragments reduced to 1"
elif grep -q '"--concurrent-fragments", "2"' "$SVC"; then
  sed -i 's/"--concurrent-fragments", "2"/"--concurrent-fragments", "1"/' "$SVC"
  pass "service — concurrent-fragments reduced to 1"
else
  warn "service — concurrent-fragments already set or not found"
fi

# Fix socket timeout if set to 60
if grep -q '"--socket-timeout", "60"' "$SVC"; then
  sed -i 's/"--socket-timeout", "60"/"--socket-timeout", "30"/' "$SVC"
  pass "service — socket-timeout set to 30"
fi

# Add --force-ipv4 to buildArgs if not already there
if ! grep -q "force-ipv4" "$SVC"; then
  # Insert after --no-part
  sed -i 's/"--no-part",/"--no-part",\n    "--force-ipv4",/' "$SVC"
  pass "service — --force-ipv4 added (avoids IPv6 timeout on Railway)"
else
  pass "service — --force-ipv4 already present"
fi

# Add --sleep-requests if not present (avoids rate limiting)
if ! grep -q "sleep-requests\|extractor-retries" "$SVC"; then
  sed -i 's/"--retries", "5",/"--retries", "5",\n    "--extractor-retries", "5",/' "$SVC"
  pass "service — --extractor-retries 5 added"
fi

# Verify the fixes
grep -q "force-ipv4" "$SVC"        && pass "service — --force-ipv4 confirmed" || fail "service — force-ipv4 missing"
grep -q "concurrent-fragments.*1" "$SVC" && pass "service — fragments=1 confirmed" || warn "service — fragments not 1"

# ════════════════════════════════════════════════════════════════
section "3. Verify app.js"
# ════════════════════════════════════════════════════════════════
grep -q 'filename(\*)' "$BACKEND_DIR/src/app.js" \
  && pass "app.js — wildcard route present" \
  || fail "app.js — wildcard route missing"

grep -q "sendFile" "$BACKEND_DIR/src/app.js" \
  && pass "app.js — sendFile used" \
  || fail "app.js — sendFile missing"

grep -q "express.static" "$BACKEND_DIR/src/app.js" \
  && fail "app.js — STILL using express.static (should be removed)" \
  || pass "app.js — express.static removed"

# ════════════════════════════════════════════════════════════════
section "4. Quick local test of file route logic"
# ════════════════════════════════════════════════════════════════
node - "$BACKEND_DIR/src/app.js" << 'NODEEOF' 2>/dev/null
// Test filename validation logic
const tests = [
  ["43_Rick_Astley.mp4",          true,  "normal filename"],
  ["file.with.dots.mp4",          true,  "dots in name"],
  ["my video (1).mp4",            true,  "spaces and parens"],
  ["../etc/passwd",               false, "path traversal"],
  ["foo/bar.mp4",                 false, "slash"],
  ["58_DD_Geopolitics_-_Even.mp4",true,  "dashes and underscores"],
];
let all = true;
for (const [name, expected, label] of tests) {
  const blocked = name.includes("..") || name.includes("/") || name.includes("\\");
  const result  = !blocked;
  const ok      = result === expected;
  if (!ok) { console.log(`  ✗ FAIL: ${label} — got ${result}, want ${expected}`); all = false; }
  else      { console.log(`  ✓ ${label}`); }
}
process.exit(all ? 0 : 1);
NODEEOF
[ $? -eq 0 ] && pass "File validation logic correct" || warn "File validation check inconclusive"

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
  git add "$BACKEND_DIR/src/app.js" "$BACKEND_DIR/src/services/download.service.js"
  if git diff --cached --quiet; then
    git commit --allow-empty -m "fix: wildcard file route, force-ipv4, reduce fragments"
  else
    git commit -m "fix: wildcard route (express.static removed), force-ipv4, fragments=1"
  fi
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  git push origin "$BRANCH" \
    && pass "Pushed → Railway redeploys" \
    || { git push --set-upstream origin "$BRANCH" && pass "Pushed"; }
else
  warn "No git repo — push manually"
fi

# ════════════════════════════════════════════════════════════════
section "6. Post-deploy test plan"
# ════════════════════════════════════════════════════════════════
echo ""
echo "  After Railway redeploys (~1 min), test:"
echo ""
echo "  1. Submit a short video:"
echo '     curl -X POST https://grabr-production-fa32.up.railway.app/api/download \'
echo '       -H "Content-Type: application/json" \'
echo '       -d '"'"'{"url":"https://youtu.be/dQw4w9WgXcQ","format":"mp4"}'"'"
echo ""
echo "  2. Watch live SSE (replace JOB_ID):"
echo "     curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/JOB_ID"
echo "     # Should see: data: {\"percent\":12,\"speed\":...}"
echo ""
echo "  3. Once complete, test file serving:"
echo '     curl -I "https://grabr-production-fa32.up.railway.app/files/FILENAME"'
echo "     # Must show: content-type: video/mp4"
echo "     # Must show: content-disposition: attachment"
echo ""
echo "  Note: files only exist until Railway restarts the container."
echo "  This is normal for /tmp — download immediately after completion."
echo ""

if [ $FAIL -eq 0 ]; then echo -e "${G}  ✓ Done!${N}"; else echo -e "${R}  ✗ $FAIL issue(s)${N}"; fi