import { audioType, base64UrlDecode, ShareCryptoError } from "./share-crypto.mjs";
import { canonicalTrackID, openTrack } from "./share-mixtape-crypto.mjs";
import { authenticateManifest, readBounded } from "./mixtape-manifest.mjs";
const $ = id => document.getElementById(id);
const data = JSON.parse($("mixtape-data").textContent);
const audio = $("audio"), api = data.id ? `/v1/share/m/${data.id}` : null;
let root = null, manifest = null, session = null, currentURL = null, loadedIndex = -1, selected = 0;
let busy = false, pendingIndex = null, closed = false, cancelLoad = null, loadGeneration = 0;
let everAdmitted = false, containerDeadline = 0;
let started = false, thirty = false, completed = false, listened = 0, lastTick = null;
let remainingPlays = null; // display only; the service enforces the cap
const endedTracks = new Set();
const ownedRequests = new Set();
const resourceDeadlineMilliseconds = 60000;
const canonical = (value, length) => {
  const bytes = base64UrlDecode(value);
  if (!bytes || bytes.length !== length || btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") !== value) return null;
  return bytes;
};
const status = message => { $("status").textContent = message; };
const fmt = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
const length = seconds => seconds < 60 ? `${seconds} sec` : `${Math.round(seconds / 60)} min`;
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
function unavailable(state, message) {
  document.body.dataset.state = state;
  status(message); $("player").hidden = true; $("chips").hidden = true; releaseTrack(); session = null;
}
function chips() {
  $("plays-left").hidden = remainingPlays === null;
  if (remainingPlays !== null) $("plays-left").textContent = remainingPlays === 0 ? "No plays left" : `${plural(remainingPlays, "play", "plays")} left`;
}
function endsLabel(deadline) {
  const end = new Date(deadline), today = end.toDateString() === new Date().toDateString();
  const when = new Intl.DateTimeFormat(undefined, today ? { hour: "numeric", minute: "2-digit", timeZoneName: "short" }
    : { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" }).format(end);
  return `Ends ${today ? "today, " : ""}${when}`;
}
// The card names the selected track; the list marks the loaded (or loading) one.
function showTrack(index) {
  const track = manifest.tracks[index];
  $("current").textContent = track.metadata.title; $("current-by").textContent = track.metadata.artist;
  if (index !== loadedIndex || !currentURL) { $("seek").style.setProperty("--progress", "0%"); $("seek").value = "0"; times(0, track.metadata.durationSeconds); }
}
function times(elapsed, duration) {
  $("elapsed").textContent = fmt(elapsed); $("remaining").textContent = `-${fmt(Math.max(0, duration - elapsed))}`;
}
function controls() {
  if (!manifest || closed) return;
  const waiting = busy || pendingIndex !== null, playing = Boolean(currentURL) && !audio.paused;
  $("play").disabled = waiting;
  $("play").dataset.mode = busy ? "loading" : playing ? "pause" : "play";
  $("play").setAttribute("aria-label", busy ? "Loading" : playing ? "Pause" : "Play");
  $("play").setAttribute("aria-busy", busy ? "true" : "false");
  $("previous").disabled = waiting || selected === 0;
  $("next").disabled = waiting || selected === manifest.tracks.length - 1;
  const current = busy ? selected : currentURL ? loadedIndex : -1;
  for (const [index, button] of [...$("tracks").querySelectorAll("button")].entries()) {
    button.disabled = waiting;
    if (index === current) button.setAttribute("aria-current", "true"); else button.removeAttribute("aria-current");
  }
  $("seek").disabled = busy || !currentURL;
  for (const button of $("reactions").querySelectorAll("button")) button.disabled = !session;
}
function releaseTrack() {
  audio.pause(); audio.removeAttribute("src"); audio.load();
  if (currentURL) URL.revokeObjectURL(currentURL);
  currentURL = null; loadedIndex = -1; lastTick = null;
}
// One absolute foreground deadline covers headers and the entire response body.
// A slow drip cannot restart it. Every request, including analytics events, is owned
// by this page and is canceled when its invitation is disposed.
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
    // Never follow redirects with recipient credentials; paths are constructed locally.
    const response = await fetch(api + path, { ...options, headers, signal: controller.signal,
      credentials: "omit", cache: "no-store", referrerPolicy: "no-referrer", redirect: "error" });
    if (!response.ok) {
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
  request("/events", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ type, ...extra }) }, true).catch(() => {});
}
// The one-line session prompt. Starting a new listen spends a play, so it is always explicit.
function confirmation(index, message = "") {
  audio.pause(); session = null; pendingIndex = index;
  $("admission-text").textContent = remainingPlays === null || remainingPlays === 0 ? "Start a new listen? It uses 1 play from this link."
    : remainingPlays === 1 ? "Start a new listen? It uses your last play." : `Start a new listen? It uses 1 of your ${remainingPlays} plays.`;
  $("admission").hidden = false; status(message);
  controls(); $("confirm").focus();
}
// The transport's 503 "capacity" answers before the service handles the request, so it charged
// nothing: no play, no transfer bytes.
const uncharged = error => error.status === 503 && error.code === "capacity";
async function admit() {
  const before = everAdmitted;
  everAdmitted = true; // a lost admission response may already have spent a play
  let value;
  try { value = await json("/sessions", { method: "POST" }, false, 4096); }
  catch (error) { if (uncharged(error)) everAdmitted = before; throw error; }
  const deadline = Date.parse(value.expiresAt);
  // A session never outlives 30 minutes, and may end after the deadline this page loaded with:
  // the sender can extend the link while the page is open. A day of slack covers a viewer whose
  // clock runs behind the server's; with 1 s, such a viewer failed every admission.
  if (!canonical(value.token, 32) || !Number.isFinite(deadline) || deadline <= Date.now() || deadline > Date.now() + 1800000 + 86400000 ||
      !Number.isSafeInteger(value.remainingBytes) || value.remainingBytes < 0 || value.remainingBytes > manifest.audioBytes ||
      !Number.isSafeInteger(value.remainingPlays) || value.remainingPlays < 0) throw new ShareCryptoError("format", "Invalid session");
  if (closed) return;
  // A session past the loaded deadline means the sender extended the link. The session ends within
  // 30 minutes, not with the link, so the link's new end comes from its details.
  if (deadline > containerDeadline) refreshEnds();
  session = { token: value.token, expiresAt: deadline, remainingBytes: value.remainingBytes };
  remainingPlays = value.remainingPlays; chips();
  started = false; thirty = false; completed = false; listened = 0; lastTick = null; endedTracks.clear();
}
async function refreshEnds() {
  try {
    const details = await json("");
    const ends = Date.parse(details.expiresAt);
    if (!closed && Number.isFinite(ends) && ends > containerDeadline) { containerDeadline = ends; $("ends").textContent = endsLabel(ends); }
  } catch {}
}
async function playTrack(index, confirmed = false) {
  if (busy || closed || !manifest) return;
  // Resume, pause and seek do not reacquire a current authenticated buffer.
  if (index === loadedIndex && currentURL && !confirmed) {
    try {
      if (audio.error) { audio.src = currentURL; audio.load(); }
      if (!audio.paused) audio.pause(); else await audio.play();
      status("");
    } catch { status("Audio could not start. Tap Play to retry the retained track."); }
    controls(); return;
  }
  const track = manifest.tracks[index];
  if (!confirmed && session && (session.expiresAt <= Date.now() || session.remainingBytes < track.audioBytes)) {
    confirmation(index); return;
  }
  // After a previous admission, an invalid session is never replaced on an ordinary Play.
  if (!confirmed && !session && everAdmitted) { confirmation(index); return; }
  busy = true; selected = index; showTrack(index); controls();
  const generation = ++loadGeneration;
  cancelLoad = new AbortController();
  status("Unlocking the complete track…");
  let preparedForPlayback = false;
  try {
    if (!session) await admit();
    if (closed || generation !== loadGeneration) return;
    releaseTrack(); // release previous plaintext before any next-track transfer/decryption
    const encrypted = await request(`/tracks/${track.id}`, { signal: cancelLoad.signal }, true, track.audioBytes, true);
    // Conservative local accounting: canceled/transit failures remain spent server-side.
    session.remainingBytes -= track.audioBytes;
    const plain = await openTrack(encrypted, root, track);
    if (closed || generation !== loadGeneration) { plain.fill(0); return; }
    try { currentURL = URL.createObjectURL(new Blob([plain], { type: audioType(plain) })); } finally { plain.fill(0); }
    preparedForPlayback = true; loadedIndex = index; audio.src = currentURL;
    $("seek").value = "0"; $("seek").style.setProperty("--progress", "0%");
    await audio.play(); status("");
  } catch (error) {
    if (closed) return;
    if (error.code === "session" || error.code === "transfer_budget") {
      confirmation(index);
    } else if (["expired", "play_cap", "unsupported", "share_disabled"].includes(error.code)) {
      unavailable(error.code, error.code === "play_cap" ? "No new listening sessions remain. Ask the sender for a fresh link." : "This mixtape is unavailable or has ended.");
    } else if (error instanceof ShareCryptoError || error instanceof SyntaxError) {
      event("decrypt_failed", { reason: error.reason === "auth" ? "auth" : "format" });
      unavailable("failed", "This track could not be authenticated. Ask the sender for a fresh link.");
    } else if (uncharged(error)) {
      // Refused before anything was charged: the session (if any) stands and Play tries again.
      status("Baton is busy right now. Tap Play to try again.");
    } else if (currentURL && preparedForPlayback) { status("Audio could not start. Tap Play to retry the retained track."); }
    else {
      // A failed HTTP transfer may have charged bytes. Never transparently retry it.
      confirmation(index, error.code === "timeout"
        ? "The listening request did not finish within one minute. A retry needs a new listening session and another play."
        : "The track did not arrive. A retry needs a new listening session and another play.");
    }
  } finally { busy = false; cancelLoad = null; controls(); }
}
$("play").addEventListener("click", () => playTrack(selected));
$("previous").addEventListener("click", () => playTrack(selected - 1));
$("next").addEventListener("click", () => playTrack(selected + 1));
$("confirm").addEventListener("click", () => {
  const index = pendingIndex; pendingIndex = null; $("admission").hidden = true;
  if (index !== null) playTrack(index, true);
});
$("cancel").addEventListener("click", () => {
  pendingIndex = null; $("admission").hidden = true; status(""); controls(); $("play").focus();
});
$("seek").addEventListener("input", () => {
  if (currentURL && Number.isFinite(audio.duration)) {
    audio.currentTime = audio.duration * Number($("seek").value) / 1000; lastTick = null;
    $("seek").style.setProperty("--progress", `${Number($("seek").value) / 10}%`); times(audio.currentTime, audio.duration);
  }
});
function clock() {
  const now = performance.now();
  if (!audio.paused && !audio.seeking && audio.readyState >= 3) {
    if (lastTick !== null) listened += Math.max(0, Math.min((now - lastTick) / 1000, 1));
    lastTick = now;
    if (!thirty && listened >= 30) { thirty = true; event("play_30s"); }
  } else lastTick = null;
  if (!manifest || loadedIndex < 0) return;
  const duration = Number.isFinite(audio.duration) ? audio.duration : manifest.tracks[loadedIndex].metadata.durationSeconds;
  times(audio.currentTime, duration);
  if (duration && !audio.seeking) {
    $("seek").value = String(Math.round(audio.currentTime / duration * 1000));
    $("seek").style.setProperty("--progress", `${Math.min(100, audio.currentTime / duration * 100)}%`);
  }
}
audio.addEventListener("timeupdate", clock);
audio.addEventListener("playing", () => { if (!started) { started = true; event("play_started"); } lastTick = performance.now(); controls(); });
audio.addEventListener("pause", () => { clock(); lastTick = null; if (manifest) controls(); });
audio.addEventListener("seeking", () => { lastTick = null; });
audio.addEventListener("waiting", () => { lastTick = null; });
audio.addEventListener("error", () => { status("Audio could not play. Tap Play to retry the retained track."); if (manifest) controls(); });
audio.addEventListener("ended", () => {
  lastTick = null; endedTracks.add(loadedIndex);
  if (!completed && endedTracks.size === manifest.tracks.length) { completed = true; event("play_completed"); }
  if (selected + 1 < manifest.tracks.length) playTrack(selected + 1); else { status("You reached the end of the mixtape."); controls(); }
});
async function initialize() {
  if (!api || !["ready", "pending"].includes(data.state)) return;
  root = canonical(location.hash.slice(1), 16);
  if (!root) { unavailable("incomplete", "This link is incomplete. Copy all of it, including the part after #."); return; }
  // Hide the key from subsequent address-bar/history copies; no storage or network receives it.
  history.replaceState(null, "", location.pathname);
  try {
    const details = await json("");
    if (details.status === "pending") { status("The sender is still uploading. Reopen the complete link when it is ready."); return; }
    containerDeadline = Date.parse(details.expiresAt);
    if (!Number.isFinite(containerDeadline) || containerDeadline <= Date.now() || details.status !== "ready") throw new ShareCryptoError("format", "Invalid lifecycle");
    manifest = await authenticateManifest(details, root);
    if (closed) { manifest = null; return; }
    $("title").textContent = manifest.title; $("byline").textContent = `${plural(manifest.tracks.length, "track", "tracks")} · ${length(manifest.durationSeconds)}`;
    document.title = manifest.title;
    $("ends").textContent = endsLabel(containerDeadline); $("ends").hidden = false;
    remainingPlays = Number.isSafeInteger(details.remainingPlays) && details.remainingPlays >= 0 ? details.remainingPlays : null;
    chips(); $("chips").hidden = false;
    const element = (tag, className, text) => { const node = document.createElement(tag); node.className = className; if (text !== undefined) node.textContent = text; return node; };
    for (const [index, track] of manifest.tracks.entries()) {
      const li = document.createElement("li"), button = element("button", "row"), words = element("span", "row-text");
      const speaker = document.createElementNS("http://www.w3.org/2000/svg", "svg"), path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      speaker.setAttribute("viewBox", "0 0 24 24"); speaker.setAttribute("class", "row-speaker"); speaker.setAttribute("aria-hidden", "true");
      path.setAttribute("d", "M4 9.5h3.5L12 5.5v13l-4.5-4H4zM15 8.6a4.5 4.5 0 0 1 0 6.8l-1-1.1a3 3 0 0 0 0-4.6zm2.4-2.5a8 8 0 0 1 0 11.8l-1.1-1.1a6.4 6.4 0 0 0 0-9.6z");
      speaker.append(path);
      words.append(element("span", "row-title", track.metadata.title));
      if (track.metadata.artist) words.append(element("span", "row-by", track.metadata.artist));
      button.type = "button";
      button.setAttribute("aria-label", `Track ${index + 1}: ${track.metadata.title}${track.metadata.artist ? ` by ${track.metadata.artist}` : ""}, ${fmt(track.metadata.durationSeconds)}`);
      button.append(element("span", "row-num", String(index + 1)), speaker, words, element("span", "row-time", fmt(track.metadata.durationSeconds)));
      button.addEventListener("click", () => playTrack(index)); li.append(button); $("tracks").append(li);
    }
    for (const reaction of data.reactions) {
      const button = document.createElement("button"); button.type = "button"; button.textContent = reaction; button.setAttribute("aria-label", `React ${reaction}`);
      button.addEventListener("click", async () => {
        button.disabled = true; $("reaction-status").textContent = "";
        try { await request("/reactions", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ emoji: reaction }) }, true); $("reaction-status").textContent = "Reaction sent."; }
        catch { $("reaction-status").textContent = "Reaction could not be sent. The session may have ended."; }
        finally { button.disabled = false; controls(); }
      }); $("reaction-status").before(button);
    }
    showTrack(0); $("player").hidden = false; status(""); controls();
  } catch (error) {
    if (closed) return;
    unavailable("failed", error.code === "timeout"
      ? "The mixtape did not arrive within one minute. Reopen the complete link to retry."
      : error.code ? "This mixtape is unavailable or has ended." : "This mixtape could not be authenticated. Ask the sender for a fresh link.");
  }
}
function dispose() {
  closed = true; ++loadGeneration; cancelLoad?.abort();
  for (const controller of ownedRequests) controller.abort();
  ownedRequests.clear(); releaseTrack();
  root?.fill(0); root = null; session = null; manifest = null;
}
window.addEventListener("pagehide", dispose);
// Pasting another invitation can be a same-document navigation. Discard its predecessor
// before reloading; the new fragment must authenticate before any admission or transfer.
window.addEventListener("hashchange", () => { dispose(); location.reload(); });
// On a phone the player card docks under the list (mixtape.css). Keep the DOM in that order too,
// so Tab meets the card where the eye does (WCAG 2.4.3): the list and reactions move, never the
// card, so the <audio> inside it is not detached. Focus inside a moved node stays put.
const phone = matchMedia("(max-width: 640px)");
function placeCard() {
  const card = $("card"), moving = [$("tracks"), $("reactions")], focused = document.activeElement;
  if ((card === $("player").lastElementChild) === phone.matches) return;
  for (const node of moving) phone.matches ? card.before(node) : $("player").append(node);
  if (focused && moving.some(node => node.contains(focused)) && document.activeElement !== focused) focused.focus({ preventScroll: true });
}
phone.addEventListener("change", placeCard); placeCard();
initialize();
