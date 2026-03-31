require("dotenv").config();
const { Worker }                     = require("bullmq");
const { getRedisClient }             = require("../config/redis");
const { runDownload, sendProgress }  = require("../services/download.service");
const logger                         = require("../utils/logger");
const { QUEUE_NAME }                 = require("../services/queue.service");

const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY, 10) || 2;

let worker;
try {
  worker = new Worker(QUEUE_NAME, async (job) => {
    const { url, format } = job.data;
    logger.info("Job started", { jobId: job.id, url, format });

    const onProgress = async (progressData) => {
      const pct = typeof progressData === "object"
        ? Math.floor(progressData.percent || 0)
        : Math.floor(Number(progressData) || 0);

      // 1. BullMQ progress (polling fallback)
      try { await job.updateProgress(pct); } catch {}

      // 2. SSE — sends data to browser via shared sseClients Map
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

    const baseUrl = (process.env.BASE_URL || config?.baseUrl || "http://localhost:3000").replace(/\/$/, "");
    return {
      filename:    result.filename,
      filePath:    result.filePath,
      downloadUrl: result.fileUrl || `${baseUrl}/files/${encodeURIComponent(result.filename)}`,
      mediaType:   result.mediaType || "file",
    };
  }, {
    connection:  getRedisClient(),
    concurrency: CONCURRENCY,
    limiter:     { max: CONCURRENCY, duration: 1000 },
  });

  worker.on("active",    j      => logger.info("Job active",    { jobId: j.id }));
  worker.on("completed", (j, v) => logger.info("Job completed", { jobId: j.id, file: v?.filename }));
  worker.on("failed",    (j, e) => logger.error("Job failed",   { jobId: j?.id, error: e.message }));
  worker.on("error",     e      => logger.error("Worker error", { error: e.message }));

  logger.info("Worker ready", { concurrency: CONCURRENCY, queue: QUEUE_NAME });

} catch (err) {
  logger.error("Worker init failed", { error: err.message });
  // Don't exit — if embedded, API still runs
  if (require.main === module) process.exit(1);
}

// Only set up shutdown handlers when run standalone
if (require.main === module) {
  async function shutdown(sig) {
    logger.info(`${sig} — shutting down worker`);
    if (worker) await worker.close();
    process.exit(0);
  }
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT",  () => shutdown("SIGINT"));
}

module.exports = worker;
