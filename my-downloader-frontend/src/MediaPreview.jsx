import { useState } from "react";
import { API_BASE, safeStr } from "./api";

export default function MediaPreview({ job }) {
  const [playing, setPlaying] = useState(false);
  const [copied, setCopied]   = useState(false);

  if (!job || job.state !== "completed" || !job.result) return null;

  const { filename, downloadUrl, mediaType } = job.result;
  const safeName = safeStr(filename);
  const safeUrl  = safeStr(downloadUrl);
  const type     = safeStr(mediaType || "file");

  // Build the correct URL
  const fileHref = safeUrl.startsWith("http")
    ? safeUrl
    : `${API_BASE}/files/${encodeURIComponent(safeName)}`;

  const copyLink = async () => {
    await navigator.clipboard.writeText(fileHref);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="media-preview">
      {/* Video player */}
      {type === "video" && (
        <div className="media-player">
          {!playing ? (
            <button className="play-btn" onClick={() => setPlaying(true)}>
              <div className="play-thumb">
                <span className="play-icon">▶</span>
              </div>
              <span className="play-label">Preview video</span>
            </button>
          ) : (
            <video
              className="video-el"
              src={fileHref}
              controls
              autoPlay
              playsInline
            >
              Your browser does not support video playback.
            </video>
          )}
        </div>
      )}

      {/* Audio player */}
      {type === "audio" && (
        <div className="media-player media-audio">
          <span className="audio-icon">🎵</span>
          <audio className="audio-el" src={fileHref} controls />
        </div>
      )}

      {/* File info + actions */}
      <div className="media-info">
        <p className="media-filename">
          {type === "video" ? "🎬" : type === "audio" ? "🎵" : "📄"} {safeName}
        </p>
        <div className="media-actions">
          <a href={fileHref} download={safeName} className="mb primary">
            ⬇ Save file
          </a>
          <button className="mb secondary" onClick={copyLink}>
            {copied ? "✓ Copied!" : "🔗 Copy link"}
          </button>
        </div>
      </div>
    </div>
  );
}
