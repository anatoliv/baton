// The album and playlist page (specs/collection-sharing.md, "The page"): a /b/ link
// whose stored kind is album or playlist, built from the book page (book.mjs) and its rules.
// The key comes from the fragment and goes nowhere else: no request, no storage. The details are
// fetched and the manifest authenticated before anything is shown, the cover included (it travels
// inside the encrypted manifest). Starting to listen is always an explicit choice, because it spends
// one of the link's listeners; the session then lasts as long as the link. One track is fetched and
// decrypted at a time, and play runs on into the next one. Repeat one replays the track already in
// memory, so it spends no transfer.
//
// localStorage holds, per link, only {token, expiresAt, track, seconds, shuffle, repeat}: the session
// token, the link's deadline (which is the session's; extending the link extends both), the track's
// random ID, the seconds into it, and the shuffle and repeat choices. Never the key and never a title.
// It is deleted on expiry, on any 410 from a /b/ route (revoked reads as expired), on a 401 session
// and on a spent transfer allowance, and every collection page load sweeps expired entries of every
// link. Every access is wrapped so the page works with storage blocked.
import { base64UrlDecode, ShareCryptoError } from "./share-crypto.mjs";
import { authenticateBook, openChapter } from "./share-book-crypto.mjs";
import { readBounded } from "./mixtape-manifest.mjs";
const $ = id => document.getElementById(id);
const data = JSON.parse($("collection-data").textContent);
const audio = $("audio"), api = data.id ? `/v1/share/b/${data.id}` : null;
const entryPrefix = "baton-collection:", storageKey = data.id ? entryPrefix + data.id : null;
const REPEATS = ["off", "all", "one"];
let kind = ["album", "playlist"].includes(data.kind) ? data.kind : "album"; // the manifest's, once authenticated
let root = null, music = null, session = null, currentURL = null, coverURL = null, loadedIndex = -1, selected = 0;
let order = [], position = 0, shuffle = false, repeat = "off";
let busy = false, closed = false, cancelLoad = null, loadGeneration = 0, linkDeadline = 0;
let remainingListeners = null; // display only; the service enforces the cap
let started = false, thirty = false, completed = false, listened = 0, lastTick = null;
let resumeAt = null, savedAt = 0;
const ownedRequests = new Set();
const resourceDeadlineMilliseconds = 60000;
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const canonical = (value, length) => {
  if (typeof value !== "string") return null;
  const bytes = base64UrlDecode(value);
  if (!bytes || bytes.length !== length || btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") !== value) return null;
  return bytes;
};
const status = message => { $("status").textContent = message; };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const fmt = value => {
  const s = Math.max(0, Math.floor(value)), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
};
const length = s => s < 60 ? `${s} sec` : s < 3600 ? `${Math.round(s / 60)} min` : `${Math.floor(s / 3600)} h ${Math.floor(s % 3600 / 60)} min`;
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const noun = () => kind === "playlist" ? "playlist" : "album";
const tracks = () => music.chapters;
// The label a Blob gets from its own bytes: an MP4 box, an ADTS header (sync 0xFFF, layer 00), else MPEG audio.
function mediaType(bytes) {
  if (bytes.length >= 8 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70) return "audio/mp4";
  if (bytes.length >= 2 && bytes[0] === 0xff && (bytes[1] & 0xf6) === 0xf0) return "audio/aac";
  return "audio/mpeg";
}
// A playlist names each song's artist; an album only where a song's artist is not the album's.
const byline = track => track.artist && (kind === "playlist" || track.artist !== music.author) ? track.artist : "";
const number = index => kind === "album" && tracks()[index].trackNumber ? tracks()[index].trackNumber : index + 1;

// ---------- The resume entry ----------

function forget() { try { if (storageKey) localStorage.removeItem(storageKey); } catch {} }
// deadline: the link's current one, when the details are known (an extension moves it later).
const usable = (value, deadline = 0) => object(value) && Object.keys(value).sort().join(",") === "expiresAt,repeat,seconds,shuffle,token,track" &&
  Boolean(canonical(value.token, 32)) && Number.isSafeInteger(value.expiresAt) && Math.max(value.expiresAt, deadline) > Date.now() &&
  typeof value.track === "string" && Number.isFinite(value.seconds) && value.seconds >= 0 && typeof value.shuffle === "boolean" && REPEATS.includes(value.repeat);
// Every collection page load deletes the entries of any link that has passed its deadline (or is unreadable),
// so a link opened once and never again leaves nothing behind after it ends. This link's own entry
// waits for its details, which may carry an extended deadline.
function sweep(keep = null) {
  try {
    const keys = [];
    for (let i = 0; i < localStorage.length; i++) { const key = localStorage.key(i); if (key?.startsWith(entryPrefix)) keys.push(key); }
    for (const key of keys) {
      let value = null;
      try { value = JSON.parse(localStorage.getItem(key)); } catch {}
      if (key !== keep && !usable(value)) localStorage.removeItem(key);
    }
  } catch {}
}
function remembered(deadline) {
  let value;
  try { value = JSON.parse(localStorage.getItem(storageKey) ?? "null"); } catch { return null; }
  if (value === null) return null;
  if (!usable(value, deadline)) { forget(); return null; }
  return value;
}
function remember(force = false) {
  if (!session || !music || closed) return;
  if (session.expiresAt <= Date.now()) { forget(); return; }
  const now = Date.now();
  if (!force && now - savedAt < 2000) return;
  savedAt = now;
  const index = loadedIndex >= 0 ? loadedIndex : selected;
  const seconds = loadedIndex >= 0 ? audio.currentTime : resumeAt?.index === index ? resumeAt.seconds : 0;
  try {
    localStorage.setItem(storageKey, JSON.stringify({ token: session.token, expiresAt: session.expiresAt, track: tracks()[index].id,
      seconds: Math.floor((Number.isFinite(seconds) ? seconds : 0) * 10) / 10, shuffle, repeat }));
  } catch {}
}

// ---------- Play order: shuffle and repeat ----------

const natural = () => tracks().map((_, index) => index);
function shuffled(indexes) {
  const out = [...indexes];
  for (let i = out.length - 1; i > 0; i--) {
    const pick = crypto.getRandomValues(new Uint32Array(1))[0] % (i + 1);
    [out[i], out[pick]] = [out[pick], out[i]];
  }
  return out;
}
// Shuffle keeps the current song and puts every other one after it in a random order.
function arrange(first = selected) {
  order = shuffle ? [first, ...shuffled(natural().filter(index => index !== first))] : natural();
  position = Math.max(0, order.indexOf(first));
}
function nextTarget() {
  if (position < order.length - 1) return order[position + 1];
  return repeat === "all" ? order[0] : null;
}
const loadedCurrent = () => Boolean(currentURL) && loadedIndex === selected;
function previousTarget() {
  if (loadedCurrent() && audio.currentTime > 3) return "restart"; // the start of this song first, as a music player does
  if (position > 0) return order[position - 1];
  if (repeat === "all" && order.length > 1) return order[order.length - 1];
  return loadedCurrent() ? "restart" : null;
}
function go(target) {
  if (target === null) return;
  if (target === "restart" || (target === loadedIndex && currentURL)) {
    audio.currentTime = 0; lastTick = null; remember(true);
    if (audio.paused) playTrack(loadedIndex);
    return;
  }
  playTrack(target);
}
function setShuffle(on) {
  shuffle = on; arrange(selected); controls(); remember(true);
}
function showRepeat() {
  const labels = { off: "Repeat: off", all: "Repeat: all songs", one: "Repeat: this song" };
  $("repeat").dataset.repeat = repeat; $("repeat").setAttribute("aria-label", labels[repeat]);
}
function setRepeat(value) {
  repeat = value; showRepeat(); controls(); remember(true);
}

// ---------- States and controls ----------

function unavailable(state, message) {
  document.body.dataset.state = state;
  status(message); $("player").hidden = true; $("chips").hidden = true; $("admission").hidden = true;
  releaseTrack(); session = null;
}
// A revoked link reads exactly as an expired one, on the page as in every response.
function ended() {
  forget();
  unavailable("expired", "This link has expired. Ask whoever sent it for a fresh one.");
  const headline = `This ${noun()}’s link has expired`;
  $("title").textContent = headline; document.title = headline;
  $("byline").textContent = "Ask whoever sent it for a fresh one."; $("byline").hidden = false; $("from").hidden = true; $("note").hidden = true;
}
function chips() {
  $("listeners").hidden = remainingListeners === null;
  if (remainingListeners !== null) $("listeners").textContent = remainingListeners === 0 ? "No listeners left" : `${plural(remainingListeners, "listener", "listeners")} left`;
}
function endsLabel(deadline) {
  const end = new Date(deadline), today = end.toDateString() === new Date().toDateString();
  const when = new Intl.DateTimeFormat(undefined, today ? { hour: "numeric", minute: "2-digit", timeZoneName: "short" }
    : { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" }).format(end);
  return `Ends ${today ? "today, " : ""}${when}`;
}
function times(elapsed, duration) {
  $("elapsed").textContent = fmt(elapsed); $("remaining").textContent = `-${fmt(Math.max(0, duration - elapsed))}`;
}
function progress(elapsed, duration) {
  const fraction = duration > 0 ? Math.min(1, Math.max(0, elapsed / duration)) : 0;
  $("seek").value = String(Math.round(fraction * 1000)); $("seek").style.setProperty("--progress", `${fraction * 100}%`);
}
// The card names the selected song; the list marks the loaded (or loading) one.
function showTrack(index) {
  const track = tracks()[index], artist = track.artist || music.author;
  $("current").textContent = track.title;
  $("current-of").textContent = `${artist ? `${artist} · ` : ""}${position + 1} of ${tracks().length}${shuffle ? " · shuffled" : ""}`;
  if (index !== loadedIndex || !currentURL) {
    const at = resumeAt?.index === index ? resumeAt.seconds : 0;
    progress(at, track.durationSeconds); times(at, track.durationSeconds);
  }
}
function controls() {
  if (!music || closed) return;
  const playing = Boolean(currentURL) && !audio.paused, none = remainingListeners === 0 && !session;
  $("play").disabled = busy || none;
  $("play").dataset.mode = busy ? "loading" : playing ? "pause" : "play";
  $("play").setAttribute("aria-label", busy ? "Loading" : playing ? "Pause" : "Play");
  $("play").setAttribute("aria-busy", busy ? "true" : "false");
  $("previous").disabled = busy || none || (position === 0 && !(repeat === "all" && order.length > 1) && !loadedCurrent());
  $("next").disabled = busy || none || nextTarget() === null;
  $("shuffle").disabled = busy || none; $("repeat").disabled = busy || none;
  $("shuffle").setAttribute("aria-pressed", shuffle ? "true" : "false");
  const current = busy ? selected : currentURL ? loadedIndex : -1;
  for (const [index, button] of [...$("tracks").querySelectorAll("button")].entries()) {
    button.disabled = busy || none;
    if (index === current) button.setAttribute("aria-current", "true"); else button.removeAttribute("aria-current");
  }
  $("seek").disabled = busy || !currentURL;
  for (const button of $("reactions").querySelectorAll("button")) button.disabled = !session;
  if (music && selected < tracks().length) showTrack(selected);
}
function releaseTrack() {
  audio.pause(); audio.removeAttribute("src"); audio.load();
  if (currentURL) URL.revokeObjectURL(currentURL);
  currentURL = null; loadedIndex = -1; lastTick = null;
}

// ---------- Media Session (lock screen, headphones, keyboard media keys) ----------

function mediaMetadata(index) {
  if (!("mediaSession" in navigator) || typeof MediaMetadata !== "function") return;
  try {
    const track = tracks()[index];
    navigator.mediaSession.metadata = new MediaMetadata({ title: track.title, artist: track.artist || music.author,
      album: track.album || (kind === "album" ? music.title : ""), artwork: coverURL ? [{ src: coverURL, type: music.cover.type }] : [] });
  } catch {}
}
function mediaHandlers() {
  if (!("mediaSession" in navigator)) return;
  const handle = (action, handler) => { try { navigator.mediaSession.setActionHandler(action, handler); } catch {} };
  handle("play", () => { if (currentURL && audio.paused) audio.play().catch(() => {}); else if (!currentURL) playTrack(selected); });
  handle("pause", () => audio.pause());
  handle("previoustrack", () => go(previousTarget()));
  handle("nexttrack", () => go(nextTarget()));
  handle("seekto", details => {
    if (!currentURL || !Number.isFinite(details?.seekTime)) return;
    audio.currentTime = Math.max(0, Math.min(details.seekTime, Number.isFinite(audio.duration) ? audio.duration : details.seekTime)); lastTick = null; remember(true);
  });
}

// ---------- Requests ----------

// One absolute deadline covers headers and the whole body, so a slow drip cannot restart it.
// Every request is owned by this page and canceled when it goes away. Any 410 from a /b/ route,
// and a 401 for the session, deletes the resume entry before anything else happens.
async function request(path, options = {}, authenticated = false, maximum = 4096, exact = false) {
  if (closed) throw new Error("Page left");
  const headers = { ...options.headers };
  if (authenticated) {
    if (!session) throw Object.assign(new Error("Session ended"), { code: "session" });
    headers.Authorization = `Bearer ${session.token}`;
  }
  const controller = new AbortController();
  ownedRequests.add(controller);
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; controller.abort(); }, resourceDeadlineMilliseconds);
  const cancel = () => controller.abort();
  options.signal?.addEventListener("abort", cancel, { once: true });
  if (options.signal?.aborted) cancel();
  try {
    // Never follow redirects with the listener's token; paths are constructed locally.
    const response = await fetch(api + path, { ...options, headers, signal: controller.signal,
      credentials: "omit", cache: "no-store", referrerPolicy: "no-referrer", redirect: "error" });
    if (!response.ok) {
      if (response.status === 410 || (authenticated && response.status === 401)) forget();
      let reason = {};
      try { reason = JSON.parse(new TextDecoder().decode(await readBounded(response, 4096))); } catch {}
      throw Object.assign(new Error("Request refused"), { code: reason.code ?? "network", status: response.status });
    }
    if (response.status === 204) return new Uint8Array();
    return await readBounded(response, maximum, exact);
  } catch (error) {
    if (timedOut) throw Object.assign(new Error("Listening request timed out"), { code: "timeout" });
    throw error;
  } finally {
    clearTimeout(timer); options.signal?.removeEventListener("abort", cancel);
    controller.abort(); ownedRequests.delete(controller);
  }
}
async function json(path, options = {}, authenticated = false, maximum = 100000) {
  const bytes = await request(path, options, authenticated, maximum);
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}
function event(type, extra = {}) {
  if (!session || closed) return;
  request("/events", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ type, ...extra }) }, true)
    .catch(error => { if (error.status === 410 && !closed) ended(); });
}

// ---------- Admission ----------

// The one-line prompt. Starting to listen spends a listener, so it is always explicit.
function confirmation(message = "", focus = true) {
  audio.pause(); session = null;
  if (remainingListeners === 0) {
    $("admission").hidden = true; status(message || "No listeners remain on this link. Ask the sender for a fresh one."); controls(); return;
  }
  $("admission-text").textContent = remainingListeners === 1 ? "Start listening? It uses the last listener on this link."
    : remainingListeners === null ? "Start listening? It uses one listener on this link." : `Start listening? It uses 1 of the ${remainingListeners} listeners on this link.`;
  $("admission").hidden = false; status(message);
  controls(); if (focus) $("confirm").focus();
}
async function admit() {
  const value = await json("/sessions", { method: "POST" }, false, 4096);
  const deadline = Date.parse(value?.expiresAt);
  // A session lasts as long as the link, which the sender can extend while this page is open, so a
  // deadline later than the one the page loaded with is the link's new end. No link
  // runs past 30 days from now; a day of slack covers a viewer whose clock runs behind the server's.
  if (!object(value) || !canonical(value.token, 32) || !Number.isFinite(deadline) || deadline <= Date.now() || deadline > Date.now() + 2678400000 ||
      !Number.isSafeInteger(value.remainingBytes) || value.remainingBytes < 0 ||
      !Number.isSafeInteger(value.remainingListeners) || value.remainingListeners < 0) throw new ShareCryptoError("format", "Invalid session");
  if (closed) return;
  if (deadline > linkDeadline) { linkDeadline = deadline; $("ends").textContent = endsLabel(linkDeadline); }
  session = { token: value.token, expiresAt: deadline };
  remainingListeners = value.remainingListeners; chips();
  started = false; thirty = false; completed = false; listened = 0; lastTick = null;
  remember(true);
}

// ---------- Playback ----------

function seekWhenReady(seconds) {
  return new Promise(resolve => {
    const apply = () => {
      const end = Number.isFinite(audio.duration) ? Math.max(0, audio.duration - 0.25) : seconds;
      audio.currentTime = Math.min(seconds, end); resolve();
    };
    if (audio.readyState >= 1) { apply(); return; }
    audio.addEventListener("loadedmetadata", apply, { once: true });
    audio.addEventListener("error", resolve, { once: true });
  });
}
function select(index) {
  selected = index;
  const at = order.indexOf(index);
  if (at >= 0) position = at; else arrange(index);
  showTrack(index);
}
async function playTrack(index, confirmed = false) {
  if (busy || closed || !music || index < 0 || index >= tracks().length) return;
  // Resume, pause and seek reuse the song already decrypted.
  if (index === loadedIndex && currentURL) {
    try {
      if (audio.error) { audio.src = currentURL; audio.load(); }
      if (!audio.paused) audio.pause(); else await audio.play();
      status("");
    } catch { status("Audio could not start. Tap Play to try again."); }
    controls(); return;
  }
  select(index);
  if (!session && !confirmed) { confirmation(); return; }
  busy = true; $("admission").hidden = true; controls();
  const generation = ++loadGeneration;
  cancelLoad = new AbortController();
  status("Unlocking the song…");
  let prepared = false;
  try {
    if (!session) await admit();
    if (closed || generation !== loadGeneration) return;
    releaseTrack(); // release the previous plaintext before the next transfer and decryption
    remember(true);
    const track = tracks()[index];
    const encrypted = await request(`/blobs/${track.id}`, { signal: cancelLoad.signal }, true, track.audioBytes, true);
    const plain = await openChapter(encrypted, root, track);
    if (closed || generation !== loadGeneration) { plain.fill(0); return; }
    try { currentURL = URL.createObjectURL(new Blob([plain], { type: mediaType(plain) })); } finally { plain.fill(0); }
    prepared = true; loadedIndex = index; audio.src = currentURL;
    mediaMetadata(index);
    const at = resumeAt?.index === index ? resumeAt.seconds : 0;
    resumeAt = null;
    if (at > 0) await seekWhenReady(at);
    if (closed || generation !== loadGeneration) return;
    await audio.play(); status("");
  } catch (error) {
    if (closed) return;
    // Starting again is offered only while a listener remains; otherwise say why it ended.
    const again = remainingListeners === 0 ? " No listeners remain on this link. Ask the sender for a fresh one."
      : " Starting again uses another listener.";
    if (error.code === "session") {
      confirmation("This listening session has ended." + again);
    } else if (error.code === "transfer_budget") {
      forget(); confirmation("This listen has used its transfer allowance." + again);
    } else if (error.code === "play_cap") {
      remainingListeners = 0; chips(); confirmation("No listeners remain on this link. Ask the sender for a fresh one.");
    } else if (error.status === 410) {
      ended();
    } else if (["unsupported", "share_disabled"].includes(error.code)) {
      unavailable("unsupported", "Album and playlist links are unavailable here right now.");
    } else if (error instanceof ShareCryptoError || error instanceof SyntaxError) {
      event("decrypt_failed", { reason: error.reason === "auth" ? "auth" : "format" });
      unavailable("failed", "This song could not be authenticated. Ask the sender for a fresh link.");
    } else if (prepared) {
      status("Audio could not start. Tap Play to try again.");
    } else {
      // The session holds for the life of the link, so a retry spends no listener.
      status(error.code === "timeout" ? "The song did not arrive within one minute. Tap Play to try again." : "The song did not arrive. Tap Play to try again.");
    }
  } finally { busy = false; cancelLoad = null; controls(); }
}

// ---------- Wiring ----------

$("play").addEventListener("click", () => playTrack(selected));
$("previous").addEventListener("click", () => go(previousTarget()));
$("next").addEventListener("click", () => go(nextTarget()));
$("shuffle").addEventListener("click", () => setShuffle(!shuffle));
$("repeat").addEventListener("click", () => setRepeat(REPEATS[(REPEATS.indexOf(repeat) + 1) % REPEATS.length]));
$("confirm").addEventListener("click", () => { $("admission").hidden = true; playTrack(selected, true); });
$("cancel").addEventListener("click", () => { $("admission").hidden = true; status(""); controls(); $("play").focus(); });
$("seek").addEventListener("input", () => {
  if (currentURL && Number.isFinite(audio.duration)) {
    audio.currentTime = audio.duration * Number($("seek").value) / 1000; lastTick = null;
    $("seek").style.setProperty("--progress", `${Number($("seek").value) / 10}%`); times(audio.currentTime, audio.duration);
    remember(true);
  }
});
function clock() {
  const now = performance.now();
  if (!audio.paused && !audio.seeking && audio.readyState >= 3) {
    if (lastTick !== null) listened += Math.max(0, Math.min((now - lastTick) / 1000, 1));
    lastTick = now;
    if (!thirty && listened >= 30) { thirty = true; event("play_30s"); }
  } else lastTick = null;
  if (!music || loadedIndex < 0) return;
  const duration = Number.isFinite(audio.duration) ? audio.duration : tracks()[loadedIndex].durationSeconds;
  times(audio.currentTime, duration);
  if (duration && !audio.seeking) progress(audio.currentTime, duration);
  if ("mediaSession" in navigator && Number.isFinite(audio.duration) && audio.duration > 0) {
    try { navigator.mediaSession.setPositionState({ duration: audio.duration, position: Math.min(audio.currentTime, audio.duration), playbackRate: audio.playbackRate || 1 }); } catch {}
  }
  remember();
}
const playbackState = value => { try { if ("mediaSession" in navigator) navigator.mediaSession.playbackState = value; } catch {} };
audio.addEventListener("timeupdate", clock);
audio.addEventListener("playing", () => { if (!started) { started = true; event("play_started"); } lastTick = performance.now(); playbackState("playing"); controls(); });
audio.addEventListener("pause", () => { clock(); lastTick = null; remember(true); playbackState("paused"); if (music) controls(); });
audio.addEventListener("seeking", () => { lastTick = null; });
audio.addEventListener("waiting", () => { lastTick = null; });
audio.addEventListener("error", () => { if (currentURL) status("Audio could not play. Tap Play to try again."); if (music) controls(); });
audio.addEventListener("ended", () => {
  lastTick = null;
  if (!music || loadedIndex < 0) return;
  // Repeat one plays the decrypted song again from memory: no request, no transfer.
  if (repeat === "one") {
    audio.currentTime = 0;
    audio.play().catch(() => status("Audio could not start. Tap Play to try again."));
    remember(true); return;
  }
  const next = nextTarget();
  if (next === null) {
    remember(true);
    if (!completed) { completed = true; event("play_completed"); }
    status(`You reached the end of the ${noun()}.`); controls(); return;
  }
  go(next);
});

function showCover() {
  const cover = $("cover");
  // A placeholder tinted from the title, so two links without art still look different.
  let hue = 0;
  for (const c of music.title) hue = (hue * 31 + c.codePointAt(0)) % 360;
  cover.style.setProperty("--hue", String(hue));
  if (!music.cover) return;
  try { coverURL = URL.createObjectURL(new Blob([music.cover.bytes], { type: music.cover.type })); } catch { coverURL = null; return; }
  const art = $("art");
  art.addEventListener("load", () => { art.hidden = false; cover.classList.add("has-art"); }, { once: true });
  art.addEventListener("error", () => { art.hidden = true; cover.classList.remove("has-art"); }, { once: true });
  art.src = coverURL;
}
function render(details) {
  $("kind").textContent = kind === "playlist" ? "Playlist" : "Album";
  $("title").textContent = music.title; document.title = music.author ? `${music.title} · ${music.author}` : music.title;
  $("byline").textContent = music.author; $("byline").hidden = !music.author;
  $("from").textContent = music.from ? `From ${music.from}` : ""; $("from").hidden = !music.from;
  $("note").textContent = music.note; $("note").hidden = !music.note;
  $("length").textContent = `${plural(tracks().length, "song", "songs")} · ${length(music.durationSeconds)}`;
  $("ends").textContent = endsLabel(linkDeadline); $("ends").hidden = false;
  remainingListeners = details.remainingListeners;
  chips(); $("chips").hidden = false;
  $("shuffle").hidden = kind !== "playlist"; $("repeat").hidden = kind !== "playlist";
  $("player").setAttribute("aria-label", kind === "playlist" ? "Playlist player" : "Album player");
  showCover();
  const element = (tag, className, text) => { const node = document.createElement(tag); node.className = className; if (text !== undefined) node.textContent = text; return node; };
  for (const [index, track] of tracks().entries()) {
    const li = document.createElement("li"), button = element("button", "row"), words = element("span", "row-text");
    const speaker = document.createElementNS("http://www.w3.org/2000/svg", "svg"), path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    speaker.setAttribute("viewBox", "0 0 24 24"); speaker.setAttribute("class", "row-speaker"); speaker.setAttribute("aria-hidden", "true");
    path.setAttribute("d", "M4 9.5h3.5L12 5.5v13l-4.5-4H4zM15 8.6a4.5 4.5 0 0 1 0 6.8l-1-1.1a3 3 0 0 0 0-4.6zm2.4-2.5a8 8 0 0 1 0 11.8l-1.1-1.1a6.4 6.4 0 0 0 0-9.6z");
    speaker.append(path);
    const by = byline(track);
    words.append(element("span", "row-title", track.title));
    if (by) words.append(element("span", "row-by", by));
    button.type = "button";
    button.setAttribute("aria-label", `${number(index)}. ${track.title}${by ? `, ${by}` : ""}, ${fmt(track.durationSeconds)}`);
    button.append(element("span", "row-num", String(number(index))), speaker, words, element("span", "row-time", fmt(track.durationSeconds)));
    button.addEventListener("click", () => {
      if (index === loadedIndex && currentURL) { playTrack(index); return; }
      if (shuffle) arrange(index); // a chosen song starts a fresh shuffle from it
      playTrack(index);
    });
    li.append(button); $("tracks").append(li);
  }
  for (const reaction of data.reactions) {
    const button = document.createElement("button"); button.type = "button"; button.textContent = reaction; button.setAttribute("aria-label", `React ${reaction}`);
    button.addEventListener("click", async () => {
      button.disabled = true; $("reaction-status").textContent = "";
      try { await request("/reactions", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ emoji: reaction }) }, true); $("reaction-status").textContent = "Reaction sent."; }
      catch (error) { if (error.status === 410) { ended(); return; } $("reaction-status").textContent = "Reaction could not be sent. The session may have ended."; }
      finally { button.disabled = false; controls(); }
    }); $("reaction-status").before(button);
  }
  mediaHandlers();
}
async function initialize() {
  $("kind").textContent = kind === "playlist" ? "Playlist" : "Album";
  sweep(["ready", "pending"].includes(data.state) ? storageKey : null);
  if (!api) return;
  if (data.state === "expired") { ended(); return; }
  if (!["ready", "pending"].includes(data.state)) return;
  root = canonical(location.hash.slice(1), 16);
  if (!root) { unavailable("incomplete", "This link is incomplete. Copy all of it, including the part after #."); return; }
  // The fragment stays in the address bar: it is what lets a reload resume, since the key is never stored.
  try {
    let details = await json("", {}, false, 524288);
    for (let attempt = 0; details?.status === "pending"; attempt++) {
      if (attempt === 40) { status("Still not here. Ask whoever sent it whether it finished sending."); return; }
      if (attempt === 0) status(`The sender is still uploading this ${noun()}. This page opens it when it is ready.`);
      await sleep(3000);
      if (closed) return;
      details = await json("", {}, false, 524288);
    }
    linkDeadline = Date.parse(details?.expiresAt);
    if (!object(details) || details.status !== "ready" || !Number.isFinite(linkDeadline) || linkDeadline <= Date.now() ||
        !Number.isSafeInteger(details.remainingListeners) || details.remainingListeners < 0) throw new ShareCryptoError("format", "Invalid lifecycle");
    const opened = await authenticateBook(details, root);
    if (closed) return;
    // A book's details never reach this page; if they did, the page would not play them as music.
    if (!["album", "playlist"].includes(opened.kind)) throw new ShareCryptoError("format", "Not a collection");
    music = opened; kind = opened.kind;
    document.body.dataset.state = "ready";
    render(details);
    const stored = remembered(linkDeadline);
    const index = stored ? tracks().findIndex(track => track.id === stored.track) : -1;
    if (index >= 0) {
      // Resume with the stored session: no admission, no listener spent. A 401 later asks again.
      // An extended link extends its sessions, so the stored deadline follows the link's.
      session = { token: stored.token, expiresAt: Math.max(stored.expiresAt, linkDeadline) };
      shuffle = kind === "playlist" && stored.shuffle; repeat = kind === "playlist" ? stored.repeat : "off"; showRepeat();
      resumeAt = { index, seconds: Math.min(stored.seconds, tracks()[index].durationSeconds) };
      arrange(index); select(index);
      // A resumed listen has started already (no second play-started); its 30 seconds count from here.
      started = index > 0 || resumeAt.seconds > 0 || shuffle; thirty = resumeAt.seconds >= 30;
      if (session.expiresAt !== stored.expiresAt) remember(true);
      showTrack(index); $("player").hidden = false; controls();
      status(`Welcome back. Play resumes song ${number(index)} at ${fmt(resumeAt.seconds)}.`);
    } else {
      if (stored) forget();
      arrange(0); select(0); $("player").hidden = false; confirmation("", false);
    }
  } catch (error) {
    if (closed) return;
    if (error.status === 410) ended();
    else if (error.status === 404) unavailable("unknown", "This link doesn’t lead anywhere. Check that you copied all of it.");
    else if (error.code === "unsupported") unavailable("unsupported", "Album and playlist links are unavailable here right now.");
    else if (error instanceof ShareCryptoError && error.reason === "auth") unavailable("failed", `This link’s key does not open this ${noun()}. Check that you copied all of it.`);
    else if (error instanceof ShareCryptoError || error instanceof SyntaxError) unavailable("failed", `This ${noun()} could not be authenticated. Ask the sender for a fresh link.`);
    else unavailable("failed", error.code === "timeout" ? `The ${noun()} did not arrive within one minute. Reopen the link to try again.` : `This ${noun()} could not be loaded. Reopen the link to try again.`);
  }
}
function dispose() {
  remember(true);
  closed = true; ++loadGeneration; cancelLoad?.abort();
  for (const controller of ownedRequests) controller.abort();
  ownedRequests.clear(); releaseTrack();
  if (coverURL) URL.revokeObjectURL(coverURL);
  coverURL = null; root?.fill(0); root = null; session = null; music = null;
}
window.addEventListener("pagehide", dispose);
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") remember(true); });
// Pasting another link can be a same-document navigation. Discard this one before reloading.
window.addEventListener("hashchange", () => { dispose(); location.reload(); });
// On a phone the player card docks under the list (collection.css). Keep the DOM in that order too, so
// Tab meets the card where the eye does (WCAG 2.4.3); the <audio> inside the card never moves.
const phone = matchMedia("(max-width: 640px)");
function placeCard() {
  const card = $("card"), moving = [$("tracks"), $("reactions")], focused = document.activeElement;
  if ((card === $("player").lastElementChild) === phone.matches) return;
  for (const node of moving) phone.matches ? card.before(node) : $("player").append(node);
  if (focused && moving.some(node => node.contains(focused)) && document.activeElement !== focused) focused.focus({ preventScroll: true });
}
phone.addEventListener("change", placeCard); placeCard();
initialize();
