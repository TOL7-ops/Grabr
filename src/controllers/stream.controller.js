const { registerSSE, unregisterSSE, sendProgress } = require("../services/download.service");
const queueService = require("../services/queue.service");
const logger = require("../utils/logger");

async function streamJob(req, res) {
  const { jobId } = req.params;
  if (!jobId || !/^[\w-]+$/.test(jobId)) {
    return res.status(400).json({ error: "Invalid job ID" });
  }

  res.setHeader("Content-Type",    "text/event-stream");
  res.setHeader("Cache-Control",   "no-cache");
  res.setHeader("Connection",      "keep-alive");
  res.setHeader("X-Accel-Buffering","no");
  res.flushHeaders();

  // Keep-alive ping every 20s (prevents Railway/nginx from closing idle connections)
  const ping = setInterval(() => {
    try { res.write(": ping\n\n"); } catch { clearInterval(ping); }
  }, 20_000);

  registerSSE(jobId, res);
  logger.info("SSE client connected", { jobId });

  // Late-join: job finished before client opened SSE connection
  try {
    const job = await queueService.getJob(jobId);
    if (job) {
      const state = await job.getState();
      if (state === "completed" && job.returnvalue) {
        const { filename, downloadUrl, mediaType } = job.returnvalue;
        sendProgress(jobId, { status: "completed", percent: 100, filename, fileUrl: downloadUrl, mediaType: mediaType || "file" });
        cleanup(); return;
      }
      if (state === "failed") {
        sendProgress(jobId, { status: "error", message: job.failedReason || "Download failed" });
        cleanup(); return;
      }
      // Job active — send current progress so UI doesn't show 0%
      const prog = job.progress || 0;
      if (prog > 0) {
        sendProgress(jobId, { status: "downloading", percent: prog });
      }
    }
  } catch (e) {
    logger.warn("SSE late-join check failed", { jobId, error: e.message });
  }

  function cleanup() {
    clearInterval(ping);
    unregisterSSE(jobId);
    logger.info("SSE client disconnected", { jobId });
    try { res.end(); } catch {}
  }

  req.on("close",  cleanup);
  req.on("error",  cleanup);
  res.on("error",  cleanup);
  res.on("finish", cleanup);
}

module.exports = { streamJob };
