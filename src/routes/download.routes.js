const express = require("express");
const router = express.Router();
const controller = require("../controllers/download.controller");
const { downloadLimiter } = require("../middlewares/rateLimiter.middleware");

// Queue metrics — must come before /:id to avoid swallowing "metrics" as an id
router.get("/queue/metrics", controller.getQueueMetrics);

// Submit a download
router.post("/", downloadLimiter, controller.createDownload);

// Poll job status
router.get("/:id", controller.getStatus);

module.exports = router;