const config = require("../config");

const ALLOWED_FORMATS = new Set(["best", "mp4", "mp3", "webm", "m4a", "720p", "1080p", "480p", "360p"]);

function validateUrl(rawUrl) {
  if (!rawUrl || typeof rawUrl !== "string") {
    return { valid: false, reason: "URL must be a non-empty string" };
  }
  const trimmed = rawUrl.trim();
  if (trimmed.length > 2048) return { valid: false, reason: "URL exceeds maximum length" };
  if (!/^https?:\/\//i.test(trimmed)) return { valid: false, reason: "URL must start with http:// or https://" };
  let parsed;
  try { parsed = new URL(trimmed); } catch { return { valid: false, reason: "URL is not parseable" }; }
  const hostname = parsed.hostname.replace(/^(www\.|m\.|vm\.)/, "");
  const builtIn = ["youtube.com","youtu.be","instagram.com","tiktok.com","twitter.com","x.com","t.co"];
  const all = [...builtIn,...config.allowedDomains].map(d=>d.replace(/^(www\.|m\.|vm\.)/,""));
  const ok = all.some(d => hostname === d || hostname.endsWith("."+d));
  if (!ok) return { valid: false, reason: `Domain '${parsed.hostname}' is not supported. Supported: YouTube, Instagram, TikTok, Twitter/X.` };
  return { valid: true, url: trimmed };
}

function validateFormat(format) {
  if (!format) return { valid: true, format: "best" };
  if (!ALLOWED_FORMATS.has(format)) return { valid: false, reason: `Format '${format}' is not supported. Allowed: ${[...ALLOWED_FORMATS].join(", ")}` };
  return { valid: true, format };
}

module.exports = { validateUrl, validateFormat, ALLOWED_FORMATS };