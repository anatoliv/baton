// Baton Share — the player (specs/song-sharing.md §4.2, docs/plan-song-sharing.md §3).
//
// The page arrives with its state in #share-data. The key is the URL fragment, which no server
// ever sees. This module unlocks the song in the browser and plays it from a blob URL: no Media
// Source Extensions, which iOS Safari restricts, and seeking for free.

import { audioType, base64Decode, base64UrlDecode, open, ShareCryptoError } from "./share-crypto.mjs";

const data = JSON.parse(document.getElementById("share-data").textContent);
const $ = (id) => document.getElementById(id);
const body = document.body;
const api = data.id ? `/v1/share/p/${data.id}` : null;

const audio = new Audio();
audio.preload = "none";

let meta = data.share?.preview ?? null;
let key = null;
let unlocked = null; // the object URL once the song is decrypted
let artURL = null;
let loadStarted = 0;
let sentStarted = false;
let sent30 = false;
let sentCompleted = false;
let listened = 0; // seconds actually heard, not the playhead position
let lastTick = null;
let mediaFailed = false;
let playbackAttempt = 0;
let afterShown = false;

// ---------- Beacons ----------

function beacon(type, extra = {}) {
  if (!api) return;
  const payload = JSON.stringify({ type, ...extra });
  try {
    if (navigator.sendBeacon && navigator.sendBeacon(`${api}/events`, new Blob([payload], { type: "text/plain" }))) return;
  } catch {}
  fetch(`${api}/events`, { method: "POST", body: payload, keepalive: true, headers: { "Content-Type": "text/plain" } }).catch(() => {});
}

// ---------- States ----------

const copy = {
  incomplete: ["This link is incomplete", "Make sure you copied all of it, including the part after the #."],
  unknown: ["This link doesn’t lead anywhere", "Check that you copied all of it."],
  expired: ["This song’s link has expired", "Ask whoever sent it to send it again."],
  revoked: ["This song’s link has expired", "Ask whoever sent it to send it again."],
  failed: ["This song couldn’t be unlocked", "The link may be damaged. Ask whoever sent it for a fresh one."],
};

function setState(state, message) {
  body.dataset.state = state;
  if (state === "play_cap") {
    $("title").textContent = "This link has been played a lot";
    $("byline").textContent = `Ask ${meta?.from || "whoever sent it"} for a fresh one.`;
    $("player").hidden = true;
  } else if (copy[state]) {
    [$("title").textContent, $("byline").textContent] = copy[state];
    $("eyebrow").textContent = "";
    $("note").hidden = true;
    $("player").hidden = true;
  }
  status(message ?? "");
  document.title = $("title").textContent;
}

function status(text) {
  $("status").textContent = text;
}

// ---------- Rendering ----------

function fmt(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) seconds = 0;
  const s = Math.floor(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function renderMeta() {
  if (!meta) return;
  const from = meta.from || "Someone";
  $("eyebrow").textContent = `${from} sent you a song`;
  $("title").textContent = meta.title;
  $("byline").textContent = [meta.artist, meta.album].filter(Boolean).join(" · ");
  if (meta.note) {
    $("note-text").textContent = meta.note;
    $("note-from").textContent = `— ${from}`;
    $("note").hidden = false;
  }
  if (/^#[0-9A-Fa-f]{6}$/.test(meta.accent ?? "")) {
    document.documentElement.style.setProperty("--song", meta.accent);
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", meta.accent);
  }
  $("remaining").textContent = `-${fmt(meta.durationSeconds)}`;
  document.title = `${meta.title}${meta.artist ? ` — ${meta.artist}` : ""}`;
  drawWave();
}

// ---------- Waveform ----------

const canvas = $("wave");
const ctx = canvas.getContext("2d");

function peaks() {
  const p = meta?.peaks;
  if (Array.isArray(p) && p.length >= 8) return p;
  // No peaks sent: a calm, even shape rather than an empty bar.
  return Array.from({ length: 64 }, (_, i) => 90 + 50 * Math.sin(i * 0.55) * Math.sin(i * 0.13));
}

function drawWave() {
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (!width || !height) return;
  if (canvas.width !== Math.round(width * ratio)) {
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
  }
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);

  const values = peaks();
  const bars = Math.max(16, Math.min(values.length, Math.floor(width / 4)));
  const step = width / bars;
  const barWidth = Math.max(1.5, step * 0.6);
  const duration = audio.duration || meta?.durationSeconds || 0;
  const played = duration ? audio.currentTime / duration : 0;
  const style = getComputedStyle(document.documentElement);
  const song = style.getPropertyValue("--song").trim() || "#E98345";
  const rest = style.getPropertyValue("--wave-rest").trim();

  for (let i = 0; i < bars; i++) {
    const from = Math.floor((i / bars) * values.length);
    const to = Math.max(from + 1, Math.floor(((i + 1) / bars) * values.length));
    let peak = 0;
    for (let j = from; j < to; j++) peak = Math.max(peak, values[j] ?? 0);
    const h = Math.max(3, (peak / 255) * height * 0.92);
    ctx.fillStyle = (i + 0.5) / bars <= played ? song : rest;
    const x = i * step + (step - barWidth) / 2;
    const y = (height - h) / 2;
    ctx.beginPath();
    if (ctx.roundRect) ctx.roundRect(x, y, barWidth, h, barWidth / 2);
    else ctx.rect(x, y, barWidth, h);
    ctx.fill();
  }
}

new ResizeObserver(drawWave).observe(canvas);

// ---------- Artwork ----------

async function loadArt() {
  if (!api || !data.share?.hasArt) return;
  try {
    if (data.share.encryptedMeta) {
      const response = await fetch(`${api}/art`);
      if (!response.ok) return;
      const plain = await open(new Uint8Array(await response.arrayBuffer()), key, "art");
      artURL = URL.createObjectURL(new Blob([plain]));
    } else {
      artURL = `${api}/art`;
    }
    const img = $("art");
    img.onload = () => { img.hidden = false; };
    img.src = artURL;
  } catch {
    // The page is whole without the picture; the placeholder stays.
  }
}

// ---------- Unlocking and playing ----------

async function fetchWithProgress(url, total, onProgress) {
  const response = await fetch(url);
  if (response.status === 410) {
    const reason = await response.json().catch(() => ({}));
    throw Object.assign(new Error("gone"), { gone: reason.code || "expired" });
  }
  if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`);
  const length = Number(response.headers.get("Content-Length")) || total;
  const out = new Uint8Array(length);
  const reader = response.body.getReader();
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (received + value.length > out.length) throw new ShareCryptoError("format", "longer than declared");
    out.set(value, received);
    received += value.length;
    onProgress(received / length);
  }
  if (received !== length) throw new ShareCryptoError("auth", "truncated in transit");
  return out;
}

function progress(fraction) {
  $("play").style.setProperty("--progress", String(Math.max(0.02, Math.min(1, fraction))));
}

async function unlock() {
  body.classList.add("is-loading");
  $("play").setAttribute("aria-label", "Loading");
  status("Unlocking the song…");
  try {
    const sealed = await fetchWithProgress(`${api}/audio`, data.share.audioBytes, (f) => progress(f * 0.85));
    const plain = await open(sealed, key, "audio", (f) => progress(0.85 + f * 0.15));
    unlocked = URL.createObjectURL(new Blob([plain], { type: audioType(plain) }));
    audio.src = unlocked;
    $("seek").disabled = false;
    status("");
    return true;
  } catch (error) {
    if (error.gone) {
      setState(error.gone === "play_cap" ? "play_cap" : "expired");
    } else if (error instanceof ShareCryptoError) {
      beacon("decrypt_failed", { reason: error.reason === "format" ? "format" : "auth" });
      setState("failed");
    } else {
      status("The song didn’t arrive. Check your connection and tap play again.");
    }
    return false;
  } finally {
    body.classList.remove("is-loading");
    $("play").setAttribute("aria-label", "Play");
  }
}

async function toggle() {
  const attempt = ++playbackAttempt;
  // A platform output/decoder error leaves the media element unusable until load().
  // Retry the already decrypted blob; do not spend another fetch or listening session.
  if (unlocked && (mediaFailed || audio.error)) {
    audio.src = unlocked;
    audio.load();
  }
  if (unlocked && !audio.paused) {
    audio.pause();
    return;
  }
  if (!unlocked) {
    if (body.classList.contains("is-loading")) return;
    loadStarted = performance.now();
    // Call play() inside the tap, before any await. WebKit grants playback to an element the
    // first time play() runs under a user gesture; by the time the song is decrypted the gesture
    // is long gone, and a later play() on a fresh element would be refused.
    audio.play().catch(() => {});
    if (!(await unlock())) return;
  }
  try {
    await audio.play();
  } catch {
    if (attempt === playbackAttempt && !mediaFailed) status("Tap play to start.");
  }
}

$("play").addEventListener("click", toggle);

document.addEventListener("keydown", (event) => {
  if (event.code !== "Space" || event.target.closest("input, button, textarea")) return;
  if (body.dataset.state !== "ready") return;
  event.preventDefault();
  toggle();
});

$("seek").addEventListener("input", () => {
  if (!audio.duration) return;
  audio.currentTime = (Number($("seek").value) / 1000) * audio.duration;
  drawWave();
});

audio.addEventListener("playing", () => {
  if (audio.error) return;
  mediaFailed = false;
  status("");
  body.classList.add("is-playing");
  lastTick = performance.now();
  if (!sentStarted) {
    sentStarted = true;
    beacon("play_started", { ms: Math.round(performance.now() - loadStarted) });
  }
});

audio.addEventListener("pause", () => {
  body.classList.remove("is-playing");
  lastTick = null;
});

audio.addEventListener("error", () => {
  if (!unlocked) return; // the initial empty play() only grants WebKit its user gesture
  mediaFailed = true;
  // An audio renderer can fail after "playing" (for example, a device output failure).
  // Stop the active UI and offer the same explicit retry for decoder failures.
  audio.pause();
  body.classList.remove("is-playing", "is-loading");
  lastTick = null;
  $("play").setAttribute("aria-label", "Play");
  status("Couldn't play the song. Tap play to try again.");
});

audio.addEventListener("timeupdate", () => {
  if (mediaFailed) { lastTick = null; return; }
  const now = performance.now();
  if (lastTick !== null && !audio.paused) listened += Math.min(1.5, (now - lastTick) / 1000);
  lastTick = audio.paused ? null : now;
  const duration = audio.duration || meta?.durationSeconds || 0;
  $("elapsed").textContent = fmt(audio.currentTime);
  $("remaining").textContent = `-${fmt(duration - audio.currentTime)}`;
  if (duration) $("seek").value = String(Math.round((audio.currentTime / duration) * 1000));
  $("seek").setAttribute("aria-valuetext", `${fmt(audio.currentTime)} of ${fmt(duration)}`);
  drawWave();
  if (!sent30 && listened >= 30) {
    sent30 = true;
    beacon("play_30s");
    showAfter();
  }
});

audio.addEventListener("ended", () => {
  lastTick = null;
  if (mediaFailed) return;
  body.classList.remove("is-playing");
  if (!sentCompleted) {
    sentCompleted = true;
    beacon("play_completed");
  }
  showAfter();
});

// ---------- Lock screen ----------

function mediaSession() {
  if (!("mediaSession" in navigator) || !meta) return;
  const artwork = artURL ? [{ src: artURL, sizes: "600x600" }] : [];
  navigator.mediaSession.metadata = new MediaMetadata({ title: meta.title, artist: meta.artist, album: meta.album, artwork });
  navigator.mediaSession.setActionHandler("play", () => toggle());
  navigator.mediaSession.setActionHandler("pause", () => audio.pause());
  try {
    navigator.mediaSession.setActionHandler("seekto", (d) => { audio.currentTime = d.seekTime; });
  } catch {}
}

audio.addEventListener("playing", mediaSession, { once: true });

// ---------- After listening: react, and Get Baton ----------

let chosen = null;

function showAfter() {
  if (afterShown || !api) return;
  afterShown = true;
  const from = meta?.from;
  $("after-title").textContent = from ? `Let ${from} know you listened` : "Let them know you listened";
  const row = $("reactions");
  for (const emoji of data.reactions) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = emoji;
    button.setAttribute("aria-pressed", "false");
    button.setAttribute("aria-label", `React with ${emoji}`);
    button.addEventListener("click", () => {
      chosen = emoji;
      for (const b of row.children) b.setAttribute("aria-pressed", String(b === button));
      $("reply").hidden = false;
    });
    row.append(button);
  }
  $("after").hidden = false;
}

$("send").addEventListener("click", async () => {
  if (!chosen) return;
  $("send").disabled = true;
  const response = await fetch(`${api}/reactions`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ emoji: chosen, name: $("reply-name").value, reply: $("reply-text").value }),
  }).catch(() => null);
  if (response?.ok) {
    $("reply").hidden = true;
    $("reactions").hidden = true;
    $("sent").textContent = `${chosen} Sent${meta?.from ? ` to ${meta.from}` : ""}.`;
    $("sent").hidden = false;
  } else {
    $("send").disabled = false;
    $("sent").textContent = response?.status === 429 ? "That’s plenty for today." : "Didn’t send. Try again?";
    $("sent").hidden = false;
  }
});

function setUpGetBaton() {
  const ua = navigator.userAgent;
  const isiOS = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  const isMac = !isiOS && /Macintosh/.test(ua);
  const link = $("get-baton");
  const target = isiOS ? "app_store" : isMac ? "mac_download" : "about";
  link.href = isiOS ? data.links.appStore : isMac ? data.links.macDownload : data.links.about;
  if (isiOS) $("get-baton-text").textContent = "for iPhone. Plays the music you own.";
  if (isMac) $("get-baton-text").textContent = "for Mac. Free, and plays the music you own.";
  link.addEventListener("click", () => beacon("get_baton_clicked", { target }));
}

// ---------- Start ----------

async function start() {
  setUpGetBaton();
  if (data.state === "unknown" || data.state === "expired" || data.state === "revoked") {
    setState(data.state);
    return;
  }

  key = base64UrlDecode(location.hash.slice(1));
  if (!key || key.length !== 16) {
    if (data.state === "ready") beacon("decrypt_failed", { reason: "missing_key" });
    setState("incomplete");
    return;
  }

  if (data.share?.encryptedMeta) {
    try {
      meta = JSON.parse(new TextDecoder().decode(await open(base64Decode(data.share.encryptedMeta), key, "meta")));
    } catch (error) {
      if (data.state === "ready") beacon("decrypt_failed", { reason: error instanceof ShareCryptoError ? error.reason : "format" });
      setState("incomplete");
      return;
    }
  }
  renderMeta();
  loadArt().then(mediaSession);

  if (data.state === "play_cap") {
    setState("play_cap");
    return;
  }
  if (data.state === "pending") {
    status("Arriving… the song is still on its way.");
    pollUntilReady();
    return;
  }
  $("player").hidden = false;
  drawWave();
}

async function pollUntilReady() {
  for (let attempt = 0; attempt < 40; attempt++) {
    await new Promise((r) => setTimeout(r, 3000));
    const response = await fetch(api).catch(() => null);
    if (response?.ok) {
      const share = await response.json();
      if (share.status === "ready") {
        location.reload();
        return;
      }
    } else if (response && response.status !== 404) {
      setState("expired");
      return;
    }
  }
  status("Still not here. Ask whoever sent it whether it finished sending.");
}

start();
