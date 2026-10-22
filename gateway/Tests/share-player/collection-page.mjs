// The album and playlist page (/b/ with a collection kind) through the same service and nginx as
// e2e.mjs (specs/collection-sharing.md, "The page"). Three short AAC songs are made
// the way the apps seal music (ffmpeg, 128 kbps stereo, in an .m4a) and a tiny JPEG cover, then sealed
// under the book keys as an album (with the cover and track numbers) and as a playlist (each song's
// artist and album, no cover), created, uploaded and finalized through the real service routes. A
// real browser then authenticates them, shows the cover before anyone is admitted, starts one
// listener, plays on from song to song, walks previous, next, choose and seek, shuffle and both
// repeats, resumes after a reload without a second listener, runs out of its transfer allowance and
// starts again, and reads as expired when revoked or past its deadline. Local fixtures only; the key
// goes in the fragment and nowhere else, and is never printed.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { seal } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";
import { chapterKey, manifestKey } from "../../Sources/BatonShareServer/Web/share-book-crypto.mjs";

const b64u = (bytes) => Buffer.from(bytes).toString("base64url");
const sha256 = async (bytes) => Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
const json = { "Content-Type": "application/json" };
const newID = () => b64u(crypto.getRandomValues(new Uint8Array(16)));

// WCAG contrast ratio of two computed "rgb(r, g, b)" colors.
function contrast(...colors) {
  const [a, b] = colors.map((color) => {
    const [r, g, bl] = color.match(/\d+(\.\d+)?/g).slice(0, 3).map((v) => { const c = Number(v) / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  });
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

/** A song as the apps seal music: AAC, 128 kbps, stereo, in an .m4a. */
function songAudio(work, name, low, high, seconds) {
  const path = join(work, `${name}.m4a`);
  execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", `sine=frequency=${low}:duration=${seconds}`,
    "-f", "lavfi", "-i", `sine=frequency=${high}:duration=${seconds}`, "-filter_complex", "amix=inputs=2,volume=0.6[m];[m]aformat=channel_layouts=stereo",
    "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-movflags", "+faststart", path]);
  const bytes = new Uint8Array(readFileSync(path));
  assert.equal(Buffer.from(bytes.subarray(4, 8)).toString("latin1"), "ftyp", "ffmpeg wrote an MP4 song");
  return bytes;
}
function coverImage(work) {
  const path = join(work, "collection-cover.jpg");
  execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", "gradients=s=160x160:c0=0x6f1d3b:c1=0x45c3e9:x0=0:y0=0:x1=160:y1=160:d=1",
    "-frames:v", "1", "-q:v", "5", path]);
  const bytes = new Uint8Array(readFileSync(path));
  assert.deepEqual([...bytes.subarray(0, 3)], [0xff, 0xd8, 0xff], "ffmpeg wrote a JPEG cover");
  assert.ok(bytes.length <= 131072, "the cover fits the 128 KiB cap");
  return bytes;
}

// Records every Blob URL the page makes and revokes, so the label and the release are observed.
const watchBlobs = () => {
  window.__blobs = { made: [], revoked: [] };
  const create = URL.createObjectURL, revoke = URL.revokeObjectURL;
  URL.createObjectURL = function (object) {
    const url = create.call(this, object);
    if (object instanceof Blob) window.__blobs.made.push({ url, type: object.type });
    return url;
  };
  URL.revokeObjectURL = function (url) { window.__blobs.revoked.push(url); return revoke.call(this, url); };
};

const SECONDS = 5;
const ALBUM = { title: "Sine Sessions", artist: "The Test Signals", from: "Anatoli", note: "Track two is the one.",
  tracks: [{ title: "Opening Tone", trackNumber: 1 }, { title: "Second Wave", trackNumber: 2, artist: "The Test Signals and Guest" },
    { title: "Long Way Home", trackNumber: 4 }] };
const PLAYLIST = { title: "Road Trip Mix", artist: "", from: "Maya", note: "For the drive on Saturday.",
  tracks: [{ title: "Morning Drive", artist: "First Band", album: "Early Hours" }, { title: "Open Highway", artist: "Second Band", album: "Miles" },
    { title: "Last Exit", artist: "Third Band", album: "Night Roads" }] };
const FREQUENCIES = [[330, 495], [392, 588], [262, 393]];

// Returns null when it ran, or the reason it was skipped.
export async function verifyCollectionPage({ browser, base, api, evidence, dataDir, external, work, step, screenshot, monitor, problems, activate = () => {} }) {
  const config = await fetch(`${base}/v1/share/config`).then((r) => r.json());
  if (config.books !== 1) return "collection page: the service has books off";
  if (config.collections !== 1) return "collection page: the service has collections off";
  const results = { checks: [] };
  activate(null);
  const passed = (name) => { results.checks.push(name); step(`collection page: ${name}`); };

  step("collection page: making three 128 kbps AAC songs and a JPEG cover");
  const audio = FREQUENCIES.map(([low, high], i) => songAudio(work, `collection-${i}`, low, high, SECONDS));
  const coverBytes = coverImage(work);

  // Seals one collection under fresh book keys, as the apps do; the key never leaves this function's result.
  async function sealCollection(kind, spec, withCover) {
    const root = crypto.getRandomValues(new Uint8Array(16));
    const tracks = [], blobs = {}, sealedBlobs = {};
    for (const [i, plain] of audio.entries()) {
      const id = newID(), encrypted = await seal(plain, await chapterKey(root, id), "audio");
      const entry = { id, ...spec.tracks[i], durationSeconds: SECONDS, audioBytes: encrypted.length, audioSHA256: await sha256(encrypted) };
      blobs[id] = { role: "audio", bytes: encrypted.length, sha256: entry.audioSHA256 }; sealedBlobs[id] = encrypted;
      tracks.push(entry);
    }
    const manifest = { schema: "baton-collection-1", kind, title: spec.title, artist: spec.artist, from: spec.from, note: spec.note,
      ...(withCover ? { cover: { type: "image/jpeg", data: Buffer.from(coverBytes).toString("base64") } } : {}), tracks };
    const encryptedManifest = Buffer.from(await seal(new TextEncoder().encode(JSON.stringify(manifest)), await manifestKey(root), "meta")).toString("base64");
    return { kind, spec, key: b64u(root), tracks, blobs, sealedBlobs, encryptedManifest };
  }
  const albumSealed = await sealCollection("album", ALBUM, true);
  const playlistSealed = await sealCollection("playlist", PLAYLIST, false);

  const minted = [];
  async function mint(sealed, { listenerCap = 3, preview = null, finalize = true } = {}) {
    const created = await api("POST", "/v1/share/books", JSON.stringify({ schema: "baton-collection-1", kind: sealed.kind, requestID: crypto.randomUUID(),
      encryptedManifest: sealed.encryptedManifest, blobs: sealed.blobs, totalDurationSeconds: SECONDS * 3, expiresInSeconds: 86400, listenerCap,
      ...(preview ? { preview } : {}), client: { platform: "macos", appVersion: "e2e" } }), json);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    const id = created.json.id;
    minted.push(id);
    for (const [blobID, encrypted] of Object.entries(sealed.sealedBlobs)) {
      assert.equal((await api("PUT", created.json.uploads[blobID], encrypted)).status, 200, `upload ${blobID}`);
    }
    if (finalize) assert.equal((await api("POST", `/v1/share/books/${id}/finalize`)).status, 200);
    return { id, link: `${base}/b/${id}#${sealed.key}` };
  }
  const summary = async (id) => (await api("GET", `/v1/share/books/${id}`)).json.share;
  // The page's beacons are fire-and-forget, so on a loaded machine they can land after the step that
  // caused them: read the owner's view until it holds what the step should have produced (at most 10 s).
  const eventually = async (id, wanted) => {
    let share;
    for (const end = Date.now() + 10000; ;) {
      share = await summary(id);
      if (wanted(share) || Date.now() > end) return share;
      await new Promise((r) => setTimeout(r, 250));
    }
  };
  const text = (page, selector) => page.locator(selector).textContent();
  const current = (page) => page.evaluate(() => [...document.querySelectorAll("#tracks .row")].findIndex((row) => row.getAttribute("aria-current") === "true"));
  const playingPast = (page, seconds) => page.waitForFunction((s) => {
    const a = document.getElementById("audio"); return !a.paused && a.error === null && a.currentTime > s && document.getElementById("play").dataset.mode === "pause";
  }, seconds, { timeout: 20000 });
  const nowPlaying = (page, title) => page.waitForFunction((t) => document.getElementById("current").textContent === t &&
    document.querySelector('#tracks .row[aria-current="true"] .row-title')?.textContent === t, title, { timeout: 20000 });
  const stored = (page, id) => page.evaluate((k) => { const v = localStorage.getItem(k); return v === null ? null : JSON.parse(v); }, `baton-collection:${id}`);
  const allStorage = (page) => page.evaluate(() => JSON.stringify([Object.entries(localStorage), Object.entries(sessionStorage), document.cookie]));
  const audioBlobs = (page) => page.evaluate(() => window.__blobs.made.filter((b) => b.type.startsWith("audio/")));
  const secrets = (sealed) => [sealed.key, sealed.spec.title, sealed.spec.from, sealed.spec.note, ...(sealed.spec.artist ? [sealed.spec.artist] : []),
    ...sealed.spec.tracks.flatMap((t) => [t.title, t.artist, t.album].filter(Boolean))];
  // The blob requests a page makes, by path (no fragment ever reaches a request).
  const blobRequests = (page) => { const seen = []; page.on("request", (r) => { if (/\/v1\/share\/b\/[^/]+\/blobs\//.test(r.url())) seen.push(r.url()); }); return seen; };
  // Any console line the steps expect (a refused request's status) is taken out of `problems` and checked.
  const expectLogged = (from, pattern) => {
    const logged = problems.splice(from);
    assert.ok(logged.every((line) => pattern.test(line)), JSON.stringify(logged));
  };

  const contextFor = async (options) => {
    const context = await browser.newContext(options);
    context.on("page", monitor);
    context.on("page", activate);
    await context.addInitScript(watchBlobs);
    return context;
  };
  const contexts = [];
  try {
    // ---------- Shell, headers, assets and Open Graph ----------
    const album = await mint(albumSealed, { listenerCap: 10 });
    const playlist = await mint(playlistSealed, { listenerCap: 8,
      preview: { title: PLAYLIST.title, author: PLAYLIST.artist, from: PLAYLIST.from, note: PLAYLIST.note } });
    const shell = await fetch(`${base}/b/${album.id}`);
    assert.equal(shell.status, 200);
    assert.equal(shell.headers.get("referrer-policy"), "no-referrer", "one Referrer-Policy for a collection");
    assert.equal(shell.headers.get("cache-control"), "no-store");
    assert.equal(shell.headers.get("x-content-type-options"), "nosniff");
    const csp = shell.headers.get("content-security-policy") ?? "";
    assert.match(csp, /default-src 'none'.*script-src 'self'; style-src 'self'.*connect-src 'self'/);
    assert.match(csp, /img-src [^;]*blob:/, "the cover is a Blob URL"); assert.match(csp, /media-src [^;]*blob:/, "the audio is a Blob URL");
    const html = await shell.text();
    assert.ok(html.includes("/b/_/collection.mjs?v=") && html.includes("/b/_/collection.css?v="), "the collection page, not the book page");
    assert.ok(html.includes('id="collection-data"') && /"kind":"album"/.test(html), "the data block names the kind");
    for (const asset of ["collection.css", "collection.mjs", "share-book-crypto.mjs", "share-crypto.mjs", "share-mixtape-crypto.mjs", "mixtape-manifest.mjs", "icon.svg"]) {
      const response = await fetch(`${base}/b/_/${asset}?v=retired`);
      assert.equal(response.status, 200, asset); assert.equal(response.headers.get("cache-control"), "public, no-cache", asset);
      if (asset === "collection.mjs") assert.match(await response.text(), /"\.\/share-book-crypto\.mjs\?v=[0-9a-f]+"/, "imports carry the asset version");
    }
    const bot = await fetch(`${base}/b/${album.id}`, { headers: { "User-Agent": "facebookexternalhit/1.1" } }).then((r) => r.text());
    assert.match(bot, /property="og:title" content="Someone sent you an album"/);
    for (const secret of [...secrets(albumSealed), "encryptedManifest"]) assert.ok(!bot.includes(secret) && !html.includes(secret), "the private album shell names nothing");
    const publicBot = await fetch(`${base}/b/${playlist.id}`, { headers: { "User-Agent": "facebookexternalhit/1.1" } }).then((r) => r.text());
    assert.match(publicBot, new RegExp(`property="og:title" content="${PLAYLIST.from} sent you ${PLAYLIST.title}"`));
    assert.ok(/"kind":"playlist"/.test(publicBot));
    for (const track of PLAYLIST.tracks) assert.ok(!publicBot.includes(track.title) && !publicBot.includes(track.artist), "even a public preview names no song");
    passed("collection shell: one no-referrer, strict CSP with blob: images and media, versioned assets, private OG \"Someone sent you an album\", public OG names no song");

    // ---------- The album: details and cover before admission ----------
    const phone = await contextFor({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: "dark" });
    contexts.push(phone);
    const page = await phone.newPage();
    const albumRequests = blobRequests(page);
    await page.goto(album.link);
    await page.locator("#player").waitFor({ state: "visible" });
    assert.equal(await text(page, "#kind"), "Album");
    assert.equal(await text(page, "#title"), ALBUM.title);
    assert.equal(await text(page, "#byline"), ALBUM.artist);
    assert.equal(await text(page, "#from"), `From ${ALBUM.from}`);
    assert.equal(await text(page, "#note"), ALBUM.note);
    assert.equal(await text(page, "#length"), "3 songs · 15 sec");
    assert.match(await text(page, "#ends"), /^Ends /);
    assert.equal(await text(page, "#listeners"), "10 listeners left");
    assert.deepEqual(await page.locator("#tracks .row-num").allTextContents(), ["1", "2", "4"], "an album numbers by trackNumber");
    assert.deepEqual(await page.locator("#tracks .row-title").allTextContents(), ALBUM.tracks.map((t) => t.title));
    assert.deepEqual(await page.locator("#tracks .row-by").allTextContents(), [ALBUM.tracks[1].artist], "only the song by someone else names its artist");
    assert.deepEqual(await page.locator("#tracks .row-time").allTextContents(), ["0:05", "0:05", "0:05"]);
    assert.equal(await page.isVisible("#shuffle"), false, "an album has no shuffle"); assert.equal(await page.isVisible("#repeat"), false, "an album has no repeat");
    await page.waitForFunction(() => { const art = document.getElementById("art"); return !art.hidden && art.complete && art.naturalWidth > 0; });
    const art = await page.evaluate(() => { const a = document.getElementById("art"), box = a.getBoundingClientRect();
      return { src: a.src.slice(0, 5), width: a.naturalWidth, shown: box.width > 100 && box.height > 100, hasArt: document.getElementById("cover").classList.contains("has-art") }; });
    assert.deepEqual(art, { src: "blob:", width: 160, shown: true, hasArt: true }, "the decrypted cover shows before anyone is admitted");
    assert.equal(await current(page), -1);
    assert.equal(await text(page, "#current"), ALBUM.tracks[0].title);
    assert.equal(await text(page, "#current-of"), `${ALBUM.artist} · 1 of 3`);
    assert.equal(new URL(page.url()).hash, `#${albumSealed.key}`, "the key stays in the fragment so a reload can resume");
    assert.equal(await page.isVisible("#admission"), true, "Start listening is offered, not taken");
    assert.equal(await text(page, "#admission-text"), "Start listening? It uses 1 of the 10 listeners on this link.");
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, "no horizontal scroll at 390 px");
    assert.equal(await page.evaluate(() => [...document.getElementById("player").children].map((n) => n.id).join(",")), "tracks,reactions,card",
      "on a phone the docked card follows the list in the DOM");
    assert.equal(await stored(page, album.id), null, "nothing stored before a listener is spent");
    await page.waitForTimeout(300);
    assert.equal((await summary(album.id)).stats.fetches, 0, "opening the page spends no listener");
    await page.click("#play");
    assert.equal(await page.evaluate(() => document.activeElement.id), "confirm", "Play asks first");
    await page.getByRole("button", { name: "Not now", exact: true }).click();
    assert.equal(await page.isVisible("#admission"), false);
    assert.equal((await summary(album.id)).stats.fetches, 0, "Not now spends nothing");
    assert.deepEqual(albumRequests, [], "no song is requested before admission");
    await screenshot(page, join(evidence, "collection-390-dark-album-details.png"));
    // No download: no link to any audio, no native controls, nodownload on the element.
    const offers = await page.evaluate(() => ({ anchors: [...document.querySelectorAll("a")].map((a) => a.href),
      download: document.querySelectorAll("[download], a[href^='blob:'], audio[controls], video").length,
      controlsList: document.getElementById("audio").getAttribute("controlslist") }));
    assert.deepEqual(offers.anchors, ["https://batonmusic.app/"], "the only link is Baton's site");
    assert.equal(offers.download, 0, "nothing offers a download");
    assert.match(offers.controlsList, /\bnodownload\b/);
    passed("album details authenticate: kind, title, artist, From, note, songs by trackNumber, length, listeners; cover shown before admission; Not now spends nothing; no download offered");

    // ---------- Start listening, play-through ----------
    await page.focus("#play"); await page.keyboard.press("Enter");
    await page.locator("#admission").waitFor({ state: "visible" });
    await page.keyboard.press("Enter"); // focus is on Start listening
    await playingPast(page, 1);
    assert.equal(await current(page), 0);
    assert.equal(await text(page, "#listeners"), "9 listeners left");
    assert.equal((await summary(album.id)).stats.fetches, 1, "Start listening spends exactly one listener");
    assert.ok(parseFloat(await page.evaluate(() => document.getElementById("seek").style.getPropertyValue("--progress"))) > 0, "progress moves");
    const media = await page.evaluate(() => {
      if (!("mediaSession" in navigator) || !navigator.mediaSession.metadata) return null;
      const m = navigator.mediaSession.metadata; return { title: m.title, artist: m.artist, album: m.album, artwork: [...m.artwork].map((a) => a.src.slice(0, 5)) };
    });
    results.mediaSession = media ?? "not available in this engine";
    if (media) assert.deepEqual(media, { title: ALBUM.tracks[0].title, artist: ALBUM.artist, album: ALBUM.title, artwork: ["blob:"] }, "Media Session names the song with the cover");
    passed(`Start listening (keyboard) spends exactly one listener; song 1 plays on a moving media clock; Media Session ${media ? "has title, artist, album and cover" : "not available"}`);

    await nowPlaying(page, ALBUM.tracks[1].title);
    await playingPast(page, 0.8);
    // Paused while the walk looks, so a slow machine cannot let a 5-second song run on and change the transfers.
    await page.click("#play"); await page.waitForFunction(() => document.getElementById("audio").paused);
    assert.equal(await page.isVisible("#admission"), false, "no second admission");
    assert.equal((await summary(album.id)).stats.fetches, 1, "song 2 plays in the same listener");
    const made = await audioBlobs(page);
    assert.deepEqual(made.map((b) => b.type), ["audio/mp4", "audio/mp4"], "one decrypted song at a time, labelled audio/mp4 by its bytes");
    assert.ok((await page.evaluate(() => window.__blobs.revoked)).includes(made[0].url), "song 1's Blob URL is revoked");
    assert.equal(await text(page, "#current-of"), `${ALBUM.tracks[1].artist} · 2 of 3`);
    passed("play runs on from song 1 into song 2 with no second admission; the previous Blob URL is revoked");

    // ---------- What the browser keeps ----------
    const entry = await stored(page, album.id);
    assert.deepEqual(Object.keys(entry).sort(), ["expiresAt", "repeat", "seconds", "shuffle", "token", "track"], "only token, expiry, track, seconds, shuffle, repeat");
    assert.equal(entry.track, albumSealed.tracks[1].id);
    assert.equal(entry.shuffle, false); assert.equal(entry.repeat, "off");
    assert.match(entry.token, /^[A-Za-z0-9_-]{43}$/);
    assert.ok(Number.isSafeInteger(entry.expiresAt) && entry.expiresAt > Date.now());
    const everything = await allStorage(page);
    for (const secret of secrets(albumSealed)) assert.ok(!everything.includes(secret), "storage holds no key, title or name");
    results.storageKeys = Object.keys(entry).sort();
    passed("localStorage holds only {token, expiresAt, track, seconds, shuffle, repeat}; no key, no title");

    // ---------- Seek, previous restarts, reload resume ----------
    await page.focus("#seek"); await page.keyboard.press("Home");
    await page.waitForFunction(() => document.getElementById("audio").currentTime < 0.75);
    await page.click("#play");
    await playingPast(page, 3.3);
    const blobsBeforeRestart = (await audioBlobs(page)).length;
    await page.click("#previous");
    await page.waitForFunction(() => document.getElementById("audio").currentTime < 1.5);
    assert.equal(await text(page, "#current"), ALBUM.tracks[1].title, "past 3 s, Previous restarts the song");
    assert.equal((await audioBlobs(page)).length, blobsBeforeRestart, "a restart needs no transfer");
    await playingPast(page, 1.6);
    await page.click("#play");
    await page.waitForFunction(() => document.getElementById("audio").paused);
    const pausedAt = await page.evaluate(() => document.getElementById("audio").currentTime);
    assert.ok(pausedAt > 1.5 && pausedAt < 3, `paused inside song 2 at ${pausedAt}`);
    await page.reload();
    await page.locator("#player").waitFor({ state: "visible" });
    assert.match(await text(page, "#status"), /^Welcome back\. Play resumes song 2 at 0:0\d\.$/);
    assert.equal(await page.isVisible("#admission"), false, "a reload asks for nothing");
    assert.equal(await text(page, "#current"), ALBUM.tracks[1].title);
    await page.click("#play");
    await page.waitForFunction(() => !document.getElementById("audio").paused && document.getElementById("play").dataset.mode === "pause", null, { timeout: 20000 });
    const resumedAt = await page.evaluate(() => document.getElementById("audio").currentTime);
    assert.ok(resumedAt >= pausedAt - 0.6 && resumedAt < pausedAt + 1.2, `resumed at ${resumedAt}, paused at ${pausedAt}`);
    await page.click("#play"); await page.waitForFunction(() => document.getElementById("audio").paused);
    assert.equal(await current(page), 1);
    await page.waitForTimeout(400);
    const afterReload = await summary(album.id);
    assert.equal(afterReload.stats.fetches, 1, "a reload spends no second listener");
    assert.equal(afterReload.stats.plays, 1, "a reload sends no second play-started");
    results.resume = { pausedAt, resumedAt };
    passed("seek; Previous past 3 s restarts the song from memory; reload resumes song 2 at its position with no second listener and no second play-started");

    // Previous inside the first 3 s goes back a song; then the transfer allowance runs out.
    await page.focus("#seek"); await page.keyboard.press("Home");
    await page.waitForFunction(() => document.getElementById("audio").currentTime < 0.75);
    await page.click("#previous");
    await nowPlaying(page, ALBUM.tracks[0].title);
    await playingPast(page, 0.5);
    // 1.5 times the album's bytes covers four whole-song transfers here (song 1, song 2, song 2 again
    // after the reload, song 1); a fifth cannot fit, so choosing song 4 meets the allowance.
    const sizes = albumSealed.tracks.map((t) => t.audioBytes), allowance = 1.5 * sizes.reduce((a, b) => a + b, 0);
    const spent = sizes[0] + sizes[1] + sizes[1] + sizes[0];
    assert.ok(spent <= allowance && spent + sizes[2] > allowance, `fixture sizes ${sizes} must make the fifth transfer exceed the allowance`);
    const before409 = problems.length;
    await page.locator("#tracks .row").nth(2).focus(); await page.keyboard.press("Enter");
    await page.locator("#admission").waitFor({ state: "visible" });
    assert.equal(await text(page, "#status"), "This listen has used its transfer allowance. Starting again uses another listener.");
    assert.equal(await stored(page, album.id), null, "a spent allowance deletes the entry");
    assert.equal(await text(page, "#current"), ALBUM.tracks[2].title);
    await page.waitForTimeout(200);
    expectLogged(before409, /status of 409/);
    assert.equal((await summary(album.id)).stats.fetches, 1, "the refusal spends no listener");
    assert.equal(await page.evaluate(() => document.activeElement.id), "confirm");
    await page.keyboard.press("Enter");
    await nowPlaying(page, ALBUM.tracks[2].title);
    await playingPast(page, 0.3);
    assert.equal(await text(page, "#listeners"), "8 listeners left");
    assert.equal((await summary(album.id)).stats.fetches, 2, "starting again spends exactly one more listener");
    passed("Previous inside 3 s goes back a song; a spent allowance (409) says so, keeps the listener count, and Start listening again spends one and plays the chosen song");

    // Previous and next in the new session, then the end of the album. Seek to the start first, so
    // Previous goes back a song however slowly a loaded machine reaches this step.
    await page.focus("#seek"); await page.keyboard.press("Home");
    await page.waitForFunction(() => document.getElementById("audio").currentTime < 0.75);
    await page.click("#previous");
    await nowPlaying(page, ALBUM.tracks[1].title);
    await playingPast(page, 0.3);
    await page.click("#next");
    await nowPlaying(page, ALBUM.tracks[2].title);
    await playingPast(page, 0.3);
    assert.equal(await page.isDisabled("#next"), true, "Next stops at the last song");
    await page.getByRole("button", { name: "React ❤️", exact: true }).click();
    await page.getByText("Reaction sent.", { exact: true }).waitFor();
    await page.waitForFunction(() => document.getElementById("status").textContent === "You reached the end of the album.", null, { timeout: 15000 });
    const owner = await eventually(album.id, (share) => share.stats.completed >= 1 && share.reactions.length >= 1);
    assert.equal(owner.stats.fetches, 2); assert.equal(owner.stats.plays, 2, "one play started per listener");
    assert.equal(owner.stats.completed, 1, "finishing the last song completes the album");
    assert.deepEqual(owner.reactions.map((r) => r.emoji), ["❤️"]);
    const sequence = await audioBlobs(page);
    assert.ok(sequence.every((b) => b.type === "audio/mp4"));
    assert.deepEqual(await page.evaluate(() => window.__blobs.made.filter((b) => b.type.startsWith("audio/")).slice(0, -1).filter((b) => !window.__blobs.revoked.includes(b.url)).length), 0,
      "every earlier song's Blob URL is revoked: one song in memory at a time");
    results.albumOwner = owner.stats;
    passed("previous and next; Next stops at the end; completion and a reaction reach the sender");

    // ---------- The playlist: shuffle, repeat one, reload ----------
    const desk = await contextFor({ viewport: { width: 1280, height: 860 }, colorScheme: "light" });
    contexts.push(desk);
    const list = await desk.newPage();
    const listRequests = blobRequests(list);
    await list.goto(playlist.link);
    await list.locator("#player").waitFor({ state: "visible" });
    assert.equal(await text(list, "#kind"), "Playlist");
    assert.equal(await text(list, "#title"), PLAYLIST.title);
    assert.equal(await list.isVisible("#byline"), false, "a playlist without an artist shows none");
    assert.equal(await text(list, "#from"), `From ${PLAYLIST.from}`);
    assert.equal(await text(list, "#listeners"), "8 listeners left");
    assert.deepEqual(await list.locator("#tracks .row-num").allTextContents(), ["1", "2", "3"], "a playlist numbers by position");
    assert.deepEqual(await list.locator("#tracks .row-by").allTextContents(), PLAYLIST.tracks.map((t) => t.artist), "a playlist names every artist");
    const placeholder = await list.evaluate(() => ({ art: document.getElementById("art").hidden, hasArt: document.getElementById("cover").classList.contains("has-art"),
      hue: document.getElementById("cover").style.getPropertyValue("--hue") }));
    assert.equal(placeholder.art, true); assert.equal(placeholder.hasArt, false); assert.match(placeholder.hue, /^\d+$/, "a generated placeholder cover");
    assert.equal(await list.isVisible("#shuffle"), true); assert.equal(await list.isVisible("#repeat"), true);
    assert.equal(await list.evaluate(() => [...document.getElementById("player").children].map((n) => n.id).join(",")), "card,tracks,reactions", "wide: the card leads");
    assert.equal(await list.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, "no horizontal scroll at 1280 px");
    await list.getByRole("button", { name: "Start listening", exact: true }).click();
    await playingPast(list, 0.5);
    assert.equal((await summary(playlist.id)).stats.fetches, 1);
    if (results.mediaSession !== "not available in this engine") {
      const listMedia = await list.evaluate(() => { const m = navigator.mediaSession.metadata; return { title: m.title, artist: m.artist, album: m.album, artwork: m.artwork.length }; });
      assert.deepEqual(listMedia, { title: PLAYLIST.tracks[0].title, artist: PLAYLIST.tracks[0].artist, album: PLAYLIST.tracks[0].album, artwork: 0 });
    }
    await list.click("#shuffle");
    assert.equal(await list.getAttribute("#shuffle", "aria-pressed"), "true");
    assert.match(await text(list, "#current-of"), /^First Band · 1 of 3 · shuffled$/, "shuffle keeps the current song first");
    const visited = [PLAYLIST.tracks[0].title];
    for (let i = 0; i < 2; i++) {
      await list.click("#next");
      await list.waitForFunction((seen) => !seen.includes(document.getElementById("current").textContent) && document.getElementById("play").dataset.mode === "pause", visited, { timeout: 20000 });
      visited.push(await text(list, "#current"));
      await playingPast(list, 0.3);
    }
    await list.click("#play"); await list.waitForFunction(() => document.getElementById("audio").paused);
    assert.deepEqual([...visited].sort(), PLAYLIST.tracks.map((t) => t.title).sort(), "the shuffled order plays every other song once");
    assert.equal(await list.isDisabled("#next"), true, "with repeat off, Next stops at the end of the shuffled order");
    results.shuffled = visited;
    const shuffledEntry = await stored(list, playlist.id);
    assert.equal(shuffledEntry.shuffle, true);
    await list.click("#repeat");
    assert.equal(await list.getAttribute("#repeat", "aria-label"), "Repeat: all songs");
    assert.equal(await list.isDisabled("#next"), false, "repeat all wraps Next");
    await list.click("#repeat");
    assert.equal(await list.getAttribute("#repeat", "data-repeat"), "one");
    assert.equal(await list.getAttribute("#repeat", "aria-label"), "Repeat: this song");
    assert.equal((await stored(list, playlist.id)).repeat, "one");
    passed(`shuffle keeps the current song and plays the rest in a random order (${visited.join(" → ")}); repeat cycles off, all, one`);

    await list.reload();
    await list.locator("#player").waitFor({ state: "visible" });
    assert.match(await text(list, "#status"), /^Welcome back\. Play resumes song [123] at 0:0\d\.$/);
    assert.equal(await list.getAttribute("#shuffle", "aria-pressed"), "true", "shuffle survives a reload");
    assert.equal(await list.getAttribute("#repeat", "data-repeat"), "one", "repeat survives a reload");
    assert.equal(await text(list, "#current"), visited[2]);
    await list.click("#play");
    await list.waitForFunction(() => !document.getElementById("audio").paused, null, { timeout: 20000 });
    // Repeat one: the song ends and plays again from the decrypted copy already in memory.
    await list.evaluate(() => {
      const a = document.getElementById("audio"); window.__wrap = { high: false, wrapped: false };
      a.addEventListener("timeupdate", () => { if (a.currentTime > 4) window.__wrap.high = true; else if (window.__wrap.high && a.currentTime < 1.5) window.__wrap.wrapped = true; });
    });
    const requestsBeforeRepeat = listRequests.length, blobsBeforeRepeat = (await audioBlobs(list)).length;
    await list.waitForFunction(() => window.__wrap.wrapped && !document.getElementById("audio").paused, null, { timeout: 15000 });
    assert.equal(await text(list, "#current"), visited[2], "repeat one stays on the song");
    assert.equal(listRequests.length, requestsBeforeRepeat, "repeat one makes no request");
    assert.equal((await audioBlobs(list)).length, blobsBeforeRepeat, "repeat one replays the same Blob");
    await list.waitForTimeout(300);
    const listOwner = await summary(playlist.id);
    assert.equal(listOwner.stats.fetches, 1, "the reload spent no second listener"); assert.equal(listOwner.stats.plays, 1, "and sent no second play-started");
    passed("shuffle and repeat survive a reload with no second listener; repeat one replays the song from memory with no request");
    await list.click("#play");
    await list.close();

    // ---------- The playlist: repeat all wraps ----------
    const wrapPage = await phone.newPage();
    await wrapPage.goto(playlist.link);
    await wrapPage.locator("#player").waitFor({ state: "visible" });
    await wrapPage.locator("#tracks .row").nth(2).click();
    await wrapPage.locator("#admission").waitFor({ state: "visible" });
    assert.equal((await summary(playlist.id)).stats.fetches, 1, "choosing a song before admission only asks");
    assert.equal(await wrapPage.isDisabled("#next"), true, "the last song, repeat off");
    await wrapPage.click("#repeat");
    assert.equal(await wrapPage.getAttribute("#repeat", "data-repeat"), "all");
    assert.equal(await wrapPage.isDisabled("#next"), false, "repeat all wraps Next");
    await wrapPage.getByRole("button", { name: "Start listening", exact: true }).click();
    await nowPlaying(wrapPage, PLAYLIST.tracks[2].title);
    await playingPast(wrapPage, 0.3);
    await nowPlaying(wrapPage, PLAYLIST.tracks[0].title);
    await playingPast(wrapPage, 0.3);
    assert.equal(await current(wrapPage), 0);
    assert.equal((await summary(playlist.id)).stats.fetches, 2);
    await wrapPage.click("#play");
    await wrapPage.close();
    passed("choose a song first, then repeat all runs from the last song on into the first");

    // ---------- A link extended while its page is open ----------
    const extending = await mint(playlistSealed, { listenerCap: 2 });
    const open = await phone.newPage();
    await open.goto(extending.link);
    await open.locator("#player").waitFor({ state: "visible" });
    const endsBefore = await text(open, "#ends");
    const longer = await api("PATCH", `/v1/share/books/${extending.id}`, JSON.stringify({ extendBySeconds: 86400 }), json);
    assert.equal(longer.status, 200, JSON.stringify(longer.json));
    await open.click("#play");
    await open.getByRole("button", { name: "Start listening", exact: true }).click();
    await open.waitForFunction(() => document.body.dataset.state !== "ready"
      || (!document.getElementById("audio").paused && document.getElementById("audio").currentTime > 0.3), null, { timeout: 20000 });
    assert.equal(await open.evaluate(() => document.body.dataset.state), "ready", `the later session deadline is accepted: ${await text(open, "#status")}`);
    assert.notEqual(await text(open, "#ends"), endsBefore, "the page shows the link's new end");
    await open.click("#play");
    await open.close();
    passed("a link extended while its page is open still admits, and the page shows the new end");

    // ---------- Wrong key, missing key, unknown ----------
    const wrong = await phone.newPage();
    await wrong.goto(`${base}/b/${album.id}#${b64u(new Uint8Array(16))}`);
    await wrong.waitForFunction(() => document.body.dataset.state === "failed");
    assert.equal(await text(wrong, "#status"), "This link’s key does not open this album. Check that you copied all of it.");
    assert.equal(await wrong.isVisible("#player"), false);
    assert.equal(await wrong.evaluate(() => document.getElementById("art").hidden && !document.getElementById("art").getAttribute("src")), true, "no cover without the key");
    await screenshot(wrong, join(evidence, "collection-390-dark-wrong-key.png"));
    await wrong.goto(`${base}/b/${album.id}`);
    await wrong.waitForFunction(() => document.body.dataset.state === "incomplete");
    await wrong.goto(`${base}/b/AAAAAAAAAAAAAAAAAAAAAA#${albumSealed.key}`);
    await wrong.waitForFunction(() => document.body.dataset.state === "unknown");
    await wrong.close();
    assert.equal((await summary(album.id)).stats.fetches, 2, "wrong and missing keys spend nothing");
    passed("wrong key, missing key and unknown link states");

    // ---------- Screenshots: 390 and 1280 px, light and dark, both kinds ----------
    // One context for all eight, sized and themed per page: eight fresh contexts open many new
    // connections at once, which Docker Desktop's port forwarding has stalled under heavy load. Each
    // page starts with no stored entry, so each one is admitted afresh.
    // WebKit's screenshots are taken after the walk from the pages still open (e2e.mjs), so there the
    // eight paused pages stay open and the browser's close ends them.
    const webkit = browser.browserType().name() === "webkit";
    const shots = await contextFor({ viewport: { width: 390, height: 844 } });
    if (!webkit) contexts.push(shots);
    await shots.addInitScript(() => {
      try { for (const k of Object.keys(localStorage)) if (k.startsWith("baton-collection:")) localStorage.removeItem(k); } catch {}
    });
    for (const [which, link] of [["album", album.link], ["playlist", playlist.link]]) {
      for (const [width, height, scheme] of [[390, 844, "light"], [390, 844, "dark"], [1280, 860, "light"], [1280, 860, "dark"]]) {
        const shot = await shots.newPage();
        await shot.setViewportSize({ width, height }); await shot.emulateMedia({ colorScheme: scheme });
        await shot.goto(link);
        await shot.locator("#player").waitFor({ state: "visible" });
        assert.equal(await shot.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal scroll at ${width}`);
        assert.equal(await shot.evaluate(() => getComputedStyle(document.getElementById("card")).position), width < 641 ? "sticky" : "static");
        assert.equal(await shot.evaluate(() => getComputedStyle(document.body).backgroundColor), scheme === "light" ? "rgb(250, 247, 244)" : "rgb(48, 52, 58)");
        const confirm = await shot.evaluate(() => { const s = getComputedStyle(document.getElementById("confirm")); return [s.color, s.backgroundColor]; });
        assert.ok(contrast(...confirm) >= 4.5, `Start listening contrast ${contrast(...confirm).toFixed(2)}:1 in ${scheme}`);
        for (const [selector, behind] of [["#kind", "body"], [".row-time", "body"], ["#from", "body"]]) {
          const pair = await shot.evaluate(([s, b]) => [getComputedStyle(document.querySelector(s)).color, getComputedStyle(document.querySelector(b)).backgroundColor], [selector, behind]);
          assert.ok(contrast(...pair) >= 4.5, `${selector} contrast ${contrast(...pair).toFixed(2)}:1 in ${scheme}`);
        }
        await shot.getByRole("button", { name: "Start listening", exact: true }).click();
        await playingPast(shot, 1.2);
        await shot.click("#play");
        await shot.waitForFunction(() => document.getElementById("audio").paused);
        await screenshot(shot, join(evidence, `collection-${which}-${width}-${scheme}.png`));
        if (!webkit) await shot.close();
      }
    }
    passed("album and playlist at 390 and 1280 px, light and dark: no horizontal scroll, contrast, screenshots");

    // ---------- Revoke while open, revoked and expired links ----------
    assert.ok(await stored(page, album.id), "the open album page still holds its entry");
    assert.equal((await api("DELETE", `/v1/share/books/${album.id}`)).status, 204);
    const beforeRevoke = problems.length;
    await page.bringToFront();
    await page.locator("#tracks .row").nth(0).click();
    await page.waitForFunction(() => document.body.dataset.state === "expired", null, { timeout: 15000 });
    await page.waitForTimeout(200);
    expectLogged(beforeRevoke, /status of 410/);
    assert.equal(await text(page, "#title"), "This album’s link has expired");
    assert.equal(await page.isVisible("#player"), false);
    assert.equal(await stored(page, album.id), null, "a 410 deletes the entry");
    await screenshot(page, join(evidence, "collection-390-dark-revoked.png"));
    const revokedShell = await fetch(`${base}/b/${album.id}`);
    assert.equal(revokedShell.status, 410);
    const revokedHTML = await revokedShell.text();
    assert.ok(!/revoked/i.test(revokedHTML), "a revoked page never says revoked"); assert.match(revokedHTML, /"state":"expired"/);
    const revokedDetails = await fetch(`${base}/v1/share/b/${album.id}`);
    assert.equal(revokedDetails.status, 410); assert.ok(!/revoked/i.test(await revokedDetails.text()));
    await page.evaluate(([k, value]) => localStorage.setItem(k, JSON.stringify(value)), [`baton-collection:${album.id}`,
      { token: b64u(crypto.getRandomValues(new Uint8Array(32))), expiresAt: Date.now() + 3600000, track: albumSealed.tracks[0].id, seconds: 1, shuffle: false, repeat: "off" }]);
    const beforeReload = problems.length;
    await page.reload();
    await page.waitForFunction(() => document.body.dataset.state === "expired");
    expectLogged(beforeReload, /status of 410/);
    assert.equal(await stored(page, album.id), null, "the expired page deletes a leftover entry");
    assert.match(await text(page, "#title"), /link has expired$/);
    await page.close();
    passed("revoking reads as expired on the open page and the shell, and clears localStorage");

    if (!external) {
      const expiring = await mint(playlistSealed, { listenerCap: 1 });
      execFileSync("python3", ["-c", "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('UPDATE shares SET expires_at=? WHERE id=?',(int(time.time())-1,sys.argv[2])); c.commit()",
        join(dataDir, "share.sqlite"), expiring.id]);
      const expired = await phone.newPage();
      const beforeExpired = problems.length;
      await expired.goto(expiring.link);
      await expired.waitForFunction(() => document.body.dataset.state === "expired");
      expectLogged(beforeExpired, /status of 410/);
      assert.match(await text(expired, "#title"), /link has expired$/);
      assert.equal(await expired.isVisible("#player"), false);
      await expired.close();
      assert.equal((await fetch(`${base}/v1/share/b/${expiring.id}`)).status, 410);
      passed("an expired link reads as expired");
    } else results.checks.push("SKIP expired link: no database writes against an external service");
    assert.equal((await api("DELETE", `/v1/share/books/${playlist.id}`)).status, 204);
    assert.deepEqual(problems, [], "no console errors or CSP violations on the collection page");
    results.passed = true;
    return null;
  } finally {
    writeFileSync(join(evidence, "collection-page.json"), JSON.stringify({ ...results, problems }, null, 2));
    for (const context of contexts) await context.close().catch(() => {});
    // Leave nothing live behind, even after a failure (a repeat revoke is harmless).
    for (const id of minted) await api("DELETE", `/v1/share/books/${id}`).catch(() => {});
  }
}
