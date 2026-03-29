const { spawn, execFile } = require("child_process");
const path   = require("path");
const fs     = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// ── SSE registry ─────────────────────────────────────────────────
const sseClients = new Map();
function registerSSE(jobId, res)  { sseClients.set(String(jobId), res); }
function unregisterSSE(jobId)     { sseClients.delete(String(jobId)); }
function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) { logger.warn("SSE write failed", { jobId }); unregisterSSE(jobId); }
}

// ── Binary resolution ─────────────────────────────────────────────
function resolveBin(envKey, candidates) {
  const fromEnv = process.env[envKey];
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv;
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return candidates[0];
}
const YTDLP_BIN  = resolveBin("YTDLP_PATH",  ["/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp", "yt-dlp"]);
const FFMPEG_BIN = resolveBin("FFMPEG_PATH",  ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "ffmpeg"]);
logger.info("Binaries resolved", { ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN });

// ── Filename sanitizer ────────────────────────────────────────────
// Replaces any char that isn't alphanumeric, dash, underscore, or dot with underscore
// Also collapses multiple underscores and trims length
function sanitizeFilename(raw) {
  return raw
    .replace(/[^\w.-]+/g, "_")   // replace bad chars
    .replace(/_+/g, "_")          // collapse repeated underscores
    .replace(/^_+|_+$/g, "")      // trim leading/trailing underscores
    .slice(0, 200);               // max length
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
  const cookiesFile = "/app/cookies/youtube.txt";
  const cookiesArgs = fs.existsSync(cookiesFile) ? ["--cookies", cookiesFile] : [];
  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist",
    "--restrict-filenames",
    "--js-runtimes",          "nodejs",
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

const RE_PROGRESS = /\[download\]\s+([\d.]+)%\s+of\s+([\d.]+\S+)\s+at\s+([\S]+)\s+ETA\s+([\S]+)/;
const RE_MERGE    = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG   = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST     = /\[download\] Destination:\s+(.+)/;

// ── runDownload ───────────────────────────────────────────────────
async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);

  if (!fs.existsSync(downloadDir)) {
    try { fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 }); }
    catch (e) { throw new Error(`Cannot create download dir ${downloadDir}: ${e.message}`); }
  }
  try { fs.accessSync(downloadDir, fs.constants.W_OK); }
  catch { throw new Error(`No write permission: ${downloadDir}. Set DOWNLOAD_PATH=/tmp/downloads`); }

  // Use sanitized template — yt-dlp --restrict-filenames helps but we double-sanitize
  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const args = buildArgs(url, format || "best", outputTemplate);

  // BASE_URL must be the public Railway URL — validated here so errors are obvious
  const baseUrl = config.baseUrl;
  if (baseUrl.includes("localhost") || baseUrl.includes("127.0.0.1")) {
    logger.warn("BASE_URL is localhost — fileUrl will be wrong in production!", { baseUrl });
  }

  logger.info("Starting download", { jobId, format, dir: downloadDir, baseUrl });

  const emit = (data) => {
    sendProgress(jobId, data);
    if (onProgress) onProgress(data, typeof data === "object" ? (data.percent || 0) : Number(data) || 0);
  };

  emit({ status: "starting", percent: 5 });

  const start = Date.now();
  let outputPath = null, stdoutBuf = "", stderrBuf = "", lastPct = 0, phase = "downloading";

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

        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          emit({ status: "processing", percent: 99 });
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
            emit({ status: "downloading", percent: Math.min(percent, 98), size: pM[2], speed: pM[3], eta: pM[4] });
          }
        }
      }
    });

    child.stderr.on("data", chunk => { stderrBuf += chunk.toString(); });

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
          emit({ status: "error", message: "Download completed but output file not found" });
          return reject(new Error("Output file not found"));
        }
        outputPath = path.join(downloadDir, files[0].name);
      }

      // Sanitize filename for URL safety
      const rawName   = path.basename(outputPath);
      const ext       = path.extname(rawName);
      const baseName  = path.basename(rawName, ext);
      const cleanName = sanitizeFilename(baseName) + ext;

      // Rename file if needed
      const cleanPath = path.join(downloadDir, cleanName);
      if (rawName !== cleanName) {
        try { fs.renameSync(outputPath, cleanPath); outputPath = cleanPath; }
        catch { /* keep original name if rename fails */ }
      }

      const filename  = path.basename(outputPath);
      // CRITICAL: use config.baseUrl which must be set to Railway URL in production
      const fileUrl   = `${baseUrl}/files/${encodeURIComponent(filename)}`;
      const mediaType = [".mp4",".webm",".mkv",".mov"].includes(ext.toLowerCase()) ? "video"
                      : [".mp3",".m4a",".ogg",".wav",".opus"].includes(ext.toLowerCase()) ? "audio"
                      : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });
      logger.info("Download complete", { jobId, filename, fileUrl, elapsed: `${elapsed}s` });
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
    execFile(YTDLP_BIN, ["--dump-json", "--no-playlist", "--js-runtimes", "nodejs", url],
      { timeout: 30_000 }, (err, stdout) => {
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
    try { if (now - fs.statSync(full).mtimeMs > maxMs) { fs.unlinkSync(full); } }
    catch {}
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles, registerSSE, unregisterSSE, sendProgress };
