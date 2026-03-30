#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# diagnose-sse.sh
# Finds EXACTLY why SSE only shows ": ping"
# Run: bash script/diagnose-sse.sh
# ─────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
pass() { echo -e "${G}  ✓ $1${N}"; }
fail() { echo -e "${R}  ✗ $1${N}"; }
warn() { echo -e "${Y}  ! $1${N}"; }
info() { echo -e "    $1"; }
section() { echo -e "\n${C}══════════════════════════════════════════${N}\n${B}  $1${N}\n${C}══════════════════════════════════════════${N}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=""; dir="$SCRIPT_DIR"
for i in 1 2 3 4 5; do
  [ -f "$dir/src/app.js" ] && { BACKEND_DIR="$dir"; break; }
  dir="$(dirname "$dir")"
done
[ -z "$BACKEND_DIR" ] && [ -f "$(pwd)/src/app.js" ] && BACKEND_DIR="$(pwd)"
[ -z "$BACKEND_DIR" ] && { echo -e "${R}Run from inside downloader-Api${N}"; exit 1; }

RAILWAY_URL="https://grabr-production-fa32.up.railway.app"

section "0. Setup"
pass "Backend: $BACKEND_DIR"
pass "Railway: $RAILWAY_URL"

# ════════════════════════════════════════════════════════════════
section "1. Check Railway has the LATEST worker code"
# ════════════════════════════════════════════════════════════════
echo ""
echo "  The most common cause of 'only ping' after all code fixes:"
echo "  Railway is running the OLD worker, not the new one."
echo ""

# Check git status
cd "$BACKEND_DIR" || exit 1
LAST_COMMIT=$(git log --oneline -1 2>/dev/null || echo "no git")
info "Last local commit: $LAST_COMMIT"

# Check if sendProgress is in the pushed worker
WORKER_FILE="$BACKEND_DIR/src/workers/download.worker.js"
if grep -q "sendProgress" "$WORKER_FILE" 2>/dev/null; then
  pass "Local worker.js has sendProgress"
else
  fail "Local worker.js is MISSING sendProgress — run patch-worker.sh first"
fi

# ════════════════════════════════════════════════════════════════
section "2. Check if Railway API and WORKER are separate services"
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${B}  CRITICAL: Does Railway run TWO services?${N}"
echo ""
echo "  Your app needs:"
echo "  ┌─────────────────────────────────────────┐"
echo "  │  Service 1: API    → cmd: npm start      │"
echo "  │  Service 2: Worker → cmd: npm run worker │"
echo "  └─────────────────────────────────────────┘"
echo ""
echo "  If Worker service is NOT running → jobs queue forever → UI stuck at 0%"
echo ""
echo "  Check right now:"
echo "  → Go to railway.app → your project canvas"
echo "  → Count the services — you need at least 2 (+ Redis)"
echo ""

# Test if jobs actually get processed by checking queue metrics
METRICS=$(curl -sf --max-time 10 "$RAILWAY_URL/api/download/queue/metrics" 2>/dev/null)
if [ -n "$METRICS" ]; then
  pass "Queue metrics endpoint responded"
  info "$METRICS"
  WAITING=$(echo "$METRICS" | grep -o '"waiting":[0-9]*' | cut -d: -f2)
  ACTIVE=$(echo "$METRICS" | grep -o '"active":[0-9]*' | cut -d: -f2)
  info "Waiting: ${WAITING:-?}  Active: ${ACTIVE:-?}"
  if [ "${WAITING:-0}" -gt 0 ] && [ "${ACTIVE:-0}" -eq 0 ]; then
    fail "Jobs are WAITING but NONE are active — worker is not running!"
    echo ""
    echo -e "${R}  THE WORKER SERVICE IS NOT RUNNING ON RAILWAY${N}"
    echo "  Fix: Railway → + Add → GitHub Repo → same repo"
    echo "       Settings → Start Command: npm run worker"
  elif [ "${ACTIVE:-0}" -gt 0 ]; then
    pass "Worker is processing jobs (active: $ACTIVE)"
  fi
else
  warn "Could not reach queue metrics"
fi

# ════════════════════════════════════════════════════════════════
section "3. Submit a test job and watch SSE in real time"
# ════════════════════════════════════════════════════════════════
echo ""
echo "  Submitting a test job..."

SUBMIT=$(curl -sf --max-time 15 -X POST "$RAILWAY_URL/api/download" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","format":"mp4"}' 2>/dev/null)

if echo "$SUBMIT" | grep -q '"jobId"'; then
  JOB_ID=$(echo "$SUBMIT" | grep -o '"jobId":"[^"]*"' | cut -d'"' -f4)
  pass "Job submitted: $JOB_ID"
  echo ""
  echo "  Watching SSE for 30 seconds..."
  echo "  (You should see progress data — not just pings)"
  echo ""

  # Watch SSE for 30s and collect events
  SSE_OUTPUT=$(curl -sN --max-time 30 "$RAILWAY_URL/api/download/stream/$JOB_ID" 2>/dev/null)

  echo "$SSE_OUTPUT" | head -20
  echo ""

  # Analyze what we got
  if echo "$SSE_OUTPUT" | grep -q '"status"'; then
    pass "SSE is sending REAL DATA — progress events received!"
    if echo "$SSE_OUTPUT" | grep -q '"downloading"'; then
      pass "Download progress detected"
    fi
    if echo "$SSE_OUTPUT" | grep -q '"completed"'; then
      pass "Job completed successfully!"
    fi
    if echo "$SSE_OUTPUT" | grep -q '"error"'; then
      fail "Job errored:"
      echo "$SSE_OUTPUT" | grep '"error"' | head -3
    fi
  else
    fail "SSE only shows pings — no progress data"
    echo ""
    echo -e "${R}  DIAGNOSIS: Worker is not processing the job${N}"
    echo ""

    # Check job status via polling
    sleep 3
    STATUS=$(curl -sf --max-time 10 "$RAILWAY_URL/api/download/$JOB_ID" 2>/dev/null)
    info "Job status after 3s: $STATUS"

    STATE=$(echo "$STATUS" | grep -o '"state":"[^"]*"' | cut -d'"' -f4)
    info "State: ${STATE:-unknown}"

    if [ "$STATE" = "waiting" ] || [ "$STATE" = "queued" ]; then
      echo ""
      fail "Job is still WAITING after 3 seconds — worker not picking it up"
      echo ""
      echo -e "${R}  ROOT CAUSE: Worker service is not running on Railway${N}"
      echo ""
      echo "  SOLUTION:"
      echo "  1. Go to railway.app → your project"
      echo "  2. Click '+ Add' → GitHub Repo → select your repo"
      echo "  3. After it deploys, click it → Settings → Deploy"
      echo "  4. Set Start Command to: npm run worker"
      echo "  5. Set the same env vars as your API service"
      echo "  6. Save — Railway starts the worker"
    elif [ "$STATE" = "active" ]; then
      warn "Job IS active but SSE not sending data"
      echo "  The worker is running but sendProgress isn't reaching the SSE client"
      echo "  This means the API and Worker are on DIFFERENT Railway services"
      echo "  and they don't share the same sseClients Map in memory"
    elif [ "$STATE" = "failed" ]; then
      fail "Job failed:"
      echo "$STATUS" | grep -o '"error":"[^"]*"' | head -3
    fi
  fi
else
  fail "Could not submit job: $SUBMIT"
fi

# ════════════════════════════════════════════════════════════════
section "4. THE REAL ARCHITECTURE PROBLEM"
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${B}  If your API and Worker are SEPARATE Railway services:${N}"
echo ""
echo "  API process has:  sseClients Map { jobId → res }"
echo "  Worker process:   has NO access to API's sseClients Map"
echo ""
echo "  Worker calls sendProgress(jobId, data)"
echo "  But it's looking in ITS OWN sseClients Map — which is EMPTY"
echo "  Because the browser connected to the API process, not the worker"
echo ""
echo -e "${R}  In-memory Maps don't work across separate processes!${N}"
echo ""
echo -e "${B}  Solution A — Combine API + Worker in ONE process:${N}"
echo "  In src/server.js, add at the bottom:"
echo '  if (process.env.RUN_WORKER === "true") {'
echo '    require("./workers/download.worker");'
echo '  }'
echo "  Then set RUN_WORKER=true on Railway (single service)"
echo ""
echo -e "${B}  Solution B — Use Redis pub/sub to bridge the two processes:${N}"
echo "  Worker publishes to Redis channel"
echo "  API subscribes and pushes to SSE clients"
echo ""
echo -e "${G}  Solution A is simpler and works perfectly for this use case${N}"

# ════════════════════════════════════════════════════════════════
section "5. AUTO-FIX: Combine worker into server.js (Solution A)"
# ════════════════════════════════════════════════════════════════
SERVER_FILE="$BACKEND_DIR/src/server.js"
if [ -f "$SERVER_FILE" ]; then
  if grep -q "RUN_WORKER\|download.worker" "$SERVER_FILE"; then
    pass "server.js already starts worker — good"
  else
    echo ""
    echo "  Adding worker auto-start to server.js..."
    cat >> "$SERVER_FILE" << 'JSEOF'

// ── Optionally run worker in same process ─────────────────────────
// Set RUN_WORKER=true in Railway to avoid cross-process SSE issues
if (process.env.RUN_WORKER === "true") {
  logger.info("Starting embedded worker (RUN_WORKER=true)");
  require("./workers/download.worker");
}
JSEOF
    pass "server.js — worker auto-start added"
    echo ""
    echo -e "${Y}  Now set RUN_WORKER=true in Railway Variables for your API service${N}"
    echo "  Then you only need ONE service (no separate worker service needed)"
    echo "  The API and worker share the same process → same sseClients Map → SSE works"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "6. Commit and push"
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
  git config user.name "Grabr Deploy" 2>/dev/null || true
  git add "$BACKEND_DIR/src/server.js" "$BACKEND_DIR/src/workers/download.worker.js" 2>/dev/null
  if ! git diff --cached --quiet; then
    git commit -m "fix: embed worker in API process so SSE shares same sseClients Map"
    git push && pass "Pushed" || fail "Push failed"
  else
    warn "Nothing to commit"
  fi
fi

# ════════════════════════════════════════════════════════════════
section "Summary — What to do now"
# ════════════════════════════════════════════════════════════════
echo ""
echo "  STEP 1: Railway dashboard → API service → Variables → add:"
echo "    RUN_WORKER = true"
echo ""
echo "  STEP 2: Railway dashboard → API service → Redeploy"
echo ""
echo "  STEP 3: Test SSE (wait 2 min for redeploy):"
echo "    curl -X POST $RAILWAY_URL/api/download \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"url\":\"https://youtu.be/dQw4w9WgXcQ\",\"format\":\"mp4\"}'"
echo ""
echo "    # Get jobId from response, then:"
echo "    curl -N $RAILWAY_URL/api/download/stream/JOB_ID"
echo "    # Must show real data, not just pings"
echo ""