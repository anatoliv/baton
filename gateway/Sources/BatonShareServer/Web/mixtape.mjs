import { base64UrlDecode, ShareCryptoError } from "./share-crypto.mjs";
import { canonicalTrackID, openTrack } from "./share-mixtape-crypto.mjs";
import { authenticateManifest, readBounded } from "./mixtape-manifest.mjs";
const $ = id => document.getElementById(id);
const data = JSON.parse($("mixtape-data").textContent);
const audio = $("audio"), api = data.id ? `/v1/share/m/${data.id}` : null;
let root = null, manifest = null, session = null, currentURL = null, loadedIndex = -1, selected = 0;
let busy = false, pendingIndex = null, closed = false, cancelLoad = null, loadGeneration = 0;
let everAdmitted = false, containerDeadline = 0;
let started = false, thirty = false, completed = false, listened = 0, lastTick = null;
const endedTracks = new Set();
const ownedRequests = new Set();
const resourceDeadlineMilliseconds = 60000;
const canonical = (value, length) => {
  const bytes = base64UrlDecode(value);
  if (!bytes || bytes.length !== length || btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") !== value) return null;
  return bytes;
};
const status = message => { $("status").textContent = message; };
function unavailable(state, message) {
  document.body.dataset.state = state;
  status(message); $("player").hidden = true; releaseTrack(); session = null;
}
function controls() {
  if (!manifest || closed) return;
  $("play").disabled = busy || pendingIndex !== null;
  $("play").textContent = busy ? "Loading…" : currentURL && !audio.paused ? "Pause" : "Play";
  $("previous").disabled = busy || pendingIndex !== null || selected === 0;
  $("next").disabled = busy || pendingIndex !== null || selected === manifest.tracks.length - 1;
  for (const [index, button] of [...$("tracks").querySelectorAll("button")].entries()) {
    button.disabled = busy || pendingIndex !== null;
    button.setAttribute("aria-current", index === selected ? "true" : "false");
  }
  $("seek").disabled = busy || !currentURL;
  $("reactions").disabled = !session;
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
function confirmation(index, message) {
  audio.pause(); session = null; pendingIndex = index;
  $("admission").hidden = false; status(message);
  controls(); $("confirm").focus();
}
async function admit() {
  everAdmitted = true; // a lost admission response may already have spent a play
  const value = await json("/sessions", { method: "POST" }, false, 4096);
  const deadline = Date.parse(value.expiresAt);
  if (!canonical(value.token, 32) || !Number.isFinite(deadline) || deadline <= Date.now() || deadline > Date.now() + 1801000 || deadline > containerDeadline ||
      !Number.isSafeInteger(value.remainingBytes) || value.remainingBytes < 0 || value.remainingBytes > manifest.audioBytes ||
      !Number.isSafeInteger(value.remainingPlays) || value.remainingPlays < 0) throw new ShareCryptoError("format", "Invalid session");
  if (closed) return;
  session = { token: value.token, expiresAt: deadline, remainingBytes: value.remainingBytes };
  started = false; thirty = false; completed = false; listened = 0; lastTick = null; endedTracks.clear();
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
    confirmation(index, "The listening session has ended or its transfer allowance is used."); return;
  }
  // After a previous admission, an invalid session is never replaced on an ordinary Play.
  if (!confirmed && !session && everAdmitted) { confirmation(index, "A new listening session needs your confirmation."); return; }
  busy = true; selected = index; controls();
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
    try { currentURL = URL.createObjectURL(new Blob([plain], { type: "audio/mpeg" })); } finally { plain.fill(0); }
    preparedForPlayback = true; loadedIndex = index; audio.src = currentURL;
    $("current").textContent = `${index + 1}. ${track.metadata.title}${track.metadata.artist ? ` · ${track.metadata.artist}` : ""}`;
    $("seek").value = "0";
    await audio.play(); status("");
  } catch (error) {
    if (closed) return;
    if (error.code === "session" || error.code === "transfer_budget") {
      confirmation(index, "The listening session has ended or its transfer allowance is used.");
    } else if (["expired", "play_cap", "unsupported", "share_disabled"].includes(error.code)) {
      unavailable(error.code, error.code === "play_cap" ? "No new listening sessions remain. Ask the sender for a fresh link." : "This mixtape is unavailable or has ended.");
    } else if (error instanceof ShareCryptoError || error instanceof SyntaxError) {
      event("decrypt_failed", { reason: error.reason === "auth" ? "auth" : "format" });
      unavailable("failed", "This track could not be authenticated. Ask the sender for a fresh link.");
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
  pendingIndex = null; $("admission").hidden = true; status("Canceled. The current track remains available in memory."); controls(); $("play").focus();
});
$("seek").addEventListener("input", () => {
  if (currentURL && Number.isFinite(audio.duration)) { audio.currentTime = audio.duration * Number($("seek").value) / 1000; lastTick = null; }
});
const fmt = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
function clock() {
  const now = performance.now();
  if (!audio.paused && !audio.seeking && audio.readyState >= 3) {
    if (lastTick !== null) listened += Math.max(0, Math.min((now - lastTick) / 1000, 1));
    lastTick = now;
    if (!thirty && listened >= 30) { thirty = true; event("play_30s"); }
  } else lastTick = null;
  const duration = Number.isFinite(audio.duration) ? audio.duration : 0;
  $("clock").textContent = `${fmt(audio.currentTime)} / ${fmt(duration)}`;
  if (duration && !audio.seeking) $("seek").value = String(Math.round(audio.currentTime / duration * 1000));
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
    $("title").textContent = manifest.title; $("byline").textContent = `${manifest.tracks.length} tracks · ${fmt(manifest.durationSeconds)}`;
    document.title = manifest.title;
    for (const [index, track] of manifest.tracks.entries()) {
      const li = document.createElement("li"), button = document.createElement("button");
      button.type = "button"; button.textContent = `${track.metadata.title}${track.metadata.artist ? ` · ${track.metadata.artist}` : ""}`;
      button.addEventListener("click", () => playTrack(index)); li.append(button); $("tracks").append(li);
    }
    for (const reaction of data.reactions) {
      const button = document.createElement("button"); button.type = "button"; button.textContent = reaction; button.setAttribute("aria-label", `React ${reaction}`);
      button.addEventListener("click", async () => {
        button.disabled = true;
        try { await request("/reactions", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ emoji: reaction }) }, true); $("reaction-status").textContent = "Reaction sent."; }
        catch { $("reaction-status").textContent = "Reaction could not be sent. The session may have ended."; }
        finally { button.disabled = false; }
      }); $("reactions").append(button);
    }
    $("player").hidden = false; status("Ready. Play starts one listening session."); controls();
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
initialize();
