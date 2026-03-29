const { registerSSE, unregisterSSE, sendProgress } = require("../services/download.service");
const queueService = require("../services/queue.service");
const logger = require("../utils/logger");

async function streamJob(req, res) {
  const { jobId } = req.params;
  if (!jobId || !/^[\w-]+$/.test(jobId)) return res.status(400).json({ error: "Invalid job ID" });

  res.setHeader("Content-Type",     "text/event-stream");
  res.setHeader("Cache-Control",    "no-cache");
  res.setHeader("Connection",       "keep-alive");
  res.setHeader("X-Accel-Buffering","no");
  res.flushHeaders();

  const ping = setInterval(() => { try { res.write(": ping\n\n"); } catch { clearInterval(ping); } }, 20_000);
  registerSSE(jobId, res);
  logger.info("SSE connected", { jobId });

  // Late-join: check if already finished
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
      const pct = job.progress || 0;
      if (pct > 0) sendProgress(jobId, { status: "downloading", percent: pct });
    }
  } catch (e) { logger.warn("SSE late-join failed", { jobId, error: e.message }); }

  function cleanup() {
    clearInterval(ping);
    unregisterSSE(jobId);
    logger.info("SSE disconnected", { jobId });
    try { res.end(); } catch {}
  }
  req.on("close",  cleanup);
  req.on("error",  cleanup);
  res.on("error",  cleanup);
  res.on("finish", cleanup);
}
module.exports = { streamJob };
