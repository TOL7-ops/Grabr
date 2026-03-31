const { spawn, execFile } = require("child_process");
const path   = require("path");
const fs     = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE registry ──────────────────────────────────────────────────
const sseClients = new Map();

function registerSSE(jobId, res) {
  sseClients.set(String(jobId), res);
  logger.info("SSE registered", { jobId, clients: sseClients.size });
}
function unregisterSSE(jobId) {
  sseClients.delete(String(jobId));
}
function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) {
    logger.warn("SSE write failed", { jobId });
    unregisterSSE(jobId);
  }
}

// ── Binary resolution ─────────────────────────────────────────────
function resolveBin(envKey, candidates) {
  const v = process.env[envKey];
  if (v && fs.existsSync(v)) return v;
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return candidates[0];
}
const YTDLP_BIN  = resolveBin("YTDLP_PATH",  ["/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp", "yt-dlp"]);
const FFMPEG_BIN = resolveBin("FFMPEG_PATH",  ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "ffmpeg"]);
// Node.js binary full path — needed for yt-dlp JS runtime
const NODE_BIN   = process.execPath || resolveBin("", ["/usr/local/bin/node", "/usr/bin/node", "node"]);

logger.info("Binaries", { ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN, node: NODE_BIN });

// ── Filename sanitizer ────────────────────────────────────────────
function sanitizeFilename(raw) {
  return raw.replace(/[^\w.-]+/g, "_").replace(/_+/g, "_")
            .replace(/^_+|_+$/g, "").slice(0, 200);
}

// ── Format map ────────────────────────────────────────────────────
const FORMAT_MAP = {
  mp4:   ["-f", "bestvideo+bestaudio/best", "--merge-output-format", "mp4"],
  mp3:   ["-f", "bestaudio/best", "--extract-audio", "--audio-format", "mp3"],
  webm:  ["-f", "bestvideo+bestaudio/best", "--merge-output-format", "webm"],
  m4a:   ["-f", "bestaudio/best", "--extract-audio", "--audio-format", "m4a"],
  "720p":  ["-f", "bestvideo[height<=720]+bestaudio/best[height<=720]",   "--merge-output-format", "mp4"],
  "1080p": ["-f", "bestvideo[height<=1080]+bestaudio/best[height<=1080]", "--merge-output-format", "mp4"],
  "480p":  ["-f", "bestvideo[height<=480]+bestaudio/best[height<=480]",   "--merge-output-format", "mp4"],
  "360p":  ["-f", "bestvideo[height<=360]+bestaudio/best[height<=360]",   "--merge-output-format", "mp4"],
  best:    ["-f", "bestvideo+bestaudio/best", "--merge-output-format", "mp4"],
};

function buildArgs(url, format, outputTemplate) {
  // Cookies: check /app/cookies/youtube.txt (inside Docker)
  // and local path (for dev)
  const cookiesPaths = [
    "/app/cookies/youtube.txt",
    path.join(__dirname, "../../cookies/youtube.txt"),
  ];
  const cookiesFile = cookiesPaths.find(p => fs.existsSync(p));
  const cookiesArgs = cookiesFile ? ["--cookies", cookiesFile] : [];

  if (cookiesFile) logger.info("Using cookies", { path: cookiesFile });
  else logger.warn("No cookies file found — YouTube may block bot");

  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist",
    "--restrict-filenames",
    // CORRECT flag: "node" not "nodejs" — with full path to binary
    "--js-runtimes",          `node:${NODE_BIN}`,
    "--max-filesize",         `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout",       "60",
    "--retries",              "5",
    "--fragment-retries",     "5",
    "--concurrent-fragments", "4",
    "--no-cache-dir",
    "--no-part",
    "--newline",
    "--ffmpeg-location",      FFMPEG_BIN,
    ...cookiesArgs,
    "-o",                     outputTemplate,
    url,
  ];
}

// ── Progress regexes ──────────────────────────────────────────────
// yt-dlp outputs several formats — handle all of them:
// [download]  42.3% of   10.00MiB at    1.23MiB/s ETA 00:05
// [download]  42.3% of ~  10.00MiB at    1.23MiB/s ETA 00:05 (frag 3/7)
// [download] 100% of    3.29MiB in 00:00:00 at 4.14MiB/s
const RE_PROGRESS_FULL = /\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\S+)\s+at\s+([\d.]+\S+)\s+ETA\s+([\d:]+)/;
const RE_PROGRESS_DONE = /\[download\]\s+100%\s+of\s+~?\s*([\d.]+\S+)\s+in\s+([\d:]+)/;
const RE_FRAG          = /\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\S+).*\(frag\s+(\d+)\/(\d+)\)/;
const RE_MERGE         = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG        = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST          = /\[download\] Destination:\s+(.+)/;

// ── runDownload ───────────────────────────────────────────────────
async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(downloadDir)) {
    try { fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 }); }
    catch (e) { throw new Error(`Cannot create dir ${downloadDir}: ${e.message}`); }
  }
  try { fs.accessSync(downloadDir, fs.constants.W_OK); }
  catch { throw new Error(`No write permission: ${downloadDir}`); }

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.info("Spawning yt-dlp", { jobId, bin: YTDLP_BIN, dir: downloadDir });

  // emit: single function that pushes to BOTH SSE and BullMQ via onProgress
  // Always sends objects — never plain numbers
  const emit = (data) => {
    // Direct SSE push
    sendProgress(String(jobId), data);
    // Also call worker callback for BullMQ progress
    if (onProgress) {
      const pct = typeof data === "object" ? (data.percent || 0) : Number(data) || 0;
      try { onProgress(data, pct); } catch {}
    }
  };

  // Send starting event — as object, never plain number
  emit({ status: "starting", percent: 5 });

  const start = Date.now();
  let outputPath = null;
  let stdoutBuf  = "";
  let stderrBuf  = "";
  let lastPct    = 0;
  let phase      = "downloading";

  return new Promise((resolve, reject) => {
    const child = spawn(YTDLP_BIN, args, {
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });

    child.stdout.on("data", chunk => {
      stdoutBuf += chunk.toString();
      const lines = stdoutBuf.split("\n");
      stdoutBuf = lines.pop();

      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;
        logger.debug("yt-dlp", { jobId, line });

        // Phase switch
        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          emit({ status: "processing", percent: 99 });
        }

        // Capture output path
        const mM = line.match(RE_MERGE);
        const fM = line.match(RE_FFMPEG);
        const dM = line.match(RE_DEST);
        if (mM) outputPath = mM[1].trim();
        else if (fM) outputPath = fM[1].trim();
        else if (dM && !outputPath) outputPath = dM[1].trim();

        // Parse progress — try all regex variants
        let percent = null, size = "", speed = "", eta = "";

        const fullM = line.match(RE_PROGRESS_FULL);
        const doneM = line.match(RE_PROGRESS_DONE);
        const fragM = line.match(RE_FRAG);

        if (fullM) {
          percent = parseFloat(fullM[1]);
          size    = fullM[2];
          speed   = fullM[3];
          eta     = fullM[4];
        } else if (fragM) {
          // Fragment download: calculate % from frag count
          const frag  = parseInt(fragM[3]);
          const total = parseInt(fragM[4]);
          percent = Math.round((frag / total) * 100);
          size    = fragM[2];
          speed   = "";
          eta     = "";
        } else if (doneM) {
          percent = 100;
          size    = doneM[1];
          speed   = "";
          eta     = "0:00";
        }

        if (percent !== null && (percent - lastPct >= 1 || percent >= 100)) {
          lastPct = percent;
          emit({
            status:  "downloading",
            percent: Math.min(percent, 98),
            size,
            speed,
            eta,
          });
        }
      }
    });

    child.stderr.on("data", chunk => {
      const text = chunk.toString();
      stderrBuf += text;
      // Log warnings in real time so they show in Railway logs
      text.split("\n").forEach(line => {
        if (line.trim()) logger.debug("yt-dlp stderr", { jobId, line: line.trim() });
      });
    });

    child.on("close", code => {
      const elapsed = ((Date.now() - start) / 1000).toFixed(1);
      logger.info("yt-dlp exit", { jobId, code, elapsed: `${elapsed}s` });

      if (code !== 0) {
        const msg = stderrBuf.trim() || `yt-dlp exited with code ${code}`;
        emit({ status: "error", message: msg });
        return reject(new Error(msg));
      }

      // Find output file
      if (!outputPath || !fs.existsSync(outputPath)) {
        const files = fs.readdirSync(downloadDir)
          .filter(f => f.startsWith(String(jobId)))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(downloadDir, f)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime);
        if (!files.length) {
          emit({ status: "error", message: "Output file not found after download" });
          return reject(new Error("Output file not found"));
        }
        outputPath = path.join(downloadDir, files[0].name);
      }

      // Sanitize filename
      const rawName   = path.basename(outputPath);
      const ext       = path.extname(rawName);
      const cleanName = sanitizeFilename(path.basename(rawName, ext)) + ext;
      const cleanPath = path.join(downloadDir, cleanName);
      if (rawName !== cleanName && !fs.existsSync(cleanPath)) {
        try { fs.renameSync(outputPath, cleanPath); outputPath = cleanPath; } catch {}
      }

      const filename  = path.basename(outputPath);
      const baseUrl   = config.baseUrl.replace(/\/$/, "");
      const fileUrl   = `${baseUrl}/files/${encodeURIComponent(filename)}`;
      const mediaType = [".mp4",".webm",".mkv",".mov"].includes(ext.toLowerCase()) ? "video"
                      : [".mp3",".m4a",".ogg",".wav",".opus"].includes(ext.toLowerCase()) ? "audio"
                      : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });
      logger.info("Complete", { jobId, filename, fileUrl, elapsed: `${elapsed}s` });
      resolve({ filePath: outputPath, filename, fileUrl, mediaType });
    });

    child.on("error", err => {
      emit({ status: "error", message: err.message });
      reject(err);
    });
  });
}

async function getMetadata(url) {
  return new Promise((resolve, reject) => {
    execFile(YTDLP_BIN,
      ["--dump-json", "--no-playlist", `--js-runtimes`, `node:${NODE_BIN}`, url],
      { timeout: 30_000 },
      (err, stdout) => {
        if (err) return reject(err);
        try {
          const d = JSON.parse(stdout);
          resolve({ title: d.title, thumbnail: d.thumbnail, duration: d.duration, uploader: d.uploader, extractor: d.extractor });
        } catch { reject(new Error("Failed to parse metadata")); }
      });
  });
}

function pruneOldFiles() {
  const dir = config.storage.downloadPath;
  if (!fs.existsSync(dir)) return;
  const maxMs = config.storage.maxFileAgeHours * 3600 * 1000;
  const now = Date.now();
  fs.readdirSync(dir).forEach(f => {
    const full = path.join(dir, f);
    try { if (now - fs.statSync(full).mtimeMs > maxMs) fs.unlinkSync(full); } catch {}
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles, registerSSE, unregisterSSE, sendProgress };
