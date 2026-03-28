import { useState, useEffect, useRef, useCallback, Component } from "react";
import { API_BASE, submitDownload, watchJob, safeStr as apiSafeStr } from "./api";
import './App.css';

// ── Platform config ────────────────────────────────────────────
const PLATFORMS = {
  youtube:   { name: "YouTube",   color: "#FF0000", bg: "rgba(255,0,0,0.08)",    domains: ["youtube.com","youtu.be"] },
  instagram: { name: "Instagram", color: "#E1306C", bg: "rgba(225,48,108,0.08)", domains: ["instagram.com"] },
  tiktok:    { name: "TikTok",    color: "#69C9D0", bg: "rgba(105,201,208,0.08)",domains: ["tiktok.com","vm.tiktok.com"] },
  twitter:   { name: "Twitter",   color: "#1DA1F2", bg: "rgba(29,161,242,0.08)", domains: ["twitter.com","x.com","t.co"] },
};

function detectPlatform(url) {
  try {
    const host = new URL(url.trim()).hostname.replace(/^www\./, "");
    for (const [key, p] of Object.entries(PLATFORMS)) {
      if (p.domains.some(d => host === d || host.endsWith("." + d))) return key;
    }
  } catch {}
  return null;
}
function isValidUrl(url) { return !!detectPlatform(url); }

function timeAgo(iso) {
  const s = Math.floor((Date.now() - new Date(iso)) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s/60)}m ago`;
  if (s < 86400) return `${Math.floor(s/3600)}h ago`;
  return `${Math.floor(s/86400)}d ago`;
}

// Ensure any value is rendered as a safe string
function safeStr(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  try { return JSON.stringify(v); } catch { return "Unknown error"; }
}

// ── Platform SVG logos ─────────────────────────────────────────
const PlatformLogo = ({ id, size = 28 }) => {
  const s = { width: size, height: size, borderRadius: 8, flexShrink: 0, display: "block" };
  if (id === "youtube")   return <svg viewBox="0 0 48 48" style={s}><rect width="48" height="48" rx="10" fill="#FF0000"/><path fill="#fff" d="M38.6 16.6a4 4 0 0 0-2.8-2.8C33.4 13 24 13 24 13s-9.4 0-11.8.8a4 4 0 0 0-2.8 2.8C8.6 19 8.6 24 8.6 24s0 5 .8 7.4a4 4 0 0 0 2.8 2.8C14.6 35 24 35 24 35s9.4 0 11.8-.8a4 4 0 0 0 2.8-2.8c.8-2.4.8-7.4.8-7.4s0-5-.8-7.4zm-17 12v-9l8 4.5-8 4.5z"/></svg>;
  if (id === "instagram") return <svg viewBox="0 0 48 48" style={s}><defs><radialGradient id="ig" cx="30%" cy="107%" r="130%"><stop offset="0%" stopColor="#fdf497"/><stop offset="5%" stopColor="#fdf497"/><stop offset="45%" stopColor="#fd5949"/><stop offset="60%" stopColor="#d6249f"/><stop offset="90%" stopColor="#285AEB"/></radialGradient></defs><rect width="48" height="48" rx="10" fill="url(#ig)"/><path fill="#fff" d="M24 14c-2.7 0-3.1 0-4.1.1-1.1 0-1.8.2-2.4.4a5 5 0 0 0-1.8 1.2 5 5 0 0 0-1.2 1.8c-.2.6-.4 1.3-.4 2.4C14 21 14 21.3 14 24s0 3.1.1 4.1c0 1.1.2 1.8.4 2.4a5 5 0 0 0 1.2 1.8 5 5 0 0 0 1.8 1.2c.6.2 1.3.4 2.4.4C21 34 21.3 34 24 34s3.1 0 4.1-.1c1.1 0 1.8-.2 2.4-.4a5 5 0 0 0 1.8-1.2 5 5 0 0 0 1.2-1.8c.2-.6.4-1.3.4-2.4C34 27 34 26.7 34 24s0-3.1-.1-4.1c0-1.1-.2-1.8-.4-2.4a5 5 0 0 0-1.2-1.8 5 5 0 0 0-1.8-1.2c-.6-.2-1.3-.4-2.4-.4C27 14 26.7 14 24 14zm0 1.8c2.7 0 3 0 4 .1 1 0 1.5.2 1.9.3.5.2.8.4 1.2.7.3.4.6.7.7 1.2.2.4.3.9.3 1.9.1 1 .1 1.3.1 4s0 3-.1 4c0 1-.1 1.5-.3 1.9a3.2 3.2 0 0 1-.7 1.2 3.2 3.2 0 0 1-1.2.7c-.4.2-.9.3-1.9.3-1 .1-1.3.1-4 .1s-3 0-4-.1c-1 0-1.5-.1-1.9-.3a3.2 3.2 0 0 1-1.2-.7 3.2 3.2 0 0 1-.7-1.2c-.2-.4-.3-.9-.3-1.9-.1-1-.1-1.3-.1-4s0-3 .1-4c0-1 .1-1.5.3-1.9.2-.5.4-.8.7-1.2.4-.3.7-.5 1.2-.7.4-.1.9-.3 1.9-.3 1-.1 1.3-.1 4-.1zm0 3a5.2 5.2 0 1 0 0 10.4A5.2 5.2 0 0 0 24 18.8zm0 8.6a3.4 3.4 0 1 1 0-6.8 3.4 3.4 0 0 1 0 6.8zm6.6-8.8a1.2 1.2 0 1 1-2.4 0 1.2 1.2 0 0 1 2.4 0z"/></svg>;
  if (id === "tiktok")    return <svg viewBox="0 0 48 48" style={s}><rect width="48" height="48" rx="10" fill="#010101"/><path fill="#fff" d="M34 19.4a9.4 9.4 0 0 1-5.5-1.8v8.3a7.5 7.5 0 1 1-7.5-7.5c.3 0 .5 0 .8 0v4.1c-.3 0-.5-.1-.8-.1a3.5 3.5 0 1 0 3.5 3.5V11h4a5.4 5.4 0 0 0 5.5 5.5v2.9z"/></svg>;
  if (id === "twitter")   return <svg viewBox="0 0 48 48" style={s}><rect width="48" height="48" rx="10" fill="#000"/><path fill="#fff" d="M26.4 22.3 34.5 13h-2L25.5 21 19.8 13H13l8.5 12.4L13 35h2l7.4-8.6 5.9 8.6H35L26.4 22.3zm-2.6 3-.9-1.2-6.9-9.9H19l5.6 8 .9 1.2 7.2 10.3h-2.9l-5.9-8.4z"/></svg>;
  return <div style={{ ...s, background: "#333" }} />;
};

// ── Icons ──────────────────────────────────────────────────────
const I = {
  Home: () => <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20"><path d="M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z"/></svg>,
  DL:   () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="20" height="20"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>,
  Cog:  () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="20" height="20"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>,
  Clip: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="16" height="16"><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><rect x="8" y="2" width="8" height="4" rx="1"/></svg>,
  Save: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" width="15" height="15"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>,
  Copy: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="15" height="15"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>,
  Tick: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" width="15" height="15"><polyline points="20 6 9 17 4 12"/></svg>,
  Del:  () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="15" height="15"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4h6v2"/></svg>,
  X:    () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="16" height="16"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>,
  Moon: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="18" height="18"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>,
  Sun:  () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="18" height="18"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/></svg>,
  Link: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="16" height="16"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>,
};

// ── Error Boundary ─────────────────────────────────────────────
class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }
  static getDerivedStateFromError(error) {
    return { error: error?.message || "Something went wrong" };
  }
  render() {
    if (this.state.error) {
      return (
        <div style={{ padding: "2rem", textAlign: "center", color: "#e5e7eb", background: "#0b0f19", minHeight: "100vh", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: "1rem" }}>
          <div style={{ fontSize: "2rem" }}>⚠</div>
          <p style={{ fontWeight: 700, fontSize: "1rem" }}>Something went wrong</p>
          <p style={{ fontSize: "0.8rem", color: "#6b7280", maxWidth: 300 }}>{safeStr(this.state.error)}</p>
          <button onClick={() => window.location.reload()} style={{ marginTop: "0.5rem", padding: "0.6rem 1.5rem", borderRadius: 8, background: "#6C63FF", color: "#fff", border: "none", cursor: "pointer", fontWeight: 600 }}>
            Reload
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

// ── useDownloadManager — SSE-based ────────────────────────────
function useDownloadManager() {
  const load = () => {
    try {
      const parsed = JSON.parse(localStorage.getItem("grabr_jobs") || "[]");
      return Array.isArray(parsed) ? parsed : [];
    } catch { return []; }
  };

  const [jobs, setJobs] = useState(load);
  const stoppers = useRef({}); // localId → stop() function from watchJob

  const save = useCallback((list) => {
    const safe = Array.isArray(list) ? list : [];
    setJobs(safe);
    try { localStorage.setItem("grabr_jobs", JSON.stringify(safe)); } catch {}
  }, []);

  const patch = useCallback((id, update) => {
    setJobs(prev => {
      const next = prev.map(j => j.id === id ? { ...j, ...update } : j);
      try { localStorage.setItem("grabr_jobs", JSON.stringify(next)); } catch {}
      return next;
    });
  }, []);

  const startWatch = useCallback((localId, apiId) => {
    if (stoppers.current[localId]) return; // already watching

    const stop = watchJob(apiId, {
      onProgress: (percent, speed, eta, size) => {
        patch(localId, {
          state:    "active",
          progress: Math.min(Math.floor(percent), 100),
          speed:    safeStr(speed),
          eta:      safeStr(eta),
          size:     safeStr(size),
        });
      },
      onStatus: (status) => {
        if (status === "starting" || status === "queued") {
          patch(localId, { state: "queued", progress: 0 });
        } else if (status === "processing") {
          patch(localId, { state: "active", progress: 99 });
        }
      },
      onComplete: (filename, fileUrl) => {
        delete stoppers.current[localId];
        patch(localId, {
          state:       "completed",
          progress:    100,
          completedAt: new Date().toISOString(),
          result:      { filename: safeStr(filename), downloadUrl: safeStr(fileUrl) },
        });
      },
      onError: (message) => {
        delete stoppers.current[localId];
        patch(localId, { state: "failed", error: safeStr(message) });
      },
    });

    stoppers.current[localId] = stop;
  }, [patch]);

  const addJob = useCallback(async (url, format) => {
    const id = `job_${Date.now()}`;
    const platform = detectPlatform(url) || "youtube";
    const job = {
      id, url, format, platform,
      state: "submitting", progress: 0,
      createdAt: new Date().toISOString(),
      result: null, error: null, apiJobId: null,
      speed: "", eta: "", size: "",
    };
    setJobs(prev => {
      const n = [job, ...prev];
      try { localStorage.setItem("grabr_jobs", JSON.stringify(n)); } catch {}
      return n;
    });

    const res = await submitDownload(url, format);
    if (!res.ok) {
      patch(id, { state: "failed", error: safeStr(res.error) });
      return;
    }
    patch(id, { state: "queued", apiJobId: safeStr(res.jobId) });
    startWatch(id, res.jobId);
  }, [patch, startWatch]);

  const removeJob = useCallback((id) => {
    if (stoppers.current[id]) { stoppers.current[id](); delete stoppers.current[id]; }
    setJobs(prev => {
      const n = prev.filter(j => j.id !== id);
      try { localStorage.setItem("grabr_jobs", JSON.stringify(n)); } catch {}
      return n;
    });
  }, []);

  const clearAll = useCallback(() => {
    Object.values(stoppers.current).forEach(s => { try { s(); } catch {} });
    stoppers.current = {};
    save([]);
  }, [save]);

  // Resume watching in-progress jobs on mount
  useEffect(() => {
    jobs.forEach(j => {
      if (["queued", "active", "submitting"].includes(j.state) && j.apiJobId) {
        startWatch(j.id, j.apiJobId);
      }
    });
    return () => Object.values(stoppers.current).forEach(s => { try { s(); } catch {} });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { jobs, addJob, removeJob, clearAll };
}

function useSettings() {
  const def = { dark: true, defaultFormat: "mp4", autoPaste: true };
  const [s, set] = useState(() => {
    try { return { ...def, ...JSON.parse(localStorage.getItem("grabr_settings") || "{}") }; }
    catch { return def; }
  });
  const update = p => {
    set(prev => {
      const n = { ...prev, ...p };
      try { localStorage.setItem("grabr_settings", JSON.stringify(n)); } catch {}
      return n;
    });
  };
  return [s, update];
}

function Toggle({ on, onChange }) {
  return (
    <button onClick={() => onChange(!on)} className={`tog ${on ? "tog-on" : ""}`} aria-checked={on}>
      <span className="tog-knob" />
    </button>
  );
}

// ═══════════════════════════════════════════
// HOME
// ═══════════════════════════════════════════
function HomePage({ settings, onStart }) {
  const [url, setUrl]       = useState("");
  const [format, setFormat] = useState(settings.defaultFormat || "mp4");
  const [platform, setPl]   = useState(null);
  const [valid, setValid]   = useState(false);
  const [busy, setBusy]     = useState(false);
  const [done, setDone]     = useState(false);
  const [clip, setClip]     = useState("");

  useEffect(() => { setFormat(settings.defaultFormat || "mp4"); }, [settings.defaultFormat]);
  useEffect(() => {
    const v = isValidUrl(url.trim());
    setValid(v);
    setPl(v ? detectPlatform(url.trim()) : null);
  }, [url]);

  const tryClip = async () => {
    if (!settings.autoPaste || url) return;
    try {
      const t = await navigator.clipboard.readText();
      if (t && isValidUrl(t)) setClip(t);
    } catch {}
  };

  const submit = async () => {
    if (!valid || busy) return;
    setBusy(true);
    await onStart(url.trim(), format);
    setBusy(false);
    setDone(true);
    setTimeout(() => { setDone(false); setUrl(""); }, 2200);
  };

  const FORMATS = ["mp4", "mp3", "720p", "1080p", "m4a"];
  const SUPPORTED = [
    { id: "youtube",   label: "YouTube" },
    { id: "instagram", label: "Instagram" },
    { id: "tiktok",    label: "TikTok" },
    { id: "twitter",   label: "Twitter / X" },
  ];

  return (
    <div className="pg">
      <div className="hero-banner">
        <div className="hero-badge">Social Media Video Downloader</div>
        <p className="hero-sub">Download from YouTube, Instagram, TikTok &amp; more</p>
      </div>

      <div className="card">
        <div className={`ufield ${valid ? "ufield-ok" : ""} ${url && !valid ? "ufield-bad" : ""}`}>
          <I.Link />
          <input
            className="uinput"
            type="url"
            placeholder="Your link here..."
            value={url}
            onChange={e => { setUrl(e.target.value); setClip(""); }}
            onFocus={tryClip}
            disabled={busy}
            spellCheck={false}
            autoComplete="off"
          />
          {url
            ? <button className="uaction" onClick={() => setUrl("")}><I.X /></button>
            : <button className="uaction" onClick={async () => { try { const t = await navigator.clipboard.readText(); if (t) setUrl(t); } catch {} }}><I.Clip /></button>
          }
        </div>

        {clip && !url && (
          <button className="clip-hint" onClick={() => { setUrl(clip); setClip(""); }}>
            <I.Clip />
            <span>Paste:</span>
            <span className="clip-preview">{clip.slice(0, 40)}…</span>
          </button>
        )}

        {platform && (
          <div className="pl-badge" style={{ background: PLATFORMS[platform]?.bg, borderColor: (PLATFORMS[platform]?.color || "#666") + "55" }}>
            <PlatformLogo id={platform} size={18} />
            <span style={{ color: PLATFORMS[platform]?.color, fontWeight: 600 }}>{PLATFORMS[platform]?.name} detected ✓</span>
          </div>
        )}

        {url && !valid && <p className="url-err">⚠ Unsupported — try YouTube, Instagram, TikTok or Twitter</p>}

        <div className="fmt-row">
          {FORMATS.map(f => (
            <button key={f} className={`fchip ${format === f ? "fchip-on" : ""}`} onClick={() => setFormat(f)} disabled={busy}>
              {f.toUpperCase()}
            </button>
          ))}
        </div>

        <div className="btn-row">
          <button className="paste-btn" onClick={async () => { try { const t = await navigator.clipboard.readText(); if (t) setUrl(t); } catch {} }} disabled={busy}>
            <I.Clip /> Paste
          </button>
          <button
            className={`dl-btn ${valid && !busy && !done ? "dl-ready" : ""} ${done ? "dl-done" : ""}`}
            onClick={submit}
            disabled={!valid || busy}
          >
            {done    ? <><I.Tick /><span>Added!</span></>
             : busy  ? <><span className="spin" /><span>Starting…</span></>
             :         <><I.Save /><span>Download</span></>}
          </button>
        </div>
      </div>

      <div className="sup-section">
        <p className="sup-label">Supported Socials</p>
        <div className="sup-grid">
          {SUPPORTED.map(p => (
            <div key={p.id} className="sup-card">
              <PlatformLogo id={p.id} size={38} />
              <span className="sup-name">{p.label}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════
// DOWNLOADS
// ═══════════════════════════════════════════
function DownloadsPage({ jobs, onRemove, onClear }) {
  const [copied, setCopied] = useState(null);

  const doCopy = async (job) => {
    try {
      const filename = job.result?.filename || "";
      const url = `${API_BASE}/files/${encodeURIComponent(filename)}`;
      await navigator.clipboard.writeText(url);
      setCopied(job.id);
      setTimeout(() => setCopied(null), 2000);
    } catch {}
  };

  if (!jobs.length) return (
    <div className="pg center-pg">
      <div className="empty">
        <div className="empty-ico"><I.DL /></div>
        <p className="empty-t">No downloads yet</p>
        <p className="empty-s">Paste a link on the Home tab</p>
      </div>
    </div>
  );

  return (
    <div className="pg">
      <div className="pghdr">
        <h2 className="pgtitle">Downloads</h2>
        <button className="clr-btn" onClick={onClear}>Clear all</button>
      </div>
      <div className="jlist">
        {jobs.map(job => {
          const inProg = ["submitting", "queued", "active"].includes(job.state);
          const filename = safeStr(job.result?.filename || "");
          const jobError = safeStr(job.error || "");
          const jobUrl   = safeStr(job.url || "");
          const jobFmt   = safeStr(job.format || "").toUpperCase();

          return (
            <div key={job.id} className={`jcard jcard-${job.state}`}>
              <div className="jtop">
                <PlatformLogo id={job.platform} size={34} />
                <div className="jmeta">
                  <span className="jurl">{jobUrl.slice(0, 44)}{jobUrl.length > 44 ? "…" : ""}</span>
                  <div className="jtags">
                    <span className="jtag">{jobFmt}</span>
                    <span className="jtime">{timeAgo(job.createdAt)}</span>
                  </div>
                </div>
                <button className="jdel" onClick={() => onRemove(job.id)}><I.Del /></button>
              </div>

              {inProg && (
                <div className="jprog">
                  <div className="jtrack">
                    <div className="jfill" style={{ width: `${Math.max(job.progress || 0, job.state === "submitting" ? 3 : 6)}%` }} />
                  </div>
                  <div className="jstrow">
                    <span className={`spill spill-${job.state}`}>
                      {job.state === "submitting" && "🔄 Connecting"}
                      {job.state === "queued"     && "⏳ Queued"}
                      {job.state === "active"     && (job.progress >= 99 ? "⚙️ Processing" : "⚡ Downloading")}
                    </span>
                    <span className="jpct">{job.progress || 0}%</span>
                  </div>
                  {job.state === "active" && (job.speed || job.eta) && (
                    <div className="jspeed">
                      {job.speed && <span>🚀 {job.speed}</span>}
                      {job.eta   && <span>⏱ ETA {job.eta}</span>}
                      {job.size  && <span>📦 {job.size}</span>}
                    </div>
                  )}
                </div>
              )}

              {job.state === "completed" && job.result && (
                <div className="jresult">
                  <span className="jfname">✅ {filename}</span>
                  <div className="jrbtns">
                    <a
                      href={`${API_BASE}/files/${encodeURIComponent(filename)}`}
                      download={filename}
                      className="rb rb-green"
                    >
                      <I.Save /> Save
                    </a>
                    <button className="rb rb-ghost" onClick={() => doCopy(job)}>
                      {copied === job.id ? <><I.Tick /> Copied!</> : <><I.Copy /> Link</>}
                    </button>
                  </div>
                </div>
              )}

              {job.state === "failed" && (
                <div className="jerr">❌ {jobError || "Download failed"}</div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════
// SETTINGS
// ═══════════════════════════════════════════
function SettingsPage({ settings, onUpdate }) {
  return (
    <div className="pg">
      <div className="pghdr"><h2 className="pgtitle">Settings</h2></div>
      <div className="slist">

        <div className="sgroup">
          <p className="sglabel">Appearance</p>
          <div className="srow">
            <div className="sinfo">
              {settings.dark ? <I.Moon /> : <I.Sun />}
              <div><p className="sname">Dark Mode</p><p className="sdesc">Easy on the eyes at night</p></div>
            </div>
            <Toggle on={settings.dark} onChange={v => onUpdate({ dark: v })} />
          </div>
        </div>

        <div className="sgroup">
          <p className="sglabel">Downloads</p>
          <div className="srow">
            <div className="sinfo">
              <I.Clip />
              <div><p className="sname">Auto-paste from clipboard</p><p className="sdesc">Auto-fill URL when you tap the input</p></div>
            </div>
            <Toggle on={settings.autoPaste} onChange={v => onUpdate({ autoPaste: v })} />
          </div>
          <div className="srow srow-col">
            <div className="sinfo">
              <I.Save />
              <div><p className="sname">Default Format</p><p className="sdesc">Pre-selected when you open the app</p></div>
            </div>
            <div className="fmt-row" style={{ marginTop: "0.5rem" }}>
              {["mp4", "mp3", "720p", "1080p", "m4a"].map(f => (
                <button key={f} className={`fchip ${settings.defaultFormat === f ? "fchip-on" : ""}`} onClick={() => onUpdate({ defaultFormat: f })}>
                  {f.toUpperCase()}
                </button>
              ))}
            </div>
          </div>
        </div>

        <div className="sgroup">
          <p className="sglabel">Backend</p>
          <div className="srow srow-col">
            <div className="sinfo">
              <I.Link />
              <div><p className="sname">API URL</p><p className="sdesc">Your downloader backend address</p></div>
            </div>
            <input className="api-inp" type="text" value={API_BASE || "http://localhost:3000"} readOnly />
          </div>
        </div>

        <div className="sgroup">
          <p className="sglabel">Supported Platforms</p>
          <div className="plat-list">
            {Object.entries(PLATFORMS).map(([id, p]) => (
              <div key={id} className="plat-row">
                <PlatformLogo id={id} size={28} />
                <span className="plat-name">{safeStr(p.name)}</span>
                <span className="plat-check">✓</span>
              </div>
            ))}
          </div>
        </div>

        <div className="sgroup">
          <p className="sglabel">About</p>
          <div className="about-card">
            <div className="about-ico">⬇</div>
            <div>
              <p className="about-name">grabr</p>
              <p className="about-ver">v1.0.0 — YouTube · Instagram · TikTok · Twitter</p>
            </div>
          </div>
        </div>

      </div>
    </div>
  );
}

// ═══════════════════════════════════════════
// SHELL
// ═══════════════════════════════════════════
function Shell() {
  const [tab, setTab]             = useState("home");
  const [settings, updSettings]   = useSettings();
  const { jobs, addJob, removeJob, clearAll } = useDownloadManager();

  const activeCount = jobs.filter(j => ["submitting", "queued", "active"].includes(j.state)).length;

  useEffect(() => {
    document.documentElement.className = settings.dark ? "dark" : "light";
  }, [settings.dark]);

  const handleStart = async (url, fmt) => {
    await addJob(url, fmt);
    setTab("downloads");
  };

  const TABS = [
    { id: "home",      label: "Home",      Icon: I.Home },
    { id: "downloads", label: "Downloads", Icon: I.DL   },
    { id: "settings",  label: "Settings",  Icon: I.Cog  },
  ];

  return (
    <div className="shell">
      <div className="content">
        {tab === "home"      && <HomePage      settings={settings} onStart={handleStart} />}
        {tab === "downloads" && <DownloadsPage jobs={jobs} onRemove={removeJob} onClear={clearAll} />}
        {tab === "settings"  && <SettingsPage  settings={settings} onUpdate={updSettings} />}
      </div>
      <nav className="bnav">
        {TABS.map(({ id, label, Icon }) => (
          <button key={id} className={`nbtn ${tab === id ? "nbtn-on" : ""}`} onClick={() => setTab(id)}>
            <span className="nbtn-ico">
              <Icon />
              {id === "downloads" && activeCount > 0 && (
                <span className="nbadge">{activeCount}</span>
              )}
            </span>
            <span className="nbtn-lbl">{label}</span>
          </button>
        ))}
      </nav>
    </div>
  );
}

export default function App() {
  return (
    <ErrorBoundary>
      <Shell />
    </ErrorBoundary>
  );
}