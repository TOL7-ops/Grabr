#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# push-and-deploy.sh
# Finds the git repo, commits all changes, pushes to Railway,
# re-authenticates Vercel if needed, and deploys frontend.
# Run: bash script/push-and-deploy.sh
# ─────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; }
warn() { echo -e "${Y}  ! $1${N}"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n${B}  $1${N}\n${C}══════════════════════════════════════════${N}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=""; dir="$SCRIPT_DIR"
for i in 1 2 3 4 5; do
  [ -f "$dir/src/app.js" ] && { BACKEND_DIR="$dir"; break; }; dir="$(dirname "$dir")"
done
[ -z "$BACKEND_DIR" ] && [ -f "$(pwd)/src/app.js" ] && BACKEND_DIR="$(pwd)"
[ -z "$BACKEND_DIR" ] && { echo -e "${R}Cannot find backend${N}"; exit 1; }

FRONTEND_DIR=""
for name in my-downloader-frontend grabr-frontend frontend; do
  [ -d "$BACKEND_DIR/$name/src" ] && { FRONTEND_DIR="$BACKEND_DIR/$name"; break; }
done

section "0. Paths"
pass "Backend  : $BACKEND_DIR"
[ -n "$FRONTEND_DIR" ] && pass "Frontend : $FRONTEND_DIR"

# ── Find git repo root (may be parent of BACKEND_DIR) ────────────
section "1. Find git repository"
GIT_ROOT=""
dir="$BACKEND_DIR"
for i in 1 2 3 4 5; do
  if [ -d "$dir/.git" ]; then GIT_ROOT="$dir"; break; fi
  dir="$(dirname "$dir")"
done

if [ -z "$GIT_ROOT" ]; then
  warn "No git repo found — initializing one now"
  cd "$BACKEND_DIR" || exit 1
  git init
  git remote add origin "$(git remote get-url origin 2>/dev/null || echo '')" 2>/dev/null || true
  GIT_ROOT="$BACKEND_DIR"
  echo ""
  echo "  Git repo initialized at: $GIT_ROOT"
  echo "  You need to set the remote. Run:"
  echo "    cd $GIT_ROOT"
  echo "    git remote add origin https://github.com/TOL7-ops/Grabr.git"
  echo "    git push -u origin main"
else
  pass "Git root: $GIT_ROOT"
fi

# ── Stage all changed files ───────────────────────────────────────
section "2. Stage and commit"

cd "$GIT_ROOT" || exit 1

# Stage backend changes
git add \
  "$BACKEND_DIR/src/app.js" \
  "$BACKEND_DIR/src/services/download.service.js" \
  "$BACKEND_DIR/src/workers/download.worker.js" \
  "$BACKEND_DIR/src/controllers/stream.controller.js" \
  "$BACKEND_DIR/src/controllers/download.controller.js" \
  "$BACKEND_DIR/src/config/index.js" \
  "$BACKEND_DIR/src/routes/download.routes.js" \
  "$BACKEND_DIR/Dockerfile" \
  "$BACKEND_DIR/cookies/" \
  2>/dev/null

# Stage frontend changes
[ -n "$FRONTEND_DIR" ] && git add \
  "$FRONTEND_DIR/src/api.js" \
  "$FRONTEND_DIR/src/App.jsx" \
  "$FRONTEND_DIR/src/App.css" \
  "$FRONTEND_DIR/src/MediaPreview.jsx" \
  "$FRONTEND_DIR/src/main.jsx" \
  "$FRONTEND_DIR/.env.production" \
  2>/dev/null

# Show what's staged
echo ""
git status --short
echo ""

if git diff --cached --quiet; then
  warn "Nothing new to commit — all files already pushed"
  warn "If Railway still shows old code, force a redeploy from the Railway dashboard"
else
  git commit -m "fix: filename sanitize, localhost URL, file serving, mobile download, SSE"
  pass "Committed"

  git push && pass "Pushed to GitHub → Railway redeploys automatically" \
           || {
                fail "git push failed — trying to set upstream"
                BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
                git push --set-upstream origin "$BRANCH" \
                  && pass "Pushed with upstream set" \
                  || fail "Push failed — check your git remote with: git remote -v"
              }
fi

# ── Vercel deploy ─────────────────────────────────────────────────
section "3. Vercel frontend deploy"

if [ -z "$FRONTEND_DIR" ]; then
  warn "No frontend dir found"
  exit 0
fi

cd "$FRONTEND_DIR" || exit 1

# Ensure .env.production exists
[ ! -f ".env.production" ] && \
  echo "VITE_API_URL=https://grabr-production-fa32.up.railway.app" > .env.production && \
  pass "Created .env.production"

if ! command -v vercel &>/dev/null; then
  warn "vercel not installed — installing..."
  npm install -g vercel
fi

# Check if logged in
if vercel whoami &>/dev/null 2>&1; then
  pass "Vercel already authenticated"
else
  echo ""
  echo -e "${Y}  Vercel token expired — logging in now...${N}"
  echo "  (A browser window will open — log in with your account)"
  echo ""
  vercel login
fi

echo ""
echo "  Deploying to Vercel..."
vercel --prod --yes && pass "Vercel deployed!" || {
  fail "Vercel deploy failed"
  echo ""
  echo "  Try manually:"
  echo "  cd $FRONTEND_DIR"
  echo "  vercel login"
  echo "  vercel --prod"
}

# ── Post-deploy checks ────────────────────────────────────────────
section "4. Post-deploy verification"

RAILWAY_URL="https://grabr-production-fa32.up.railway.app"

echo "  Waiting 5s for Railway to pick up changes..."
sleep 5

# Health check
HEALTH=$(curl -sf --max-time 10 "$RAILWAY_URL/health" 2>/dev/null)
echo "$HEALTH" | grep -q '"status":"ok"' \
  && pass "Railway health: OK" \
  || warn "Railway health check failed — may still be deploying"

# Debug path
DPATH=$(curl -sf --max-time 10 "$RAILWAY_URL/debug/path" 2>/dev/null)
echo "  debug/path: $DPATH"
if echo "$DPATH" | grep -q '"writable":true'; then
  pass "Download dir is writable"
else
  warn "Download dir not writable yet — Railway may still be starting"
fi

if echo "$DPATH" | grep -q '"baseUrl":"http://localhost'; then
  fail "BASE_URL still shows localhost on Railway!"
  echo ""
  echo -e "${R}  Go to Railway → Variables → set BASE_URL=https://grabr-production-fa32.up.railway.app${N}"
else
  pass "BASE_URL looks correct on Railway"
fi

section "Done"
echo ""
echo "  After Railway finishes rebuilding (~3 min), test:"
echo "  1. Submit a job:"
echo '     curl -X POST https://grabr-production-fa32.up.railway.app/api/download \'
echo '       -H "Content-Type: application/json" \'
echo '       -d '"'"'{"url":"https://youtu.be/dQw4w9WgXcQ","format":"mp4"}'"'"
echo ""
echo "  2. Watch SSE (replace JOB_ID):"
echo "     curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/JOB_ID"
echo "     # Should see: data: {\"status\":\"downloading\",\"percent\":12,...}"
echo ""
echo "  3. Test file headers (replace FILENAME):"
echo '     curl -I "https://grabr-production-fa32.up.railway.app/files/FILENAME"'
echo "     # Should see: content-disposition: attachment; filename=..."
echo ""