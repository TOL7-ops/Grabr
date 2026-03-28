require("dotenv").config();
const { Worker } = require("bullmq");
const { getRedisClient } = require("../config/redis");
const { runDownload } = require("../services/download.service");
const logger = require("../utils/logger");
const { QUEUE_NAME } = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

const worker = new Worker(
  QUEUE_NAME,
  async (job) => {
    const { url, format } = job.data;
    logger.info("Processing job", { jobId: job.id, url, format });

    const onProgress = async (pct) => { try { await job.updateProgress(pct); } catch {} };
    await onProgress(5);

    let result;
    try {
      result = await runDownload(url, format, job.id, onProgress);
    } catch (err) {
      logger.error("Download failed", { jobId: job.id, error: err.message });
      throw err;
    }

    await onProgress(100);
    const baseUrl = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
    return {
      filename:    result.filename,
      filePath:    result.filePath,
      downloadUrl: `${baseUrl}/files/${encodeURIComponent(result.filename)}`,
    };
  },
  { connection: getRedisClient(), concurrency: CONCURRENCY, limiter: { max: CONCURRENCY, duration: 1000 } }
);

worker.on("active",    (job)      => logger.info("Job active",    { jobId: job.id }));
worker.on("completed", (job, val) => logger.info("Job completed", { jobId: job.id, filename: val?.filename }));
worker.on("failed",    (job, err) => logger.error("Job failed",   { jobId: job?.id, error: err.message }));
worker.on("error",     (err)      => logger.error("Worker error", { error: err.message }));

async function shutdown(sig) { logger.info(`${sig} — shutting down`); await worker.close(); process.exit(0); }
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));

logger.info("Worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });
