export const API_BASE = (
  import.meta.env.VITE_API_URL ||
  "https://grabr-production-fa32.up.railway.app"
).replace(/\/$/, "");

export function safeStr(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  try { return JSON.stringify(v); } catch { return "Unknown error"; }
}

export async function submitDownload(url, format) {
  try {
    const res = await fetch(`${API_BASE}/api/download`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, format }),
    });
    const data = await res.json();
    if (!res.ok) return { ok: false, error: safeStr(data?.error || "Request failed") };
    return { ok: true, jobId: String(data.jobId) };
  } catch (err) {
    return { ok: false, error: safeStr(err?.message || "Network error") };
  }
}

/**
 * downloadFile — works on BOTH desktop and mobile
 * Backend sends Content-Disposition: attachment which forces download.
 * For mobile we fetch as blob and trigger via anchor to ensure it saves
 * to device instead of opening in browser.
 */
export async function downloadFile(fileUrl, filename) {
  try {
    const response = await fetch(fileUrl);
    if (!response.ok) throw new Error("File not found");
    const blob = await response.blob();
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement("a");
    a.href     = url;
    a.download = filename || "download";
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    // Clean up
    setTimeout(() => { URL.revokeObjectURL(url); document.body.removeChild(a); }, 5000);
    return { ok: true };
  } catch (err) {
    // Fallback: open in new tab (browser will trigger download via Content-Disposition)
    window.open(fileUrl, "_blank");
    return { ok: true };
  }
}

/**
 * watchJob — SSE primary, polling fallback
 * onProgress(percent, speed, eta, size)
 * onStatus(status)
 * onComplete(filename, fileUrl, mediaType)
 * onError(message)
 */
export function watchJob(jobId, { onProgress, onStatus, onComplete, onError }) {
  let closed = false, es = null, pollTimer = null, retries = 0;
  const MAX_RETRIES = 3;

  function stop() {
    closed = true;
    if (es)        { try { es.close(); } catch {} es = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function handle(data) {
    if (closed) return;
    const status = safeStr(data.status);
    onStatus && onStatus(status);
    switch (status) {
      case "starting":
        onProgress && onProgress(0, "", "", ""); break;
      case "downloading":
        onProgress && onProgress(Number(data.percent)||0, safeStr(data.speed), safeStr(data.eta), safeStr(data.size)); break;
      case "processing":
        onProgress && onProgress(99, "", "", ""); break;
      case "completed":
        onProgress && onProgress(100, "", "", "");
        onComplete && onComplete(safeStr(data.filename), safeStr(data.fileUrl), safeStr(data.mediaType || "file"));
        stop(); break;
      case "error":
        onError && onError(safeStr(data.message || "Download failed"));
        stop(); break;
    }
  }

  function startPolling() {
    if (closed || pollTimer) return;
    let count = 0;
    pollTimer = setInterval(async () => {
      if (closed) return;
      count++;
      try {
        const res  = await fetch(`${API_BASE}/api/download/${jobId}`);
        const data = await res.json();
        onProgress && onProgress(Number(data.progress)||0, "", "", "");
        onStatus   && onStatus(safeStr(data.state));
        if (data.state === "completed" && data.result) {
          onProgress && onProgress(100, "", "", "");
          onComplete && onComplete(safeStr(data.result.filename), safeStr(data.result.downloadUrl), safeStr(data.result.mediaType||"file"));
          stop();
        } else if (data.state === "failed") {
          onError && onError(safeStr(data.error || "Download failed"));
          stop();
        }
      } catch { if (count > 72) { onError && onError("Connection lost"); stop(); } }
    }, 2500);
  }

  function openSSE() {
    if (closed) return;
    try {
      es = new EventSource(`${API_BASE}/api/download/stream/${jobId}`);
      es.onmessage = e => { retries = 0; try { handle(JSON.parse(e.data)); } catch {} };
      es.onerror = () => {
        if (closed) return;
        if (++retries >= MAX_RETRIES) { try { es.close(); } catch {} es = null; startPolling(); }
      };
    } catch { startPolling(); }
  }

  openSSE();
  return stop;
}
