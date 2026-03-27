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

    // Report progress so callers can poll
    await job.updateProgress(5);

    let result;
    try {
      result = await runDownload(url, format, job.id);
    } catch (err) {
      logger.error("Download failed", { jobId: job.id, error: err.message });
      throw err; // BullMQ will retry per backoff config
    }

    await job.updateProgress(100);

    logger.info("Job completed", { jobId: job.id, filename: result.filename });
    return {
      filename: result.filename,
      filePath: result.filePath,
      downloadUrl: `${process.env.BASE_URL || "http://localhost:3000"}/files/${encodeURIComponent(result.filename)}`,
    };
  },
  {
    connection: getRedisClient(),
    concurrency: CONCURRENCY,
    limiter: {
      max: CONCURRENCY,
      duration: 1000,
    },
  }
);

worker.on("active", (job) => {
  logger.info("Job active", { jobId: job.id });
});

worker.on("completed", (job, returnValue) => {
  logger.info("Job completed", { jobId: job.id, filename: returnValue?.filename });
});

worker.on("failed", (job, err) => {
  logger.error("Job failed", {
    jobId: job?.id,
    attemptsMade: job?.attemptsMade,
    error: err.message,
  });
});

worker.on("progress", (job, progress) => {
  logger.debug("Job progress", { jobId: job.id, progress });
});

worker.on("error", (err) => {
  logger.error("Worker error", { error: err.message });
});

// Graceful shutdown
async function shutdown(signal) {
  logger.info(`${signal} received — shutting down worker`);
  await worker.close();
  process.exit(0);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

logger.info("Download worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });