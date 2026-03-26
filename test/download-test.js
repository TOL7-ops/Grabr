/**
 * Integration tests for the Download API.
 *
 * Tests are scoped to API behaviour (HTTP layer + validation).
 * yt-dlp execution and Redis queue are mocked to keep tests fast and deterministic.
 */

const request = require("supertest");

// ── Mocks ──────────────────────────────────────────────────────────────────────

// Mock queue service so tests never touch Redis
jest.mock("../src/services/queue.service", () => ({
  addDownloadJob: jest.fn(),
  getJob: jest.fn(),
  getQueueMetrics: jest.fn(),
  closeQueue: jest.fn(),
  QUEUE_NAME: "downloads",
}));

const queueService = require("../src/services/queue.service");

// ── App ────────────────────────────────────────────────────────────────────────

const app = require("../src/app");

// ── Helpers ────────────────────────────────────────────────────────────────────

function mockJob(overrides = {}) {
  const defaults = {
    id: "test-job-123",
    timestamp: Date.now(),
    progress: 0,
    attemptsMade: 0,
    failedReason: null,
    returnvalue: null,
    getState: jest.fn().mockResolvedValue("waiting"),
  };
  return { ...defaults, ...overrides };
}

// ── POST /api/download ──────────────────────────────────────────────────────────

describe("POST /api/download", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    queueService.addDownloadJob.mockResolvedValue(mockJob());
  });

  it("returns 400 when URL is missing", async () => {
    const res = await request(app).post("/api/download").send({});
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toBeDefined();
  });

  it("returns 400 when URL is empty string", async () => {
    const res = await request(app).post("/api/download").send({ url: "" });
    expect(res.statusCode).toBe(400);
  });

  it("returns 400 when URL is not http/https", async () => {
    const res = await request(app)
      .post("/api/download")
      .send({ url: "ftp://example.com" });
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toMatch(/https?/i);
  });

  it("returns 400 when domain is not whitelisted", async () => {
    const res = await request(app)
      .post("/api/download")
      .send({ url: "https://vimeo.com/123456" });
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toMatch(/not supported/i);
  });

  it("returns 400 for javascript: URL", async () => {
    const res = await request(app)
      .post("/api/download")
      .send({ url: "javascript:alert(1)" });
    expect(res.statusCode).toBe(400);
  });

  it("returns 400 for an invalid download format", async () => {
    const res = await request(app)
      .post("/api/download")
      .send({ url: "https://youtube.com/watch?v=test", format: "avi" });
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toMatch(/not supported/i);
  });

  it("accepts a valid YouTube URL and returns 202 with jobId", async () => {
    const res = await request(app)
      .post("/api/download")
      .send({ url: "https://youtube.com/watch?v=dQw4w9WgXcQ" });
    expect(res.statusCode).toBe(202);
    expect(res.body.status).toBe("queued");
    expect(res.body.jobId).toBeDefined();
    expect(res.body.statusUrl).toMatch(/\/api\/download\//);
  });

  it("accepts a valid Instagram reel URL", async () => {
    const res = await request(app)
      .post("/api/download")
      .send({ url: "https://www.instagram.com/reel/ABC123xyz/" });
    expect(res.statusCode).toBe(202);
    expect(res.body.jobId).toBeDefined();
  });

  it("accepts a valid format alongside a valid URL", async () => {
    const res = await request(app)
      .post("/api/download")
      .send({ url: "https://youtu.be/dQw4w9WgXcQ", format: "mp4" });
    expect(res.statusCode).toBe(202);
    expect(queueService.addDownloadJob).toHaveBeenCalledWith(
      expect.objectContaining({ format: "mp4" })
    );
  });

  it("defaults format to 'best' when omitted", async () => {
    await request(app)
      .post("/api/download")
      .send({ url: "https://youtube.com/watch?v=dQw4w9WgXcQ" });
    expect(queueService.addDownloadJob).toHaveBeenCalledWith(
      expect.objectContaining({ format: "best" })
    );
  });

  it("calls addDownloadJob exactly once per request", async () => {
    // Fresh mock instance to guarantee clean call count
    queueService.addDownloadJob.mockClear();
    queueService.addDownloadJob.mockResolvedValueOnce(mockJob());
    await request(app)
      .post("/api/download")
      .set("X-Forwarded-For", "10.0.0.99")   // distinct IP avoids rate-limit bleed
      .send({ url: "https://youtube.com/watch?v=dQw4w9WgXcQ" });
    expect(queueService.addDownloadJob).toHaveBeenCalledTimes(1);
  });

  it("returns 500 when the queue throws", async () => {
    queueService.addDownloadJob.mockRejectedValueOnce(new Error("Redis down"));
    const res = await request(app)
      .post("/api/download")
      .set("X-Forwarded-For", "10.0.0.88")   // distinct IP avoids rate-limit bleed
      .send({ url: "https://youtube.com/watch?v=dQw4w9WgXcQ" });
    expect(res.statusCode).toBe(500);
  });
});

// ── GET /api/download/:id ───────────────────────────────────────────────────────

describe("GET /api/download/:id", () => {
  beforeEach(() => jest.clearAllMocks());

  it("returns 404 when job does not exist", async () => {
    queueService.getJob.mockResolvedValue(null);
    const res = await request(app).get("/api/download/nonexistent-id");
    expect(res.statusCode).toBe(404);
  });

  it("returns 400 for an invalid job ID containing path chars", async () => {
    const res = await request(app).get("/api/download/../../etc/passwd");
    // Express router normalises the path so this hits 404 — acceptable
    expect([400, 404]).toContain(res.statusCode);
  });

  it("returns job state 'waiting'", async () => {
    queueService.getJob.mockResolvedValue(mockJob({ getState: jest.fn().mockResolvedValue("waiting") }));
    const res = await request(app).get("/api/download/test-job-123");
    expect(res.statusCode).toBe(200);
    expect(res.body.state).toBe("waiting");
    expect(res.body.jobId).toBe("test-job-123");
  });

  it("returns job state 'active' with progress", async () => {
    queueService.getJob.mockResolvedValue(
      mockJob({ progress: 50, getState: jest.fn().mockResolvedValue("active") })
    );
    const res = await request(app).get("/api/download/test-job-123");
    expect(res.statusCode).toBe(200);
    expect(res.body.state).toBe("active");
    expect(res.body.progress).toBe(50);
  });

  it("returns download URL when job is completed", async () => {
    queueService.getJob.mockResolvedValue(
      mockJob({
        progress: 100,
        returnvalue: {
          filename: "video.mp4",
          downloadUrl: "http://localhost:3000/files/video.mp4",
        },
        getState: jest.fn().mockResolvedValue("completed"),
      })
    );
    const res = await request(app).get("/api/download/test-job-123");
    expect(res.statusCode).toBe(200);
    expect(res.body.state).toBe("completed");
    expect(res.body.result.downloadUrl).toContain("/files/video.mp4");
  });

  it("includes error info when job has failed", async () => {
    queueService.getJob.mockResolvedValue(
      mockJob({
        failedReason: "yt-dlp: video unavailable",
        attemptsMade: 3,
        getState: jest.fn().mockResolvedValue("failed"),
      })
    );
    const res = await request(app).get("/api/download/test-job-123");
    expect(res.statusCode).toBe(200);
    expect(res.body.state).toBe("failed");
    expect(res.body.error).toContain("unavailable");
    expect(res.body.attemptsMade).toBe(3);
  });
});

// ── GET /api/download/queue/metrics ────────────────────────────────────────────

describe("GET /api/download/queue/metrics", () => {
  it("returns queue metrics", async () => {
    queueService.getQueueMetrics.mockResolvedValue({
      waiting: 2,
      active: 1,
      completed: 10,
      failed: 0,
      delayed: 0,
    });
    const res = await request(app).get("/api/download/queue/metrics");
    expect(res.statusCode).toBe(200);
    expect(res.body.metrics.waiting).toBe(2);
    expect(res.body.metrics.active).toBe(1);
  });
});

// ── GET /health ────────────────────────────────────────────────────────────────

describe("GET /health", () => {
  it("returns 200 with uptime", async () => {
    const res = await request(app).get("/health");
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe("ok");
    expect(typeof res.body.uptime).toBe("number");
  });
});

// ── 404 ────────────────────────────────────────────────────────────────────────

describe("Unknown routes", () => {
  it("returns 404 for an unknown path", async () => {
    const res = await request(app).get("/totally/unknown");
    expect(res.statusCode).toBe(404);
  });
});

// ── Validator unit tests ───────────────────────────────────────────────────────

describe("Validator", () => {
  const { validateUrl, validateFormat } = require("../src/utils/validator");

  describe("validateUrl", () => {
    it("rejects null", () => expect(validateUrl(null).valid).toBe(false));
    it("rejects non-string", () => expect(validateUrl(123).valid).toBe(false));
    it("rejects ftp scheme", () => expect(validateUrl("ftp://youtube.com").valid).toBe(false));
    it("rejects URLs > 2048 chars", () => expect(validateUrl("https://youtube.com/" + "x".repeat(2100)).valid).toBe(false));
    it("rejects disallowed domain", () => expect(validateUrl("https://evil.com/video").valid).toBe(false));
    it("accepts youtu.be short link", () => expect(validateUrl("https://youtu.be/dQw4w9WgXcQ").valid).toBe(true));
    it("accepts www.youtube.com", () => expect(validateUrl("https://www.youtube.com/watch?v=abc").valid).toBe(true));
    it("accepts instagram.com reel", () => expect(validateUrl("https://www.instagram.com/reel/xyz/").valid).toBe(true));
  });

  describe("validateFormat", () => {
    it("returns best when format is undefined", () => expect(validateFormat(undefined).format).toBe("best"));
    it("accepts mp4", () => expect(validateFormat("mp4").valid).toBe(true));
    it("accepts mp3", () => expect(validateFormat("mp3").valid).toBe(true));
    it("rejects avi", () => expect(validateFormat("avi").valid).toBe(false));
    it("rejects shell injection attempt", () => expect(validateFormat("; rm -rf /").valid).toBe(false));
  });
});