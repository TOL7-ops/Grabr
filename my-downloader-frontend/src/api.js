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

/**
 * downloadFile — works on desktop AND mobile
 *
 * Strategy:
 * 1. Fetch file as blob (works cross-origin, respects Content-Disposition)
 * 2. Create object URL → click hidden anchor
 * 3. Fallback: window.open (browser handles download via Content-Disposition)
 *
 * On iOS Safari: step 1+2 triggers "Save to Files"
 * On Android Chrome: step 1+2 saves to Downloads
 * On Desktop: step 1+2 downloads immediately
 */
export async function downloadFile(fileUrl, filename) {
  // Ensure we use the correct backend URL (not localhost)
  let url = fileUrl;
  if (!url || url.includes("localhost") || url.includes("127.0.0.1")) {
    // Reconstruct using API_BASE
    const name = filename || url.split("/").pop();
    url = `${API_BASE}/files/${encodeURIComponent(name)}`;
  }

  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const blob    = await response.blob();
    const objUrl  = URL.createObjectURL(blob);
    const a       = document.createElement("a");
    a.href        = objUrl;
    a.download    = filename || "download";
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(objUrl); document.body.removeChild(a); }, 10000);
    return { ok: true };
  } catch (err) {
    // Fallback: open in new tab — Content-Disposition will trigger download
    window.open(url, "_blank");
    return { ok: true };
  }
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
 * watchJob — SSE primary, polling fallback
 * Fixes localhost URL in fileUrl before passing to onComplete
 */
export function watchJob(jobId, { onProgress, onStatus, onComplete, onError }) {
  let closed = false, es = null, pollTimer = null, retries = 0;
  const MAX_RETRIES = 3;

  function stop() {
    closed = true;
    if (es)        { try { es.close(); } catch {} es = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  // Fix localhost URLs that leak from misconfigured Railway env
  function fixUrl(rawUrl, filename) {
    if (!rawUrl) return rawUrl;
    if (rawUrl.includes("localhost") || rawUrl.includes("127.0.0.1")) {
      return `${API_BASE}/files/${encodeURIComponent(filename || rawUrl.split("/").pop())}`;
    }
    return rawUrl;
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
      case "completed": {
        const filename = safeStr(data.filename);
        const fileUrl  = fixUrl(safeStr(data.fileUrl), filename);
        onProgress && onProgress(100, "", "", "");
        onComplete && onComplete(filename, fileUrl, safeStr(data.mediaType || "file"));
        stop(); break;
      }
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
          const filename = safeStr(data.result.filename);
          const fileUrl  = fixUrl(safeStr(data.result.downloadUrl), filename);
          onProgress && onProgress(100, "", "", "");
          onComplete && onComplete(filename, fileUrl, safeStr(data.result.mediaType||"file"));
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
