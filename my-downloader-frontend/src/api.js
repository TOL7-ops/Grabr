import axios from "axios";

// Safely extract API base — never undefined/null
export const API_BASE = (import.meta.env.VITE_API_URL || "").replace(/\/$/, "");

const client = axios.create({
  baseURL: API_BASE || window.location.origin,
  timeout: 15000,
  headers: { "Content-Type": "application/json" },
});

// Always return a safe string error message — never an object
function safeError(err) {
  if (!err) return "Unknown error";
  if (typeof err === "string") return err;
  // Axios error
  const msg = err?.response?.data?.error
    || err?.response?.data?.message
    || err?.message
    || "Request failed";
  return String(msg);
}

export async function submitDownload(url, format) {
  try {
    const { data } = await client.post("/api/download", { url, format });
    return { ok: true, jobId: data.jobId };
  } catch (err) {
    return { ok: false, error: safeError(err) };
  }
}

export async function pollJob(jobId) {
  try {
    const { data } = await client.get(`/api/download/${jobId}`);
    return {
      ok: true,
      state: String(data.state || "unknown"),
      progress: Number(data.progress || 0),
      result: data.result || null,
      error: data.error ? String(data.error) : null,
    };
  } catch (err) {
    return { ok: false, error: safeError(err) };
  }
}