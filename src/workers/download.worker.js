require("dotenv").config();
const { Worker }                       = require("bullmq");
const { getRedisClient }               = require("../config/redis");
const { runDownload, sendProgress }    = require("../services/download.service");
const logger                           = require("../utils/logger");
const { QUEUE_NAME }                   = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

const worker = new Worker(QUEUE_NAME, async (job) => {
  const { url, format } = job.data;
  logger.info("Job started", { jobId: job.id, url, format });

  // onProgress: receives full data object from runDownload's emit()
  // Updates BullMQ progress AND pushes to SSE via sendProgress
  const onProgress = async (progressData, pct) => {
    // 1. BullMQ progress (enables polling fallback)
    try { await job.updateProgress(Math.floor(pct || 0)); } catch {}
    // 2. SSE push — THIS is what sends data to the browser
    sendProgress(String(job.id), typeof progressData === "object"
      ? progressData
      : { status: "downloading", percent: pct || 0 }
    );
  };

  let result;
  try {
    result = await runDownload(url, format, job.id, onProgress);
  } catch (err) {
    logger.error("Download failed", { jobId: job.id, error: err.message });
    throw err;
  }

  return {
    filename:    result.filename,
    filePath:    result.filePath,
    downloadUrl: result.fileUrl,
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

async function shutdown(sig) { await worker.close(); process.exit(0); }
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));
logger.info("Worker started", { concurrency: CONCURRENCY, queue: QUEUE_NAME });
