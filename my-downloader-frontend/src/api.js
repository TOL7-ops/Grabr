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
    return { ok: false, error: safeStr(err?.message || "Network error — check your connection") };
  }
}

export function watchJob(jobId, { onProgress, onStatus, onComplete, onError }) {
  let closed = false;
  let es = null;
  let pollTimer = null;
  let retries = 0;
  const MAX_RETRIES = 3;

  function stop() {
    closed = true;
    if (es)        { try { es.close(); }          catch {} es = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function handleEvent(data) {
    if (closed) return;
    onStatus && onStatus(safeStr(data.status));
    switch (data.status) {
      case "starting":     onProgress && onProgress(0, "", "", ""); break;
      case "downloading":
        onProgress && onProgress(Number(data.percent)||0, safeStr(data.speed), safeStr(data.eta), safeStr(data.size));
        break;
      case "processing":   onProgress && onProgress(99, "", "", ""); break;
      case "completed":
        onProgress && onProgress(100, "", "", "");
        onComplete && onComplete(safeStr(data.filename), safeStr(data.fileUrl));
        stop(); break;
      case "error":
        onError && onError(safeStr(data.message));
        stop(); break;
    }
  }

  function startPolling() {
    if (closed || pollTimer) return;
    let count = 0;
    pollTimer = setInterval(async () => {
      if (closed) { clearInterval(pollTimer); return; }
      count++;
      try {
        const res  = await fetch(`${API_BASE}/api/download/${jobId}`);
        const data = await res.json();
        const pct  = Number(data.progress) || 0;
        onProgress && onProgress(pct, "", "", "");
        onStatus   && onStatus(safeStr(data.state));
        if (data.state === "completed" && data.result) {
          onProgress && onProgress(100, "", "", "");
          onComplete && onComplete(safeStr(data.result.filename), safeStr(data.result.downloadUrl));
          stop();
        } else if (data.state === "failed") {
          onError && onError(safeStr(data.error || "Download failed"));
          stop();
        }
      } catch {
        if (count > 72) { onError && onError("Connection lost after 3 minutes"); stop(); }
      }
    }, 2500);
  }

  function openSSE() {
    if (closed) return;
    try {
      es = new EventSource(`${API_BASE}/api/download/stream/${jobId}`);
      es.onmessage = (e) => {
        retries = 0;
        try { handleEvent(JSON.parse(e.data)); } catch {}
      };
      es.onerror = () => {
        if (closed) return;
        retries++;
        if (retries >= MAX_RETRIES) {
          if (es) { try { es.close(); } catch {} es = null; }
          startPolling();
        }
      };
    } catch { startPolling(); }
  }

  openSSE();
  return stop;
}
