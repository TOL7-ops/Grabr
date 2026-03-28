const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");
const path = require("path");

const downloadRoutes = require("./routes/download.routes");
const { notFound, errorHandler } = require("./middlewares/error.middleware");
const config = require("./config");
const logger = require("./utils/logger");

const app = express();

app.set("trust proxy", 1);

// CORS — allow any vercel.app subdomain + explicit CORS_ORIGIN
const allowedOrigins = [
  /https:\/\/.*\.vercel\.app$/,
  /http:\/\/localhost:\d+$/,
];

if (process.env.CORS_ORIGIN) {
  allowedOrigins.push(process.env.CORS_ORIGIN);
}

app.use(
  cors({
    origin: (origin, callback) => {
      // Allow requests with no origin (curl, mobile apps, Postman)
      if (!origin) return callback(null, true);
      const allowed =
        allowedOrigins.some((o) =>
          typeof o === "string" ? o === origin : o.test(origin)
        );
      if (allowed) return callback(null, true);
      logger.warn("CORS blocked", { origin });
      callback(new Error(`CORS: origin ${origin} not allowed`));
    },
    methods: ["GET", "POST", "OPTIONS"],
    allowedHeaders: ["Content-Type", "Authorization"],
    credentials: false,
  })
);

app.use(helmet({ crossOriginResourcePolicy: { policy: "cross-origin" } }));

app.use(
  morgan("combined", {
    stream: { write: (msg) => logger.http(msg.trim()) },
    skip: () => config.nodeEnv === "test",
  })
);

app.use(express.json({ limit: "10kb" }));

// Serve downloaded files
app.use(
  "/files",
  (req, res, next) => {
    const decoded = decodeURIComponent(req.path.replace(/^\//, ""));
    if (decoded.includes("..") || decoded.includes("/") || decoded.includes("\\")) {
      return res.status(400).json({ error: "Invalid filename" });
    }
    next();
  },
  express.static(path.resolve(config.storage.downloadPath), {
    dotfiles: "deny",
    index: false,
  })
);

app.use("/api/download", downloadRoutes);

app.get("/debug/path", (_req, res) => {
  const config = require("./config");
  const fs = require("fs");
  const dir = config.storage.downloadPath;
  const exists = fs.existsSync(dir);
  let writable = false;
  try { fs.accessSync(dir, fs.constants.W_OK); writable = true; } catch {}
  res.json({ downloadPath: dir, exists, writable, NODE_ENV: process.env.NODE_ENV, DOWNLOAD_PATH_ENV: process.env.DOWNLOAD_PATH });
});

app.get("/debug/path", (_req, res) => {
  const config = require("./config");
  const fs = require("fs");
  const dir = config.storage.downloadPath;
  const exists = fs.existsSync(dir);
  let writable = false;
  try { fs.accessSync(dir, fs.constants.W_OK); writable = true; } catch {}
  res.json({ downloadPath: dir, exists, writable, NODE_ENV: process.env.NODE_ENV, DOWNLOAD_PATH_ENV: process.env.DOWNLOAD_PATH });
});

app.get("/health", (_req, res) => {
  res.json({ status: "ok", uptime: process.uptime(), ts: new Date().toISOString() });
});

app.use(notFound);
app.use(errorHandler);

module.exports = app;