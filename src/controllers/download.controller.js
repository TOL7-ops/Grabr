const queueService = require("../services/queue.service");
const storageService = require("../services/storage.service");
const { validateUrl, validateFormat } = require("../utils/validator");
const logger = require("../utils/logger");

/**
 * POST /api/download
 * Body: { url: string, format?: string }
 */
async function createDownload(req, res, next) {
  try {
    const { url, format } = req.body;

    const urlCheck = validateUrl(url);
    if (!urlCheck.valid) {
      return res.status(400).json({ error: urlCheck.reason });
    }

    const formatCheck = validateFormat(format);
    if (!formatCheck.valid) {
      return res.status(400).json({ error: formatCheck.reason });
    }

    const job = await queueService.addDownloadJob({
      url: urlCheck.url,
      format: formatCheck.format,
    });

    return res.status(202).json({
      status: "queued",
      jobId: job.id,
      statusUrl: `${req.protocol}://${req.get("host")}/api/download/${job.id}`,
    });
  } catch (err) {
    next(err);
  }
}

/**
 * GET /api/download/:id
 * Returns job state and, when done, the download URL.
 */
async function getStatus(req, res, next) {
  try {
    const { id } = req.params;

    if (!id || !/^[\w-]+$/.test(id)) {
      return res.status(400).json({ error: "Invalid job ID" });
    }

    const job = await queueService.getJob(id);

    if (!job) {
      return res.status(404).json({ error: "Job not found" });
    }

    const state = await job.getState();
    const progress = job.progress || 0;

    const response = {
      jobId: id,
      state,        // waiting | active | completed | failed | delayed | unknown
      progress,
      createdAt: new Date(job.timestamp).toISOString(),
    };

    if (state === "completed" && job.returnvalue) {
      response.result = {
        filename: job.returnvalue.filename,
        downloadUrl: job.returnvalue.downloadUrl,
      };
    }

    if (state === "failed") {
      response.error = job.failedReason || "Unknown error";
      response.attemptsMade = job.attemptsMade;
    }

    return res.json(response);
  } catch (err) {
    next(err);
  }
}

/**
 * GET /api/download/queue/metrics
 * Returns queue health metrics.
 */
async function getQueueMetrics(req, res, next) {
  try {
    const metrics = await queueService.getQueueMetrics();
    return res.json({ queue: "downloads", metrics });
  } catch (err) {
    next(err);
  }
}

module.exports = { createDownload, getStatus, getQueueMetrics };