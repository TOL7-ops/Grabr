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
function unregisterSSE(jobId) { sseClients.delete(String(jobId)); }
function sendProgress(jobId, data) {
  const res = sseClients.get(String(jobId));
  if (!res) return;
  try { res.write(`data: ${JSON.stringify(data)}\n\n`); }
  catch (e) { logger.warn("SSE write failed", { jobId }); unregisterSSE(jobId); }
}

// ── Binary resolution ─────────────────────────────────────────────
function resolveBin(envKey, candidates) {
  const v = process.env[envKey];
  if (v && fs.existsSync(v)) return v;
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return candidates[0];
}
const YTDLP_BIN  = resolveBin("YTDLP_PATH", ["/usr/local/bin/yt-dlp",  "/usr/bin/yt-dlp",  "yt-dlp"]);
const FFMPEG_BIN = resolveBin("FFMPEG_PATH", ["/usr/bin/ffmpeg",        "/usr/local/bin/ffmpeg", "ffmpeg"]);
const NODE_BIN   = process.execPath || "/usr/local/bin/node";
logger.info("Binaries", { ytdlp: YTDLP_BIN, ffmpeg: FFMPEG_BIN, node: NODE_BIN });

// ── Filename sanitizer ────────────────────────────────────────────
function sanitizeFilename(raw) {
  return raw.replace(/[^\w.-]+/g, "_").replace(/_+/g, "_")
            .replace(/^_+|_+$/g, "").slice(0, 180);
}

// ── Format map ────────────────────────────────────────────────────
// KEY CHANGE: force H.264 (avc1) + AAC for maximum mobile compatibility
// VP9/AV1 plays on desktop but NOT on older iOS/Android without special codecs
// Fallback chain ensures we always get a playable file
const MP4_COMPAT = [
  // H.264 video + M4A audio — plays on ALL devices
  "-f", "bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[vcodec^=avc1]+bestaudio/bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best",
  "--merge-output-format", "mp4",
  "--remux-video", "mp4",
  // faststart: move moov atom to front of file → plays immediately on mobile
  "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
];

const FORMAT_MAP = {
  mp4:   MP4_COMPAT,
  mp3:   ["-f", "bestaudio/best", "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0"],
  webm:  ["-f", "bestvideo+bestaudio/best", "--merge-output-format", "webm"],
  m4a:   ["-f", "bestaudio/best", "--extract-audio", "--audio-format", "m4a"],
  "720p":  [
    "-f", "bestvideo[vcodec^=avc1][height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best[height<=720]",
    "--merge-output-format", "mp4",
    "--remux-video", "mp4",
    "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
  ],
  "1080p": [
    "-f", "bestvideo[vcodec^=avc1][height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best[height<=1080]",
    "--merge-output-format", "mp4",
    "--remux-video", "mp4",
    "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
  ],
  "480p":  [
    "-f", "bestvideo[vcodec^=avc1][height<=480][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=480]+bestaudio/best[height<=480]",
    "--merge-output-format", "mp4",
    "--remux-video", "mp4",
    "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
  ],
  "360p":  [
    "-f", "bestvideo[vcodec^=avc1][height<=360][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=360]+bestaudio/best[height<=360]",
    "--merge-output-format", "mp4",
    "--remux-video", "mp4",
    "--postprocessor-args", "ffmpeg:-c:v copy -c:a aac -movflags faststart",
  ],
  best: MP4_COMPAT,
};

function buildArgs(url, format, outputTemplate) {
  const cookiesPaths = [
    "/app/cookies/youtube.txt",
    path.join(__dirname, "../../cookies/youtube.txt"),
  ];
  const cookiesFile = cookiesPaths.find(p => fs.existsSync(p));
  const cookiesArgs = cookiesFile ? ["--cookies", cookiesFile] : [];
  if (cookiesFile) logger.info("Using cookies", { path: cookiesFile });
  else             logger.warn("No cookies — YouTube may block");

  return [
    ...(FORMAT_MAP[format] || FORMAT_MAP.best),
    "--no-playlist",
    "--restrict-filenames",
    `--js-runtimes`, `node:${NODE_BIN}`,
    "--max-filesize",         `${config.storage.maxFileSizeMb}m`,
    "--socket-timeout",       "60",
    "--retries",              "5",
    "--fragment-retries",     "5",
    // Reduced from 4 → 2 to prevent ETIMEDOUT on Railway's network
    "--concurrent-fragments", "2",
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
// Handles all yt-dlp output formats including fragments
const RE_PROGRESS_FULL = /\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\S+)\s+at\s+([\d.]+\S+)\s+ETA\s+([\d:]+)/;
const RE_PROGRESS_DONE = /\[download\]\s+100%\s+of\s+~?\s*([\d.]+\S+)/;
const RE_FRAG          = /\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\S+).*\(frag\s+(\d+)\/(\d+)\)/;
const RE_MERGE         = /\[Merger\] Merging formats into "(.+?)"/;
const RE_FFMPEG_DEST   = /\[ffmpeg\] Destination:\s+(.+)/;
const RE_DEST          = /\[download\] Destination:\s+(.+)/;

// ── runDownload ───────────────────────────────────────────────────
async function runDownload(url, format, jobId, onProgress) {
  const downloadDir = path.resolve(config.storage.downloadPath);
  if (!fs.existsSync(downloadDir)) {
    try { fs.mkdirSync(downloadDir, { recursive: true, mode: 0o755 }); }
    catch (e) { throw new Error(`Cannot create dir: ${e.message}`); }
  }
  try { fs.accessSync(downloadDir, fs.constants.W_OK); }
  catch { throw new Error(`No write permission: ${downloadDir}`); }

  const outputTemplate = path.join(downloadDir, `${jobId}_%(title)s.%(ext)s`);
  const args = buildArgs(url, format || "best", outputTemplate);
  logger.info("Spawning yt-dlp", { jobId, bin: YTDLP_BIN, dir: downloadDir, format });

  // emit: ALWAYS sends objects, never plain numbers
  // Pushes to both SSE stream AND BullMQ via onProgress callback
  const emit = (data) => {
    sendProgress(String(jobId), data);
    if (onProgress) {
      const pct = typeof data === "object" ? (data.percent || 0) : Number(data) || 0;
      try { onProgress(data, pct); } catch {}
    }
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

        // Phase: merging / ffmpeg post-processing
        if ((line.startsWith("[Merger]") || line.startsWith("[ffmpeg]")) && phase !== "processing") {
          phase = "processing";
          emit({ status: "processing", percent: 99 });
        }

        // Capture output path
        const mM = line.match(RE_MERGE);
        const fM = line.match(RE_FFMPEG_DEST);
        const dM = line.match(RE_DEST);
        if (mM) outputPath = mM[1].trim();
        else if (fM) outputPath = fM[1].trim();
        else if (dM && !outputPath) outputPath = dM[1].trim();

        // Parse progress — try all three formats
        let percent = null, size = "", speed = "", eta = "";
        const fullM = line.match(RE_PROGRESS_FULL);
        const fragM = line.match(RE_FRAG);
        const doneM = line.match(RE_PROGRESS_DONE);

        if (fullM) {
          percent = parseFloat(fullM[1]); size = fullM[2]; speed = fullM[3]; eta = fullM[4];
        } else if (fragM) {
          percent = Math.round((parseInt(fragM[3]) / parseInt(fragM[4])) * 100);
          size = fragM[2];
        } else if (doneM) {
          percent = 100; size = doneM[1]; eta = "0:00";
        }

        if (percent !== null && (percent - lastPct >= 1 || percent >= 100)) {
          lastPct = percent;
          emit({ status: "downloading", percent: Math.min(percent, 98), size, speed, eta });
        }
      }
    });

    child.stderr.on("data", chunk => {
      const text = chunk.toString();
      stderrBuf += text;
      text.split("\n").forEach(l => { if (l.trim()) logger.debug("yt-dlp stderr", { jobId, line: l.trim() }); });
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
      const fileUrl   = `${config.baseUrl.replace(/\/$/, "")}/files/${encodeURIComponent(filename)}`;
      const mediaType = [".mp4",".webm",".mkv",".mov"].includes(ext.toLowerCase()) ? "video"
                      : [".mp3",".m4a",".ogg",".wav",".opus"].includes(ext.toLowerCase()) ? "audio"
                      : "file";

      emit({ status: "completed", percent: 100, filename, fileUrl, mediaType });
      logger.info("Complete", { jobId, filename, fileUrl, elapsed: `${elapsed}s` });
      resolve({ filePath: outputPath, filename, fileUrl, mediaType });
    });

    child.on("error", err => { emit({ status: "error", message: err.message }); reject(err); });
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
