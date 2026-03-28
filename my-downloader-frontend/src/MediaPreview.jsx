import { useState } from "react";
import { API_BASE, safeStr, downloadFile } from "./api";

export default function MediaPreview({ job }) {
  const [playing,  setPlaying]  = useState(false);
  const [downloading, setDl]    = useState(false);
  const [copied,   setCopied]   = useState(false);

  if (!job || job.state !== "completed" || !job.result) return null;

  const filename  = safeStr(job.result.filename);
  const mediaType = safeStr(job.result.mediaType || "file");
  const fileUrl   = safeStr(job.result.downloadUrl).startsWith("http")
    ? safeStr(job.result.downloadUrl)
    : `${API_BASE}/files/${encodeURIComponent(filename)}`;

  const handleDownload = async () => {
    setDl(true);
    await downloadFile(fileUrl, filename);
    setDl(false);
  };

  const handleCopy = async () => {
    await navigator.clipboard.writeText(fileUrl).catch(() => {});
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="mpreview">

      {/* Video inline player */}
      {mediaType === "video" && (
        <div className="mplayer">
          {!playing ? (
            <button className="mplay-btn" onClick={() => setPlaying(true)}>
              <div className="mplay-circle">▶</div>
              <span className="mplay-hint">Tap to preview</span>
            </button>
          ) : (
            <video
              className="mvideo"
              src={fileUrl}
              controls
              autoPlay
              playsInline
              preload="metadata"
            />
          )}
        </div>
      )}

      {/* Audio player */}
      {mediaType === "audio" && (
        <div className="maudio">
          <span className="maudio-icon">🎵</span>
          <audio src={fileUrl} controls preload="metadata" style={{ flex: 1, minWidth: 0 }} />
        </div>
      )}

      {/* File name */}
      <p className="mfilename">
        {mediaType === "video" ? "🎬" : mediaType === "audio" ? "🎵" : "📄"}&nbsp;
        {filename}
      </p>

      {/* Action buttons */}
      <div className="mbtns">
        <button
          className="mbtn mbtn-primary"
          onClick={handleDownload}
          disabled={downloading}
        >
          {downloading ? "⏳ Saving…" : "⬇ Save to device"}
        </button>
        <button className="mbtn mbtn-ghost" onClick={handleCopy}>
          {copied ? "✓ Copied!" : "🔗 Copy link"}
        </button>
      </div>
    </div>
  );
}
