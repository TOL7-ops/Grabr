require("dotenv").config();
const { Worker }                     = require("bullmq");
const { getRedisClient }             = require("../config/redis");
const { runDownload, sendProgress }  = require("../services/download.service");
const logger                         = require("../utils/logger");
const { QUEUE_NAME }                 = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

const worker = new Worker(QUEUE_NAME, async (job) => {
  const { url, format } = job.data;
  logger.info("Job started", { jobId: job.id, url, format });

  /*
   * onProgress is called by runDownload's emit() on every event.
   * progressData is always an object: { status, percent, speed?, eta?, ... }
   *
   * Two things MUST happen here:
   *   1. job.updateProgress(pct)   → BullMQ (enables polling fallback)
   *   2. sendProgress(jobId, data) → SSE stream (what the browser actually sees)
   *
   * Previously only #1 happened — that's why the UI was stuck.
   */
  const onProgress = async (progressData) => {
    const pct = typeof progressData === "object"
      ? Math.floor(progressData.percent || 0)
      : Math.floor(Number(progressData) || 0);

    // 1. BullMQ progress
    try { await job.updateProgress(pct); } catch {}

    // 2. SSE — CRITICAL: this is what sends data to the browser
    sendProgress(String(job.id), typeof progressData === "object"
      ? progressData
      : { status: "downloading", percent: pct }
    );
  };

  let result;
  try {
    result = await runDownload(url, format, job.id, onProgress);
  } catch (err) {
    logger.error("Download failed", { jobId: job.id, error: err.message });
    throw err;
  }

  const baseUrl = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
  return {
    filename:    result.filename,
    filePath:    result.filePath,
    downloadUrl: result.fileUrl || `${baseUrl}/files/${encodeURIComponent(result.filename)}`,
    mediaType:   result.mediaType || "file",
  };
}, {
  connection: getRedisClient(),
  concurrency: CONCURRENCY,
  limiter: { max: CONCURRENCY, duration: 1000 },
});

worker.on("active",    j      => logger.info("Job active",    { jobId: j.id }));
worker.on("completed", (j, v) => logger.info("Job completed", { jobId: j.id, file: v?.filename }));
worker.on("failed",    (j, e) => logger.error("Job failed",   { jobId: j?.id, error: e.message }));
worker.on("error",     e      => logger.error("Worker error", { error: e.message }));

async function shutdown(sig) {
  logger.info(`${sig} — shutting down`);
  await worker.close();
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));

logger.info("Worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });
