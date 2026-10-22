// The /b/ page (specs/book-sharing.md, "The /b/ page"), built from the mixtape page.
// The key comes from the fragment and goes nowhere else: no request, no storage. The details are
// fetched and the manifest authenticated before anything is shown. Starting to listen is always an
// explicit choice, because it spends one of the link's listeners; the session then lasts as long as
// the link. One chapter is fetched and decrypted at a time, and play runs on into the next chapter.
//
// localStorage holds, per link, only {token, expiresAt, chapter, seconds}: the session token, the
// link's deadline (which is the session's; extending the link extends both) and the listening position (the chapter's random ID and the seconds into it). Never the key
// and never a title. It is deleted on expiry, on any 410 from a book route (revoked reads as
// expired) and on a 401 session, and every book page load sweeps expired entries of every link.
// Every access is wrapped so the page works with storage blocked.
import { audioType, base64UrlDecode, ShareCryptoError } from "./share-crypto.mjs";
import { authenticateBook, openChapter, openText } from "./share-book-crypto.mjs";
import { readBounded } from "./mixtape-manifest.mjs";
const $ = id => document.getElementById(id);
const data = JSON.parse($("book-data").textContent);
const audio = $("audio"), api = data.id ? `/v1/share/b/${data.id}` : null;
const entryPrefix = "baton-book:", storageKey = data.id ? entryPrefix + data.id : null;
let root = null, book = null, session = null, currentURL = null, loadedIndex = -1, selected = 0;
let busy = false, closed = false, cancelLoad = null, loadGeneration = 0, bookDeadline = 0;
let remainingListeners = null; // display only; the service enforces the cap
let started = false, thirty = false, completed = false, listened = 0, lastTick = null;
let resumeAt = null, savedAt = 0, segments = null, segmentsFor = -1, shownSegment = -1;
const texts = new Map(); // chapter index → decrypted read-along segments, this page only
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

// ---------- The resume entry ----------

function forget() { try { if (storageKey) localStorage.removeItem(storageKey); } catch {} }
// deadline: the link's current one, when the details are known (an extension moves it later).
const usable = (value, deadline = 0) => object(value) && Object.keys(value).sort().join(",") === "chapter,expiresAt,seconds,token" && Boolean(canonical(value.token, 32)) &&
  Number.isSafeInteger(value.expiresAt) && Math.max(value.expiresAt, deadline) > Date.now() && typeof value.chapter === "string" && Number.isFinite(value.seconds) && value.seconds >= 0;
// Every book page load deletes the entries of any link that has passed its deadline (or is unreadable),
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
  if (!session || !book || closed) return;
  if (session.expiresAt <= Date.now()) { forget(); return; }
  const now = Date.now();
  if (!force && now - savedAt < 2000) return;
  savedAt = now;
  const index = loadedIndex >= 0 ? loadedIndex : selected;
  const seconds = loadedIndex >= 0 ? audio.currentTime : resumeAt?.index === index ? resumeAt.seconds : 0;
  try {
    localStorage.setItem(storageKey, JSON.stringify({ token: session.token, expiresAt: session.expiresAt,
      chapter: book.chapters[index].id, seconds: Math.floor((Number.isFinite(seconds) ? seconds : 0) * 10) / 10 }));
  } catch {}
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
  $("title").textContent = "This book’s link has expired"; document.title = "This book’s link has expired";
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
// The card names the selected chapter; the list marks the loaded (or loading) one.
function showChapter(index) {
  const chapter = book.chapters[index];
  $("current").textContent = chapter.title; $("current-of").textContent = `Chapter ${index + 1} of ${book.chapters.length}`;
  if (index !== loadedIndex || !currentURL) {
    const at = resumeAt?.index === index ? resumeAt.seconds : 0;
    progress(at, chapter.durationSeconds); times(at, chapter.durationSeconds);
  }
}
function controls() {
  if (!book || closed) return;
  const playing = Boolean(currentURL) && !audio.paused, none = remainingListeners === 0 && !session;
  $("play").disabled = busy || none;
  $("play").dataset.mode = busy ? "loading" : playing ? "pause" : "play";
  $("play").setAttribute("aria-label", busy ? "Loading" : playing ? "Pause" : "Play");
  $("play").setAttribute("aria-busy", busy ? "true" : "false");
  $("previous").disabled = busy || none || selected === 0;
  $("next").disabled = busy || none || selected === book.chapters.length - 1;
  const current = busy ? selected : currentURL ? loadedIndex : -1;
  for (const [index, button] of [...$("chapters").querySelectorAll("button")].entries()) {
    button.disabled = busy || none;
    if (index === current) button.setAttribute("aria-current", "true"); else button.removeAttribute("aria-current");
  }
  $("seek").disabled = busy || !currentURL;
  for (const button of $("reactions").querySelectorAll("button")) button.disabled = !session;
}
function releaseTrack() {
  audio.pause(); audio.removeAttribute("src"); audio.load();
  if (currentURL) URL.revokeObjectURL(currentURL);
  currentURL = null; loadedIndex = -1; lastTick = null;
  segments = null; segmentsFor = -1; shownSegment = -1; $("readalong").hidden = true;
}

// ---------- Requests ----------

// One absolute deadline covers headers and the whole body, so a slow drip cannot restart it.
// Every request is owned by this page and canceled when it goes away. Any 410 from a book route,
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
  if (deadline > bookDeadline) { bookDeadline = deadline; $("ends").textContent = endsLabel(bookDeadline); }
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
async function playChapter(index, confirmed = false) {
  if (busy || closed || !book || index < 0 || index >= book.chapters.length) return;
  // Resume, pause and seek reuse the chapter already decrypted.
  if (index === loadedIndex && currentURL) {
    try {
      if (audio.error) { audio.src = currentURL; audio.load(); }
      if (!audio.paused) audio.pause(); else await audio.play();
      status("");
    } catch { status("Audio could not start. Tap Play to try again."); }
    controls(); return;
  }
  selected = index; showChapter(index);
  if (!session && !confirmed) { confirmation(); return; }
  busy = true; $("admission").hidden = true; controls();
  const generation = ++loadGeneration;
  cancelLoad = new AbortController();
  status("Unlocking the chapter…");
  let prepared = false;
  try {
    if (!session) await admit();
    if (closed || generation !== loadGeneration) return;
    releaseTrack(); // release the previous plaintext before the next transfer and decryption
    remember(true);
    const chapter = book.chapters[index];
    const encrypted = await request(`/blobs/${chapter.id}`, { signal: cancelLoad.signal }, true, chapter.audioBytes, true);
    const plain = await openChapter(encrypted, root, chapter);
    if (closed || generation !== loadGeneration) { plain.fill(0); return; }
    try { currentURL = URL.createObjectURL(new Blob([plain], { type: audioType(plain) })); } finally { plain.fill(0); }
    prepared = true; loadedIndex = index; audio.src = currentURL;
    const at = resumeAt?.index === index ? resumeAt.seconds : 0;
    resumeAt = null;
    if (at > 0) await seekWhenReady(at);
    if (closed || generation !== loadGeneration) return;
    await audio.play(); status("");
    readAlong(index, generation);
  } catch (error) {
    if (closed) return;
    if (error.code === "session") {
      confirmation("This listening session has ended. Starting again uses another listener.");
    } else if (error.code === "transfer_budget") {
      forget(); confirmation("This listen has used its download allowance. Starting again uses another listener.");
    } else if (error.code === "play_cap") {
      remainingListeners = 0; chips(); confirmation("No listeners remain on this link. Ask the sender for a fresh one.");
    } else if (error.status === 410) {
      ended();
    } else if (["unsupported", "share_disabled"].includes(error.code)) {
      unavailable("unsupported", "Book links are unavailable here right now.");
    } else if (error instanceof ShareCryptoError || error instanceof SyntaxError) {
      event("decrypt_failed", { reason: error.reason === "auth" ? "auth" : "format" });
      unavailable("failed", "This chapter could not be authenticated. Ask the sender for a fresh link.");
    } else if (prepared) {
      status("Audio could not start. Tap Play to try again.");
    } else {
      // The session holds for the life of the link, so a retry spends no listener.
      status(error.code === "timeout" ? "The chapter did not arrive within one minute. Tap Play to try again." : "The chapter did not arrive. Tap Play to try again.");
    }
  } finally { busy = false; cancelLoad = null; controls(); }
}

// ---------- Read-along ----------

async function readAlong(index, generation) {
  const chapter = book.chapters[index];
  if (!chapter.text) return;
  try {
    let value = texts.get(index);
    if (!value) {
      const encrypted = await request(`/blobs/${chapter.text.id}`, {}, true, chapter.text.bytes, true);
      value = (await openText(encrypted, root, chapter)).filter(s => s.text.trim()).sort((a, b) => a.start - b.start);
      texts.set(index, value);
    }
    if (closed || generation !== loadGeneration || loadedIndex !== index || !value.length) return;
    segments = value; segmentsFor = index; shownSegment = -1;
    $("readalong").hidden = false; follow();
  } catch (error) {
    if (closed) return;
    if (error.status === 410) { ended(); return; }
    // Without its text the chapter plays the same.
    if (error instanceof ShareCryptoError || error instanceof SyntaxError) event("decrypt_failed", { reason: error.reason === "auth" ? "auth" : "format" });
  }
}
// The sentence under the audio clock, shown inside its paragraph.
function follow() {
  if (!segments || segmentsFor !== loadedIndex) return;
  const t = audio.currentTime;
  let lo = 0, hi = segments.length - 1, found = 0;
  while (lo <= hi) { const mid = (lo + hi) >> 1; if (segments[mid].start <= t) { found = mid; lo = mid + 1; } else hi = mid - 1; }
  if (found === shownSegment) return;
  shownSegment = found;
  const paragraph = segments[found].paragraph;
  let first = found, last = found;
  if (paragraph >= 0) {
    while (first > 0 && segments[first - 1].paragraph === paragraph) first--;
    while (last < segments.length - 1 && segments[last + 1].paragraph === paragraph) last++;
  }
  const box = $("paragraph"), nodes = [];
  for (let i = first; i <= last; i++) {
    const span = document.createElement("span");
    span.textContent = segments[i].text.trim();
    if (i === found) span.className = "current";
    if (i > first) nodes.push(" ");
    nodes.push(span);
  }
  box.replaceChildren(...nodes);
  const current = box.querySelector(".current");
  box.scrollTop = Math.max(0, current.offsetTop - box.clientHeight / 3);
}

// ---------- Wiring ----------

$("play").addEventListener("click", () => playChapter(selected));
$("previous").addEventListener("click", () => playChapter(selected - 1));
$("next").addEventListener("click", () => playChapter(selected + 1));
$("confirm").addEventListener("click", () => { $("admission").hidden = true; playChapter(selected, true); });
$("cancel").addEventListener("click", () => { $("admission").hidden = true; status(""); controls(); $("play").focus(); });
$("seek").addEventListener("input", () => {
  if (currentURL && Number.isFinite(audio.duration)) {
    audio.currentTime = audio.duration * Number($("seek").value) / 1000; lastTick = null;
    $("seek").style.setProperty("--progress", `${Number($("seek").value) / 10}%`); times(audio.currentTime, audio.duration);
    follow(); remember(true);
  }
});
function clock() {
  const now = performance.now();
  if (!audio.paused && !audio.seeking && audio.readyState >= 3) {
    if (lastTick !== null) listened += Math.max(0, Math.min((now - lastTick) / 1000, 1));
    lastTick = now;
    if (!thirty && listened >= 30) { thirty = true; event("play_30s"); }
  } else lastTick = null;
  if (!book || loadedIndex < 0) return;
  const duration = Number.isFinite(audio.duration) ? audio.duration : book.chapters[loadedIndex].durationSeconds;
  times(audio.currentTime, duration);
  if (duration && !audio.seeking) progress(audio.currentTime, duration);
  follow(); remember();
}
audio.addEventListener("timeupdate", clock);
audio.addEventListener("playing", () => { if (!started) { started = true; event("play_started"); } lastTick = performance.now(); controls(); });
audio.addEventListener("pause", () => { clock(); lastTick = null; remember(true); if (book) controls(); });
audio.addEventListener("seeking", () => { lastTick = null; });
audio.addEventListener("waiting", () => { lastTick = null; });
audio.addEventListener("error", () => { if (currentURL) status("Audio could not play. Tap Play to try again."); if (book) controls(); });
audio.addEventListener("ended", () => {
  lastTick = null; remember(true);
  if (loadedIndex === book.chapters.length - 1) {
    if (!completed) { completed = true; event("play_completed"); }
    status("You reached the end of the book."); controls(); return;
  }
  playChapter(loadedIndex + 1);
});

function render(details) {
  $("title").textContent = book.title; document.title = book.title;
  $("byline").textContent = book.author ? `By ${book.author}` : ""; $("byline").hidden = !book.author;
  $("from").textContent = book.from ? `From ${book.from}` : ""; $("from").hidden = !book.from;
  $("note").textContent = book.note; $("note").hidden = !book.note;
  $("length").textContent = `${plural(book.chapters.length, "chapter", "chapters")} · ${length(book.durationSeconds)}`;
  $("ends").textContent = endsLabel(bookDeadline); $("ends").hidden = false;
  remainingListeners = details.remainingListeners;
  chips(); $("chips").hidden = false;
  const element = (tag, className, text) => { const node = document.createElement(tag); node.className = className; if (text !== undefined) node.textContent = text; return node; };
  for (const [index, chapter] of book.chapters.entries()) {
    const li = document.createElement("li"), button = element("button", "row"), words = element("span", "row-text");
    const speaker = document.createElementNS("http://www.w3.org/2000/svg", "svg"), path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    speaker.setAttribute("viewBox", "0 0 24 24"); speaker.setAttribute("class", "row-speaker"); speaker.setAttribute("aria-hidden", "true");
    path.setAttribute("d", "M4 9.5h3.5L12 5.5v13l-4.5-4H4zM15 8.6a4.5 4.5 0 0 1 0 6.8l-1-1.1a3 3 0 0 0 0-4.6zm2.4-2.5a8 8 0 0 1 0 11.8l-1.1-1.1a6.4 6.4 0 0 0 0-9.6z");
    speaker.append(path);
    words.append(element("span", "row-title", chapter.title));
    if (chapter.text) words.append(element("span", "row-by", "Read-along text"));
    button.type = "button";
    button.setAttribute("aria-label", `Chapter ${index + 1}: ${chapter.title}, ${fmt(chapter.durationSeconds)}${chapter.text ? ", with read-along text" : ""}`);
    button.append(element("span", "row-num", String(index + 1)), speaker, words, element("span", "row-time", fmt(chapter.durationSeconds)));
    button.addEventListener("click", () => playChapter(index)); li.append(button); $("chapters").append(li);
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
}
async function initialize() {
  sweep(["ready", "pending"].includes(data.state) ? storageKey : null);
  if (!api) return;
  if (data.state === "expired") { forget(); return; }
  if (!["ready", "pending"].includes(data.state)) return;
  root = canonical(location.hash.slice(1), 16);
  if (!root) { unavailable("incomplete", "This link is incomplete. Copy all of it, including the part after #."); return; }
  // The fragment stays in the address bar: it is what lets a reload resume, since the key is never stored.
  try {
    let details = await json("", {}, false, 524288);
    for (let attempt = 0; details?.status === "pending"; attempt++) {
      if (attempt === 40) { status("Still not here. Ask whoever sent it whether it finished sending."); return; }
      if (attempt === 0) status("The sender is still uploading this book. This page opens it when it is ready.");
      await sleep(3000);
      if (closed) return;
      details = await json("", {}, false, 524288);
    }
    bookDeadline = Date.parse(details?.expiresAt);
    if (!object(details) || details.status !== "ready" || !Number.isFinite(bookDeadline) || bookDeadline <= Date.now() ||
        !Number.isSafeInteger(details.remainingListeners) || details.remainingListeners < 0) throw new ShareCryptoError("format", "Invalid lifecycle");
    book = await authenticateBook(details, root);
    if (closed) { book = null; return; }
    document.body.dataset.state = "ready";
    render(details);
    const stored = remembered(bookDeadline);
    const index = stored ? book.chapters.findIndex(chapter => chapter.id === stored.chapter) : -1;
    if (index >= 0) {
      // Resume with the stored session: no admission, no listener spent. A 401 later asks again.
      // An extended link extends its sessions, so the stored deadline follows the link's.
      session = { token: stored.token, expiresAt: Math.max(stored.expiresAt, bookDeadline) };
      selected = index; resumeAt = { index, seconds: Math.min(stored.seconds, book.chapters[index].durationSeconds) };
      const before = book.chapters.slice(0, index).reduce((sum, chapter) => sum + chapter.durationSeconds, 0);
      started = before + resumeAt.seconds > 0; thirty = before + resumeAt.seconds >= 30;
      if (session.expiresAt !== stored.expiresAt) remember(true);
      showChapter(index); $("player").hidden = false; controls();
      status(`Welcome back. Play resumes chapter ${index + 1} at ${fmt(resumeAt.seconds)}.`);
    } else {
      if (stored) forget();
      showChapter(0); $("player").hidden = false; confirmation("", false);
    }
  } catch (error) {
    if (closed) return;
    if (error.status === 410) ended();
    else if (error.status === 404) unavailable("unknown", "This link doesn’t lead anywhere. Check that you copied all of it.");
    else if (error.code === "unsupported") unavailable("unsupported", "Book links are unavailable here right now.");
    else if (error instanceof ShareCryptoError && error.reason === "auth") unavailable("failed", "This link’s key does not open this book. Check that you copied all of it.");
    else if (error instanceof ShareCryptoError || error instanceof SyntaxError) unavailable("failed", "This book could not be authenticated. Ask the sender for a fresh link.");
    else unavailable("failed", error.code === "timeout" ? "The book did not arrive within one minute. Reopen the link to try again." : "This book could not be loaded. Reopen the link to try again.");
  }
}
function dispose() {
  remember(true);
  closed = true; ++loadGeneration; cancelLoad?.abort();
  for (const controller of ownedRequests) controller.abort();
  ownedRequests.clear(); releaseTrack(); texts.clear();
  root?.fill(0); root = null; session = null; book = null;
}
window.addEventListener("pagehide", dispose);
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") remember(true); });
// Pasting another link can be a same-document navigation. Discard this one before reloading.
window.addEventListener("hashchange", () => { dispose(); location.reload(); });
// On a phone the player card docks under the list (book.css). Keep the DOM in that order too, so
// Tab meets the card where the eye does (WCAG 2.4.3); the <audio> inside the card never moves.
const phone = matchMedia("(max-width: 640px)");
function placeCard() {
  const card = $("card"), moving = [$("readalong"), $("chapters"), $("reactions")], focused = document.activeElement;
  if ((card === $("player").lastElementChild) === phone.matches) return;
  for (const node of moving) phone.matches ? card.before(node) : $("player").append(node);
  if (focused && moving.some(node => node.contains(focused)) && document.activeElement !== focused) focused.focus({ preventScroll: true });
}
phone.addEventListener("change", placeCard); placeCard();
initialize();
