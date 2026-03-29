import { useState } from "react";
import { API_BASE, safeStr, downloadFile } from "./api";

export default function MediaPreview({ job }) {
  const [playing,  setPlaying]  = useState(false);
  const [saving,   setSaving]   = useState(false);
  const [copied,   setCopied]   = useState(false);

  if (!job || job.state !== "completed" || !job.result) return null;

  const filename  = safeStr(job.result.filename);
  const mediaType = safeStr(job.result.mediaType || "file");

  // Fix localhost URLs
  let rawUrl = safeStr(job.result.downloadUrl || "");
  if (!rawUrl || rawUrl.includes("localhost") || rawUrl.includes("127.0.0.1")) {
    rawUrl = `${API_BASE}/files/${encodeURIComponent(filename)}`;
  }
  const fileUrl = rawUrl;

  const handleSave = async () => {
    setSaving(true);
    await downloadFile(fileUrl, filename);
    setSaving(false);
  };

  const handleCopy = async () => {
    try { await navigator.clipboard.writeText(fileUrl); } catch {}
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="mpreview">

      {/* Video player */}
      {mediaType === "video" && (
        <div className="mplayer">
          {!playing ? (
            <button className="mplay-btn" onClick={() => setPlaying(true)} aria-label="Preview video">
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

      {/* Filename */}
      <p className="mfilename">
        {mediaType === "video" ? "🎬" : mediaType === "audio" ? "🎵" : "📄"}&nbsp;{filename}
      </p>

      {/* Buttons */}
      <div className="mbtns">
        <button className="mbtn mbtn-primary" onClick={handleSave} disabled={saving}>
          {saving ? "⏳ Saving…" : "⬇ Save to device"}
        </button>
        <button className="mbtn mbtn-ghost" onClick={handleCopy}>
          {copied ? "✓ Copied!" : "🔗 Copy link"}
        </button>
      </div>
    </div>
  );
}
