import { useState } from "react";
import { API_BASE, safeStr, downloadFile } from "./api";

export default function MediaPreview({ job }) {
  const [playing,  setPlaying]  = useState(false);
  const [saving,   setSaving]   = useState(false);
  const [copied,   setCopied]   = useState(false);
  const [shareErr, setShareErr] = useState("");

  if (!job || job.state !== "completed" || !job.result) return null;

  const filename  = safeStr(job.result.filename);
  const mediaType = safeStr(job.result.mediaType || "file");

  // Fix localhost URLs that leak from misconfigured env
  let rawUrl = safeStr(job.result.downloadUrl || "");
  if (!rawUrl || rawUrl.includes("localhost") || rawUrl.includes("127.0.0.1")) {
    rawUrl = `${API_BASE}/files/${encodeURIComponent(filename)}`;
  }
  const fileUrl = rawUrl;

  const isVideo = mediaType === "video";
  const isAudio = mediaType === "audio";

  // ── Save to device ─────────────────────────────────────────────
  // On iOS: triggers "Save to Photos" when MIME is video/mp4
  // On Android: saves to Downloads/Gallery
  // Desktop: direct download
  const handleSave = async () => {
    setSaving(true);
    setShareErr("");

    // Try Web Share API first (iOS 15+ / Android Chrome)
    // This gives "Save to Photos" option on iOS
    if (navigator.canShare) {
      try {
        const response = await fetch(fileUrl);
        const blob     = await response.blob();
        const file     = new File([blob], filename, { type: blob.type });
        if (navigator.canShare({ files: [file] })) {
          await navigator.share({ files: [file], title: filename });
          setSaving(false);
          return;
        }
      } catch (e) {
        // Share cancelled or not supported — fall through to blob download
      }
    }

    // Blob download fallback — works on all platforms
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
      {isVideo && (
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
      {isAudio && (
        <div className="maudio">
          <span className="maudio-icon">🎵</span>
          <audio src={fileUrl} controls preload="metadata" style={{ flex: 1, minWidth: 0 }} />
        </div>
      )}

      <p className="mfilename">
        {isVideo ? "🎬" : isAudio ? "🎵" : "📄"}&nbsp;{filename}
      </p>

      {shareErr && <p className="mshare-err">{shareErr}</p>}

      <div className="mbtns">
        <button className="mbtn mbtn-primary" onClick={handleSave} disabled={saving}>
          {saving ? "⏳ Saving…" : isVideo ? "⬇ Save to Photos" : "⬇ Save file"}
        </button>
        <button className="mbtn mbtn-ghost" onClick={handleCopy}>
          {copied ? "✓ Copied!" : "🔗 Link"}
        </button>
      </div>

      {/* iOS hint */}
      {isVideo && (
        <p className="mhint">
          iOS: tap "Save to Photos" when prompted · Android: check Gallery/Downloads
        </p>
      )}
    </div>
  );
}
