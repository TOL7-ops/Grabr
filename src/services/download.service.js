const { execFile } = require("child_process");
const path = require("path");
const fs = require("fs");
const config = require("../config");
const logger = require("../utils/logger");

// Each entry is an array — no string-splitting, no hidden space bugs.
const FORMAT_MAP = {
  mp4: [
    "-f", "bestvideo+bestaudio/best",
    "--merge-output-format", "mp4",
  ],
  mp3: [
    "-f", "bestaudio/best",
    "--extract-audio",
    "--audio-format", "mp3",
  ],
  webm: [
    "-f", "bestvideo+bestaudio/best",
    "--merge-output-format", "webm",
  ],
  m4a: [
    "-f", "bestaudio/best",
    "--extract-audio",
    "--audio-format", "m4a",
  ],
  "720p": [
    "-f", "bestvideo[height<=720]+bestaudio/best[height<=720]",
    "--merge-output-format", "mp4",
  ],
  "1080p": [
    "-f", "bestvideo[height<=1080]+bestaudio/best[height<=1080]",
    "--merge-output-format", "mp4",
  ],
  "480p": [
    "-f", "bestvideo[height<=480]+bestaudio/best[height<=480]",
    "--merge-output-format", "mp4",
  ],
  "360p": [
    "-f", "bestvideo[height<=360]+bestaudio/best[height<=360]",
    "--merge-output-format", "mp4",
  ],
  best: [
    "-f", "bestvideo+bestaudio/best",
    "--merge-output-format", "mp4",
  ],
};

/**
 * Builds a safe yt-dlp argument array. Uses execFile — no shell, no injection.
 */
function buildArgs(url, format, outputTemplate) {
  const ytdlpPath = process.env.YTDLP_PATH || "yt-dlp";
  const ffmpegPath = process.env.FFMPEG_PATH || "ffmpeg";
  const formatFlags = FORMAT_MAP[format] || FORMAT_MAP.best;

  return [
    ...formatFlags,
    "--no-playlist",
    "--restrict-filenames",
    "--max-filesize", `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout", "30",
    "--retries", "3",
    "--ffmpeg-location", ffmpegPath,
    "-o", outputTemplate,
    url,
  ];
}

/**
 * Executes a yt-dlp download and returns the output file path.
 */
async function runDownload(url, format, jobId) {
  const downloadDir = path.resolve(config.storage.downloadPath);

  if (!fs.existsSync(downloadDir)) {
    fs.mkdirSync(downloadDir, { recursive: true });
  }

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const ytdlpBin = process.env.YTDLP_PATH || "yt-dlp";
  const args = buildArgs(url, format || "best", outputTemplate);

  logger.debug("Running yt-dlp", { jobId, bin: ytdlpBin, args });

  return new Promise((resolve, reject) => {
    const child = execFile(ytdlpBin, args, { timeout: 300_000 }, (err, stdout, stderr) => {
      if (err) {
        logger.error("yt-dlp failed", { jobId, stderr, code: err.code });
        return reject(new Error(stderr || err.message));
      }

      // Priority: merger output > ffmpeg output > download destination
      const mergeMatch  = stdout.match(/\[Merger\] Merging formats into "(.+?)"/);
      const ffmpegMatch = stdout.match(/\[ffmpeg\] Destination: (.+)/);
      const dlMatch     = stdout.match(/\[download\] Destination: (.+)/g);
      const lastDl      = dlMatch ? dlMatch[dlMatch.length - 1].replace("[download] Destination: ", "") : null;

      const rawPath = (mergeMatch && mergeMatch[1]) ||
                      (ffmpegMatch && ffmpegMatch[1]) ||
                      lastDl;

      if (!rawPath) {
        // Fallback: newest file with jobId prefix
        const files = fs.readdirSync(downloadDir)
          .filter((f) => f.startsWith(String(jobId)))
          .map((f) => ({ name: f, mtime: fs.statSync(path.join(downloadDir, f)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime);

        if (!files.length) {
          return reject(new Error("Download completed but output file not found"));
        }
        const filename = files[0].name;
        return resolve({ filePath: path.join(downloadDir, filename), filename });
      }

      const filePath = rawPath.trim();
      const filename = path.basename(filePath);
      resolve({ filePath, filename });
    });

    child.stdout.on("data", (d) => logger.debug("yt-dlp stdout", { jobId, data: d.trim() }));
    child.stderr.on("data", (d) => logger.debug("yt-dlp stderr", { jobId, data: d.trim() }));
  });
}

/**
 * Extracts video metadata without downloading.
 */
async function getMetadata(url) {
  const ytdlpBin = process.env.YTDLP_PATH || "yt-dlp";
  return new Promise((resolve, reject) => {
    execFile(ytdlpBin, ["--dump-json", "--no-playlist", url], (err, stdout) => {
      if (err) return reject(err);
      try {
        const data = JSON.parse(stdout);
        resolve({
          title: data.title,
          thumbnail: data.thumbnail,
          duration: data.duration,
          uploader: data.uploader,
          extractor: data.extractor,
        });
      } catch (e) {
        reject(new Error("Failed to parse metadata JSON"));
      }
    });
  });
}

/**
 * Removes files older than MAX_FILE_AGE_HOURS.
 */
function pruneOldFiles() {
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(downloadDir)) return;

  const maxAgeMs = config.storage.maxFileAgeHours * 60 * 60 * 1000;
  const now = Date.now();

  fs.readdirSync(downloadDir).forEach((file) => {
    const fullPath = path.join(downloadDir, file);
    try {
      const { mtimeMs } = fs.statSync(fullPath);
      if (now - mtimeMs > maxAgeMs) {
        fs.unlinkSync(fullPath);
        logger.info("Pruned old file", { file });
      }
    } catch (e) {
      logger.warn("Could not prune file", { file, error: e.message });
    }
  });
}

module.exports = { runDownload, getMetadata, pruneOldFiles };
