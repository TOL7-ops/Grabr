const { spawn, execFile } = require("child_process");
const path = require("path");
const fs = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE client registry ──────────────────────────────────────────
const sseClients = new Map();
function registerSSE(jobId, res)  { sseClients.set(String(jobId), res); }
function unregisterSSE(jobId)     { sseClients.delete(String(jobId)); }
function sendSSE(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) { logger.warn("SSE write failed", { jobId, error: e.message }); unregisterSSE(jobId); }
}

// ── Format map ───────────────────────────────────────────────────
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
  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist", "--restrict-filenames",
    "--max-filesize",        `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout",      "60",
    "--retries",             "5",
    "--fragment-retries",    "5",
    "--concurrent-fragments","4",
    "--no-cache-dir",
    "--no-part",
    "--newline",
    "--ffmpeg-location",     process.env.FFMPEG_PATH || "ffmpeg",
    "-o",                    outputTemplate,
    url,
  ];
}

const RE_PROGRESS = /\[download\]\s+([\d.]+)%\s+of\s+([\d.]+\S+)\s+at\s+([\S]+)\s+ETA\s+([\S]+)/;
const RE_MERGE    = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG   = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST     = /\[download\] Destination:\s+(.+)/;

async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(downloadDir)) fs.mkdirSync(downloadDir, { recursive: true });

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const ytdlpBin = process.env.YTDLP_PATH || "yt-dlp";
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.info("Spawning yt-dlp", { jobId, format });
  sendSSE(jobId, { status: "starting", percent: 0 });
  onProgress && onProgress(0);

  const start = Date.now();
  let outputPath = null, stdoutBuf = "", stderrBuf = "", lastPct = 0, phase = "downloading";

  return new Promise((resolve, reject) => {
    const child = spawn(ytdlpBin, args, { env: { ...process.env, PYTHONUNBUFFERED: "1" } });

    child.stdout.on("data", (chunk) => {
      stdoutBuf += chunk.toString();
      const lines = stdoutBuf.split("\n");
      stdoutBuf = lines.pop();

      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;

        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          sendSSE(jobId, { status: "processing", percent: 99 });
          onProgress && onProgress(99);
        }

        const mM = line.match(RE_MERGE);
        const fM = line.match(RE_FFMPEG);
        const dM = line.match(RE_DEST);
        if (mM) outputPath = mM[1].trim();
        else if (fM) outputPath = fM[1].trim();
        else if (dM && !outputPath) outputPath = dM[1].trim();

        const pM = line.match(RE_PROGRESS);
        if (pM) {
          const percent = parseFloat(pM[1]);
          if (percent - lastPct >= 1 || percent >= 100) {
            lastPct = percent;
            sendSSE(jobId, { status: "downloading", percent, size: pM[2], speed: pM[3], eta: pM[4] });
            onProgress && onProgress(Math.min(Math.floor(percent), 98));
          }
        }
      }
    });

    child.stderr.on("data", (chunk) => { stderrBuf += chunk.toString(); });

    child.on("close", (code) => {
      const elapsed = ((Date.now() - start) / 1000).toFixed(1);
      logger.info("yt-dlp closed", { jobId, code, elapsed: `${elapsed}s` });

      if (code !== 0) {
        const msg = stderrBuf.trim() || `yt-dlp exited with code ${code}`;
        sendSSE(jobId, { status: "error", message: msg });
        return reject(new Error(msg));
      }

      if (!outputPath || !fs.existsSync(outputPath)) {
        const files = fs.readdirSync(downloadDir)
          .filter(f => f.startsWith(String(jobId)))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(downloadDir, f)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime);
        if (!files.length) {
          const err = "Download completed but output file not found";
          sendSSE(jobId, { status: "error", message: err });
          return reject(new Error(err));
        }
        outputPath = path.join(downloadDir, files[0].name);
      }

      const filename = path.basename(outputPath);
      const baseUrl  = (process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
      const fileUrl  = `${baseUrl}/files/${encodeURIComponent(filename)}`;

      sendSSE(jobId, { status: "completed", percent: 100, filename, fileUrl });
      onProgress && onProgress(100);
      logger.info("Download complete", { jobId, filename, elapsed: `${elapsed}s` });
      resolve({ filePath: outputPath, filename });
    });

    child.on("error", (err) => {
      sendSSE(jobId, { status: "error", message: err.message });
      reject(err);
    });
  });
}

async function getMetadata(url) {
  const bin = process.env.YTDLP_PATH || "yt-dlp";
  return new Promise((resolve, reject) => {
    execFile(bin, ["--dump-json", "--no-playlist", url], { timeout: 30_000 }, (err, stdout) => {
      if (err) return reject(err);
      try {
        const d = JSON.parse(stdout);
        resolve({ title: d.title, thumbnail: d.thumbnail, duration: d.duration, uploader: d.uploader, extractor: d.extractor });
      } catch { reject(new Error("Failed to parse metadata")); }
    });
  });
}

function pruneOldFiles() {
  const dir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(dir)) return;
  const maxMs = config.storage.maxFileAgeHours * 3600 * 1000;
  const now = Date.now();
  fs.readdirSync(dir).forEach(f => {
    const full = path.join(dir, f);
    try { if (now - fs.statSync(full).mtimeMs > maxMs) { fs.unlinkSync(full); logger.info("Pruned", { f }); } }
    catch (e) { logger.warn("Prune failed", { f, error: e.message }); }
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles, registerSSE, unregisterSSE, sendSSE };
