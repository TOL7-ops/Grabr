The exact bug

Your worker is doing this:

const onProgress = async (pct) => { 
  try { await job.updateProgress(pct); } catch {} 
};

👉 This only updates BullMQ progress, NOT your SSE stream.

So:

Queue progress ✅
SSE clients ❌ (never notified)
🧠 Why you only see : ping

Your SSE controller:

registerSSE(jobId, res);

But nowhere are you doing:

res.write(...)

during download.

So the connection stays alive → : ping
But no actual data → UI stuck on "queued"

✅ The fix (minimal + correct)

You already have:

const { registerSSE, unregisterSSE } = require("../services/download.service");

So your SSE system is centralized — good.

✅ STEP 1 — expose sendProgress

In download.service.js, you MUST have something like:

const clients = new Map();

function registerSSE(jobId, res) {
  clients.set(jobId, res);
}

function unregisterSSE(jobId) {
  clients.delete(jobId);
}

function sendProgress(jobId, data) {
  const res = clients.get(jobId);
  if (!res) return;

  try {
    res.write(`data: ${JSON.stringify(data)}\n\n`);
  } catch {
    clients.delete(jobId);
  }
}

module.exports = {
  runDownload,
  registerSSE,
  unregisterSSE,
  sendProgress, // 👈 MUST export this
};
✅ STEP 2 — FIX your worker (this is the missing link)

Update your worker:

const { sendProgress } = require("../services/download.service");
🔁 Replace your onProgress

Right now:

const onProgress = async (pct) => { 
  try { await job.updateProgress(pct); } catch {} 
};
✅ Replace with:
const onProgress = async (progress) => {
  try {
    await job.updateProgress(progress.percent || progress);
  } catch {}

  // 🚨 THIS IS THE CRITICAL LINE
  sendProgress(job.id, progress);
};
✅ STEP 3 — ensure runDownload sends structured data

Right now your worker assumes:

onProgress(5)

But your streaming expects:

{ percent, speed, eta }
👉 Fix your download.service

Inside spawn stdout:

const match = line.match(/(\d+\.\d+)%.*?at\s+([\d.]+\w+\/s).*?ETA\s+([\d:]+)/);

if (match && onProgress) {
  onProgress({
    status: "downloading",
    percent: parseFloat(match[1]),
    speed: match[2],
    eta: match[3],
  });
}
Add lifecycle events

At start:

onProgress?.({ status: "starting", percent: 0 });

At end:

onProgress?.({
  status: "completed",
  percent: 100,
  filename,
});

On error:

onProgress?.({
  status: "error",
  message: err.message,
});
🧪 WHAT YOU SHOULD SEE AFTER FIX

Run:

curl -N https://grabr-production-fa32.up.railway.app/api/download/stream/<jobId>

Now you should see:

data: {"status":"starting","percent":0}

data: {"status":"downloading","percent":3.1,"speed":"1.2MiB/s","eta":"00:20"}

data: {"status":"downloading","percent":15.4,...}

data: {"status":"completed","percent":100,"filename":"..."}
⚠️ One more subtle issue (important)

You currently do:

await onProgress(5);

That sends:

5

Frontend expects:

{ percent: 5 }

👉 mismatch = UI breaks silently

✅ Fix it:
await onProgress({ status: "starting", percent: 5 });
💥 Final diagnosis

Your system currently:

Component	Status
yt-dlp	✅ working
Worker	✅ running
Redis	✅ working
SSE connection	✅ alive
Progress flow	❌ broken
🧠 In one sentence

You built SSE correctly, but never actually send data into it.