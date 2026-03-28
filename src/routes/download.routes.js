const express = require("express");
const router = express.Router();
const controller = require("../controllers/download.controller");
const { streamJob } = require("../controllers/stream.controller");
const { downloadLimiter } = require("../middlewares/rateLimiter.middleware");

router.get("/queue/metrics", controller.getQueueMetrics);
router.get("/stream/:jobId", streamJob);
router.post("/", downloadLimiter, controller.createDownload);
router.get("/:id", controller.getStatus);

module.exports = router;
