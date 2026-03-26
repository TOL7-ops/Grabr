import { useState, useEffect, useRef, useCallback } from "react";
import axios from "axios";
import './App.css';

// ── API ────────────────────────────────────────────────────────
const API_BASE = import.meta.env.VITE_API_URL || "";
const POLL_MS  = 2500;

// ── Platform config ────────────────────────────────────────────
const PLATFORMS = {
  youtube:   { name: "YouTube",   color: "#FF0000", bg: "rgba(255,0,0,0.08)",      domains: ["youtube.com","youtu.be"] },
  instagram: { name: "Instagram", color: "#E1306C", bg: "rgba(225,48,108,0.08)",   domains: ["instagram.com"] },
  tiktok:    { name: "TikTok",   color: "#69C9D0", bg: "rgba(105,201,208,0.08)",   domains: ["tiktok.com","vm.tiktok.com"] },
  twitter:   { name: "Twitter",  color: "#1DA1F2", bg: "rgba(29,161,242,0.08)",    domains: ["twitter.com","x.com","t.co"] },
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

// ── Platform SVG logos ─────────────────────────────────────────
const PlatformLogo = ({ id, size = 28 }) => {
  const s = { width: size, height: size, borderRadius: 8, flexShrink: 0, display:"block" };
  if (id === "youtube")   return <svg viewBox="0 0 48 48" style={s}><rect width="48" height="48" rx="10" fill="#FF0000"/><path fill="#fff" d="M38.6 16.6a4 4 0 0 0-2.8-2.8C33.4 13 24 13 24 13s-9.4 0-11.8.8a4 4 0 0 0-2.8 2.8C8.6 19 8.6 24 8.6 24s0 5 .8 7.4a4 4 0 0 0 2.8 2.8C14.6 35 24 35 24 35s9.4 0 11.8-.8a4 4 0 0 0 2.8-2.8c.8-2.4.8-7.4.8-7.4s0-5-.8-7.4zm-17 12v-9l8 4.5-8 4.5z"/></svg>;
  if (id === "instagram") return <svg viewBox="0 0 48 48" style={s}><defs><radialGradient id="ig" cx="30%" cy="107%" r="130%"><stop offset="0%" stopColor="#fdf497"/><stop offset="5%" stopColor="#fdf497"/><stop offset="45%" stopColor="#fd5949"/><stop offset="60%" stopColor="#d6249f"/><stop offset="90%" stopColor="#285AEB"/></radialGradient></defs><rect width="48" height="48" rx="10" fill="url(#ig)"/><path fill="#fff" d="M24 14c-2.7 0-3.1 0-4.1.1-1.1 0-1.8.2-2.4.4a5 5 0 0 0-1.8 1.2 5 5 0 0 0-1.2 1.8c-.2.6-.4 1.3-.4 2.4C14 21 14 21.3 14 24s0 3.1.1 4.1c0 1.1.2 1.8.4 2.4a5 5 0 0 0 1.2 1.8 5 5 0 0 0 1.8 1.2c.6.2 1.3.4 2.4.4C21 34 21.3 34 24 34s3.1 0 4.1-.1c1.1 0 1.8-.2 2.4-.4a5 5 0 0 0 1.8-1.2 5 5 0 0 0 1.2-1.8c.2-.6.4-1.3.4-2.4C34 27 34 26.7 34 24s0-3.1-.1-4.1c0-1.1-.2-1.8-.4-2.4a5 5 0 0 0-1.2-1.8 5 5 0 0 0-1.8-1.2c-.6-.2-1.3-.4-2.4-.4C27 14 26.7 14 24 14zm0 1.8c2.7 0 3 0 4 .1 1 0 1.5.2 1.9.3.5.2.8.4 1.2.7.3.4.6.7.7 1.2.2.4.3.9.3 1.9.1 1 .1 1.3.1 4s0 3-.1 4c0 1-.1 1.5-.3 1.9a3.2 3.2 0 0 1-.7 1.2 3.2 3.2 0 0 1-1.2.7c-.4.2-.9.3-1.9.3-1 .1-1.3.1-4 .1s-3 0-4-.1c-1 0-1.5-.1-1.9-.3a3.2 3.2 0 0 1-1.2-.7 3.2 3.2 0 0 1-.7-1.2c-.2-.4-.3-.9-.3-1.9-.1-1-.1-1.3-.1-4s0-3 .1-4c0-1 .1-1.5.3-1.9.2-.5.4-.8.7-1.2.4-.3.7-.5 1.2-.7.4-.1.9-.3 1.9-.3 1-.1 1.3-.1 4-.1zm0 3a5.2 5.2 0 1 0 0 10.4A5.2 5.2 0 0 0 24 18.8zm0 8.6a3.4 3.4 0 1 1 0-6.8 3.4 3.4 0 0 1 0 6.8zm6.6-8.8a1.2 1.2 0 1 1-2.4 0 1.2 1.2 0 0 1 2.4 0z"/></svg>;
  if (id === "tiktok")   return <svg viewBox="0 0 48 48" style={s}><rect width="48" height="48" rx="10" fill="#010101"/><path fill="#fff" d="M34 19.4a9.4 9.4 0 0 1-5.5-1.8v8.3a7.5 7.5 0 1 1-7.5-7.5c.3 0 .5 0 .8 0v4.1c-.3 0-.5-.1-.8-.1a3.5 3.5 0 1 0 3.5 3.5V11h4a5.4 5.4 0 0 0 5.5 5.5v2.9z"/></svg>;
  if (id === "twitter")  return <svg viewBox="0 0 48 48" style={s}><rect width="48" height="48" rx="10" fill="#000"/><path fill="#fff" d="M26.4 22.3 34.5 13h-2L25.5 21 19.8 13H13l8.5 12.4L13 35h2l7.4-8.6 5.9 8.6H35L26.4 22.3zm-2.6 3-.9-1.2-6.9-9.9H19l5.6 8 .9 1.2 7.2 10.3h-2.9l-5.9-8.4z"/></svg>;
  return <div style={{...s, background:"#333"}} />;
};

// ── Tiny icons ─────────────────────────────────────────────────
const I = {
  Home:()=><svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20"><path d="M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z"/></svg>,
  DL:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="20" height="20"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>,
  Cog:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="20" height="20"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>,
  Clip:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="16" height="16"><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><rect x="8" y="2" width="8" height="4" rx="1"/></svg>,
  Save:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" width="15" height="15"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>,
  Copy:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="15" height="15"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>,
  Tick:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" width="15" height="15"><polyline points="20 6 9 17 4 12"/></svg>,
  Del:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="15" height="15"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4h6v2"/></svg>,
  X:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="16" height="16"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>,
  Moon:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="18" height="18"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>,
  Sun:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="18" height="18"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/></svg>,
  Link:()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="16" height="16"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>,
};

// ── useDownloadManager ─────────────────────────────────────────
function useDownloadManager() {
  const load = () => { try { return JSON.parse(localStorage.getItem("grabr_jobs")||"[]"); } catch { return []; } };
  const [jobs, setJobs] = useState(load);
  const timers = useRef({});

  const save = useCallback((list) => {
    setJobs(list);
    localStorage.setItem("grabr_jobs", JSON.stringify(list));
  }, []);

  const patch = useCallback((id, update) => {
    setJobs(prev => {
      const next = prev.map(j => j.id === id ? { ...j, ...update } : j);
      localStorage.setItem("grabr_jobs", JSON.stringify(next));
      return next;
    });
  }, []);

  const poll = useCallback((localId, apiId) => {
    if (timers.current[localId]) return;
    timers.current[localId] = setInterval(async () => {
      try {
        const { data } = await axios.get(`${API_BASE}/api/download/${apiId}`);
        if (data.state === "completed") {
          clearInterval(timers.current[localId]); delete timers.current[localId];
          patch(localId, { state:"completed", progress:100, result:data.result, completedAt:new Date().toISOString() });
        } else if (data.state === "failed") {
          clearInterval(timers.current[localId]); delete timers.current[localId];
          patch(localId, { state:"failed", error:data.error||"Download failed", progress:data.progress||0 });
        } else {
          patch(localId, { state:data.state==="active"?"active":"queued", progress:data.progress||0 });
        }
      } catch {
        clearInterval(timers.current[localId]); delete timers.current[localId];
        patch(localId, { state:"failed", error:"Lost connection" });
      }
    }, POLL_MS);
  }, [patch]);

  const addJob = useCallback(async (url, format) => {
    const id = `job_${Date.now()}`;
    const platform = detectPlatform(url);
    const job = { id, url, format, platform, state:"submitting", progress:0, createdAt:new Date().toISOString(), result:null, error:null };
    setJobs(prev => { const n=[job,...prev]; localStorage.setItem("grabr_jobs",JSON.stringify(n)); return n; });
    try {
      const { data } = await axios.post(`${API_BASE}/api/download`, { url, format });
      patch(id, { state:"queued", apiJobId:data.jobId });
      poll(id, data.jobId);
    } catch(e) {
      patch(id, { state:"failed", error:e.response?.data?.error||"Failed to start download" });
    }
  }, [patch, poll]);

  const removeJob = useCallback((id) => {
    clearInterval(timers.current[id]); delete timers.current[id];
    setJobs(prev => { const n=prev.filter(j=>j.id!==id); localStorage.setItem("grabr_jobs",JSON.stringify(n)); return n; });
  }, []);

  const clearAll = useCallback(() => {
    Object.values(timers.current).forEach(clearInterval);
    timers.current = {};
    save([]);
  }, [save]);

  useEffect(() => {
    jobs.forEach(j => { if (["queued","active","submitting"].includes(j.state) && j.apiJobId) poll(j.id, j.apiJobId); });
    return () => Object.values(timers.current).forEach(clearInterval);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { jobs, addJob, removeJob, clearAll };
}

function useSettings() {
  const def = { dark:true, defaultFormat:"mp4", autoPaste:true };
  const [s, set] = useState(() => { try { return {...def,...JSON.parse(localStorage.getItem("grabr_settings")||"{}")}; } catch { return def; } });
  const update = p => { set(prev => { const n={...prev,...p}; localStorage.setItem("grabr_settings",JSON.stringify(n)); return n; }); };
  return [s, update];
}

function Toggle({ on, onChange }) {
  return (
    <button onClick={()=>onChange(!on)} className={`tog ${on?"tog-on":""}`} aria-checked={on}>
      <span className="tog-knob"/>
    </button>
  );
}

// ═══════════════════════════════════════════
// HOME
// ═══════════════════════════════════════════
function HomePage({ settings, onStart }) {
  const [url, setUrl]       = useState("");
  const [format, setFormat] = useState(settings.defaultFormat);
  const [platform, setPl]   = useState(null);
  const [valid, setValid]   = useState(false);
  const [busy, setBusy]     = useState(false);
  const [done, setDone]     = useState(false);
  const [clip, setClip]     = useState("");
  const inputRef = useRef();

  useEffect(() => { setFormat(settings.defaultFormat); }, [settings.defaultFormat]);
  useEffect(() => {
    const v = isValidUrl(url.trim());
    setValid(v); setPl(v ? detectPlatform(url.trim()) : null);
  }, [url]);

  const tryClip = async () => {
    if (!settings.autoPaste || url) return;
    try { const t = await navigator.clipboard.readText(); if(isValidUrl(t)) setClip(t); } catch {}
  };

  const submit = async () => {
    if (!valid || busy) return;
    setBusy(true);
    await onStart(url.trim(), format);
    setBusy(false); setDone(true); setTimeout(()=>{setDone(false);setUrl("");},2200);
  };

  const SUPPORTED = [
    {id:"youtube",  label:"YouTube"},
    {id:"instagram",label:"Instagram"},
    {id:"tiktok",  label:"TikTok"},
    {id:"twitter", label:"Twitter"},
  ];

  const FORMATS = ["mp4","mp3","720p","1080p","m4a"];

  return (
    <div className="pg">
      {/* ── Hero banner ── */}
      <div className="hero-banner">
        <div className="hero-badge">Social Media Video Downloader</div>
        <p className="hero-sub">Download from YouTube, Instagram, TikTok &amp; more</p>
      </div>

      {/* ── Input card ── */}
      <div className="card">
        {/* URL row */}
        <div className={`ufield ${valid?"ufield-ok":""} ${url&&!valid?"ufield-bad":""}`}>
          <I.Link />
          <input
            ref={inputRef}
            className="uinput"
            type="url"
            placeholder="Your link here..."
            value={url}
            onChange={e=>{setUrl(e.target.value);setClip("");}}
            onFocus={tryClip}
            disabled={busy}
            spellCheck={false}
            autoComplete="off"
          />
          {url
            ? <button className="uaction" onClick={()=>setUrl("")}><I.X /></button>
            : <button className="uaction" onClick={async()=>{try{const t=await navigator.clipboard.readText();setUrl(t);}catch{}}}>
                <I.Clip />
              </button>
          }
        </div>

        {/* Clipboard hint */}
        {clip && !url && (
          <button className="clip-hint" onClick={()=>{setUrl(clip);setClip("");}}>
            <I.Clip />
            <span>Paste:</span>
            <span className="clip-preview">{clip.slice(0,40)}…</span>
          </button>
        )}

        {/* Platform detected */}
        {platform && (
          <div className="pl-badge" style={{background:PLATFORMS[platform].bg, borderColor:PLATFORMS[platform].color+"55"}}>
            <PlatformLogo id={platform} size={18} />
            <span style={{color:PLATFORMS[platform].color, fontWeight:600}}>{PLATFORMS[platform].name} detected ✓</span>
          </div>
        )}

        {url && !valid && <p className="url-err">⚠ Unsupported — try YouTube, Instagram, TikTok or Twitter</p>}

        {/* Format chips */}
        <div className="fmt-row">
          {FORMATS.map(f=>(
            <button key={f} className={`fchip ${format===f?"fchip-on":""}`} onClick={()=>setFormat(f)} disabled={busy}>
              {f.toUpperCase()}
            </button>
          ))}
        </div>

        {/* Paste + Download row */}
        <div className="btn-row">
          <button className="paste-btn" onClick={async()=>{try{const t=await navigator.clipboard.readText();setUrl(t);}catch{}}} disabled={busy}>
            <I.Clip /> Paste
          </button>
          <button
            className={`dl-btn ${valid&&!busy&&!done?"dl-ready":""} ${done?"dl-done":""}`}
            onClick={submit}
            disabled={!valid||busy}
          >
            {done   ? <><I.Tick /><span>Added!</span></>
            :busy   ? <><span className="spin"/><span>Starting…</span></>
            :         <><I.Save /><span>Download</span></>}
          </button>
        </div>
      </div>

      {/* ── Supported platforms ── */}
      <div className="sup-section">
        <p className="sup-label">Supported Socials</p>
        <div className="sup-grid">
          {SUPPORTED.map(p=>(
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
    await navigator.clipboard.writeText(`${window.location.origin}/files/${encodeURIComponent(job.result.filename)}`);
    setCopied(job.id); setTimeout(()=>setCopied(null), 2000);
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
        {jobs.map(job=>{
          const inProg = ["submitting","queued","active"].includes(job.state);
          return (
            <div key={job.id} className={`jcard jcard-${job.state}`}>
              <div className="jtop">
                <PlatformLogo id={job.platform} size={34} />
                <div className="jmeta">
                  <span className="jurl">{job.url.slice(0,44)}{job.url.length>44?"…":""}</span>
                  <div className="jtags">
                    <span className="jtag">{job.format.toUpperCase()}</span>
                    <span className="jtime">{timeAgo(job.createdAt)}</span>
                  </div>
                </div>
                <button className="jdel" onClick={()=>onRemove(job.id)}><I.Del /></button>
              </div>

              {inProg && (
                <div className="jprog">
                  <div className="jtrack"><div className="jfill" style={{width:`${Math.max(job.progress,job.state==="submitting"?3:6)}%`}}/></div>
                  <div className="jstrow">
                    <span className={`spill spill-${job.state}`}>
                      {job.state==="submitting"&&"🔄 Connecting"}
                      {job.state==="queued"&&"⏳ Queued"}
                      {job.state==="active"&&"⚡ Downloading"}
                    </span>
                    <span className="jpct">{job.progress}%</span>
                  </div>
                </div>
              )}

              {job.state==="completed"&&job.result&&(
                <div className="jresult">
                  <span className="jfname">✅ {job.result.filename}</span>
                  <div className="jrbtns">
                    <a href={`${API_BASE}/files/${encodeURIComponent(job.result.filename)}`} download={job.result.filename} className="rb rb-green">
                      <I.Save /> Save
                    </a>
                    <button className="rb rb-ghost" onClick={()=>doCopy(job)}>
                      {copied===job.id?<><I.Tick/> Copied!</>:<><I.Copy/> Link</>}
                    </button>
                  </div>
                </div>
              )}

              {job.state==="failed"&&(
                <div className="jerr">❌ {job.error}</div>
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
              {settings.dark?<I.Moon/>:<I.Sun/>}
              <div><p className="sname">Dark Mode</p><p className="sdesc">Easy on the eyes at night</p></div>
            </div>
            <Toggle on={settings.dark} onChange={v=>onUpdate({dark:v})} />
          </div>
        </div>

        <div className="sgroup">
          <p className="sglabel">Downloads</p>
          <div className="srow">
            <div className="sinfo">
              <I.Clip />
              <div><p className="sname">Auto-paste from clipboard</p><p className="sdesc">Auto-fill URL when you tap the input</p></div>
            </div>
            <Toggle on={settings.autoPaste} onChange={v=>onUpdate({autoPaste:v})} />
          </div>
          <div className="srow srow-col">
            <div className="sinfo">
              <I.Save />
              <div><p className="sname">Default Format</p><p className="sdesc">Pre-selected when you open the app</p></div>
            </div>
            <div className="fmt-row" style={{marginTop:"0.5rem"}}>
              {["mp4","mp3","720p","1080p","m4a"].map(f=>(
                <button key={f} className={`fchip ${settings.defaultFormat===f?"fchip-on":""}`} onClick={()=>onUpdate({defaultFormat:f})}>
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
            <input className="api-inp" type="text" defaultValue={API_BASE||"http://localhost:3000"} readOnly />
          </div>
        </div>

        <div className="sgroup">
          <p className="sglabel">Supported Platforms</p>
          <div className="plat-list">
            {Object.entries(PLATFORMS).map(([id,p])=>(
              <div key={id} className="plat-row">
                <PlatformLogo id={id} size={28} />
                <span className="plat-name">{p.name}</span>
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
export default function App() {
  const [tab, setTab]           = useState("home");
  const [settings, updSettings] = useSettings();
  const { jobs, addJob, removeJob, clearAll } = useDownloadManager();

  const activeCount = jobs.filter(j=>["submitting","queued","active"].includes(j.state)).length;

  useEffect(() => {
    document.documentElement.className = settings.dark ? "dark" : "light";
  }, [settings.dark]);

  const TABS = [
    {id:"home",      label:"Home",      Icon:I.Home},
    {id:"downloads", label:"Downloads", Icon:I.DL},
    {id:"settings",  label:"Settings",  Icon:I.Cog},
  ];

  const handleStart = async (url, fmt) => {
    await addJob(url, fmt);
    setTab("downloads");
  };

  return (
    <div className="shell">
      <div className="content">
        {tab==="home"      && <HomePage      settings={settings} onStart={handleStart} />}
        {tab==="downloads" && <DownloadsPage jobs={jobs} onRemove={removeJob} onClear={clearAll} />}
        {tab==="settings"  && <SettingsPage  settings={settings} onUpdate={updSettings} />}
      </div>

      <nav className="bnav">
        {TABS.map(({id,label,Icon})=>(
          <button key={id} className={`nbtn ${tab===id?"nbtn-on":""}`} onClick={()=>setTab(id)}>
            <span className="nbtn-ico">
              <Icon />
              {id==="downloads"&&activeCount>0&&<span className="nbadge">{activeCount}</span>}
            </span>
            <span className="nbtn-lbl">{label}</span>
          </button>
        ))}
      </nav>
    </div>
  );
}