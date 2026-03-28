require("dotenv").config();
const { Worker } = require("bullmq");
const { getRedisClient }             = require("../config/redis");
const { runDownload, sendProgress }  = require("../services/download.service");
const logger                         = require("../utils/logger");
const { QUEUE_NAME }                 = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

const worker = new Worker(
  QUEUE_NAME,
  async (job) => {
    const { url, format } = job.data;
    logger.info("Processing job", { jobId: job.id, url, format });

    // onProgress receives a structured object from runDownload:
    // { status, percent, speed?, eta?, size?, filename?, fileUrl?, message? }
    const onProgress = async (progressData) => {
      // 1. Update BullMQ (for polling fallback)
      const pct = typeof progressData === "object"
        ? (progressData.percent || 0)
        : Number(progressData) || 0;
      try { await job.updateProgress(Math.floor(pct)); } catch {}

      // 2. Push to SSE stream (THE MISSING LINK — this is what sends data to the browser)
      sendProgress(job.id, typeof progressData === "object"
        ? progressData
        : { status: "downloading", percent: pct }
      );
    };

    // Send initial queued→active transition
    await onProgress({ status: "starting", percent: 5 });

    let result;
    try {
      result = await runDownload(url, format, job.id, onProgress);
    } catch (err) {
      logger.error("Download failed", { jobId: job.id, error: err.message });
      // sendProgress already called inside runDownload on error
      throw err;
    }

    const baseUrl = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
    return {
      filename:    result.filename,
      filePath:    result.filePath,
      downloadUrl: result.fileUrl || `${baseUrl}/files/${encodeURIComponent(result.filename)}`,
      mediaType:   result.mediaType || "file",
    };
  },
  {
    connection: getRedisClient(),
    concurrency: CONCURRENCY,
    limiter: { max: CONCURRENCY, duration: 1000 },
  }
);

worker.on("active",    (job)      => logger.info("Job active",    { jobId: job.id }));
worker.on("completed", (job, val) => logger.info("Job completed", { jobId: job.id, filename: val?.filename }));
worker.on("failed",    (job, err) => logger.error("Job failed",   { jobId: job?.id, error: err.message }));
worker.on("error",     (err)      => logger.error("Worker error", { error: err.message }));

async function shutdown(sig) {
  logger.info(`${sig} — shutting down`);
  await worker.close();
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));

logger.info("Worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });
