const { Queue } = require("bullmq");
const { getRedisClient } = require("../config/redis");
const logger = require("../utils/logger");

const QUEUE_NAME = "downloads";
let queue = null;

function getQueue() {
  if (!queue) {
    queue = new Queue(QUEUE_NAME, {
      connection: getRedisClient(),
      defaultJobOptions: {
        attempts:     parseInt(process.env.JOB_ATTEMPTS, 10)     || 3,
        backoff:      { type: "exponential", delay: parseInt(process.env.JOB_BACKOFF_DELAY, 10) || 5000 },
        removeOnComplete: { count: 100 },
        removeOnFail:     { count: 200 },
      },
    });
  }
  return queue;
}

async function addDownloadJob(data) {
  const q = getQueue();
  const job = await q.add("download", data);
  logger.info("Job queued", { jobId: job.id, url: data.url });
  return job;
}

async function getJob(id) {
  return getQueue().getJob(id);
}

async function getQueueMetrics() {
  const q = getQueue();
  const [waiting, active, completed, failed, delayed] = await Promise.all([
    q.getWaitingCount(), q.getActiveCount(), q.getCompletedCount(),
    q.getFailedCount(),  q.getDelayedCount(),
  ]);
  return { waiting, active, completed, failed, delayed };
}

async function closeQueue() {
  if (queue) { await queue.close(); queue = null; }
}

module.exports = { addDownloadJob, getJob, getQueueMetrics, closeQueue, QUEUE_NAME };
