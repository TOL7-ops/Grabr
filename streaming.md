AGENT TASK: Convert downloader to real-time streaming (no polling)
🎯 Goal

Replace polling-based job status with real-time progress streaming using Server-Sent Events (SSE).

1. Backend: switch from execFile → spawn
Replace:
execFile(...)
With:
spawn(...)

Reason:

execFile buffers output → you lose real-time progress
spawn streams stdout/stderr live
2. Parse yt-dlp progress in real time

Inside spawn, listen to stdout:

child.stdout.on("data", (chunk) => {
  const line = chunk.toString();

  // Example yt-dlp output:
  // [download]  42.3% of 10.00MiB at 1.23MiB/s ETA 00:05

  const match = line.match(/(\d+\.\d+)%.*?at\s+([\d.]+\w+\/s).*?ETA\s+([\d:]+)/);

  if (match) {
    const progress = {
      percent: parseFloat(match[1]),
      speed: match[2],
      eta: match[3],
    };

    sendProgress(jobId, progress);
  }
});
3. Create SSE endpoint
Route:
GET /api/stream/:jobId
Implementation:
const clients = new Map(); // jobId -> res

app.get("/api/stream/:jobId", (req, res) => {
  const { jobId } = req.params;

  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");

  clients.set(jobId, res);

  req.on("close", () => {
    clients.delete(jobId);
  });
});
4. Send progress updates

Create helper:

function sendProgress(jobId, data) {
  const res = clients.get(jobId);
  if (!res) return;

  res.write(`data: ${JSON.stringify(data)}\n\n`);
}
5. Emit lifecycle events

During download:

sendProgress(jobId, { status: "starting" });

sendProgress(jobId, {
  status: "downloading",
  percent,
  speed,
  eta,
});

sendProgress(jobId, { status: "processing" });

sendProgress(jobId, {
  status: "completed",
  fileUrl,
});

On error:

sendProgress(jobId, {
  status: "error",
  message: error.message,
});
6. Frontend: replace polling with EventSource
Remove:
setInterval polling
/status/:jobId loop
Add:
const eventSource = new EventSource(`${API_URL}/api/stream/${jobId}`);

eventSource.onmessage = (event) => {
  const data = JSON.parse(event.data);

  if (data.status === "downloading") {
    setProgress(data.percent);
  }

  if (data.status === "completed") {
    setDownloadUrl(data.fileUrl);
    eventSource.close();
  }

  if (data.status === "error") {
    setError(data.message);
    eventSource.close();
  }
};
7. Handle Railway constraints (VERY IMPORTANT)
SSE works on Railway ✅
BUT:
Keep connections alive
Do NOT block event loop

Add:

res.flushHeaders();
8. Improve yt-dlp performance

Add flags:

"--concurrent-fragments", "4",
"--no-cache-dir",
"--no-part",

Optional:

"--downloader", "aria2c"
9. Debug slow downloads

Log timestamps:

const start = Date.now();

child.on("close", () => {
  console.log("Download time:", Date.now() - start);
});
10. Expected result

After implementation:

✅ Instant progress updates (no UI freeze)
✅ No timeouts from waiting blindly
✅ Users see % progress, speed, ETA
✅ Railway stays responsive
✅ Debugging becomes trivial
⚠️ Root cause of your current “timeout”

From everything you showed:

yt-dlp works ✅
API responds ✅
Jobs queue correctly ✅

BUT:

👉 You don’t stream progress, so frontend waits blindly → looks like timeout
👉 Large video + no feedback = perceived failure