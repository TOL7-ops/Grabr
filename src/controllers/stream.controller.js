const { registerSSE, unregisterSSE } = require("../services/download.service");
const queueService = require("../services/queue.service");
const logger = require("../utils/logger");

async function streamJob(req, res) {
  const { jobId } = req.params;
  if (!jobId || !/^[\w-]+$/.test(jobId)) return res.status(400).json({ error: "Invalid job ID" });

  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();

  const ping = setInterval(() => { try { res.write(": ping\n\n"); } catch { clearInterval(ping); } }, 20_000);

  registerSSE(jobId, res);

  // Late-join: job already done before client connected
  try {
    const job = await queueService.getJob(jobId);
    if (job) {
      const state = await job.getState();
      if (state === "completed" && job.returnvalue) {
        const { filename, downloadUrl } = job.returnvalue;
        res.write(`data: ${JSON.stringify({ status: "completed", percent: 100, filename, fileUrl: downloadUrl })}\n\n`);
        cleanup(); return;
      }
      if (state === "failed") {
        res.write(`data: ${JSON.stringify({ status: "error", message: job.failedReason || "Download failed" })}\n\n`);
        cleanup(); return;
      }
    }
  } catch (e) { logger.warn("SSE late-join check failed", { jobId, error: e.message }); }

  function cleanup() {
    clearInterval(ping);
    unregisterSSE(jobId);
    try { res.end(); } catch {}
  }

  req.on("close", cleanup);
  req.on("error", cleanup);
  res.on("error", cleanup);
  res.on("finish", cleanup);
}

module.exports = { streamJob };
