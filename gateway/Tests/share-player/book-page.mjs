// The whole-book page (/b/) through the same service and nginx as e2e.mjs (specs/book-sharing.md,
// "The /b/ page"; TBX-1000000132). A synthetic book is made the way the apps make one: three short
// AAC chapters (ffmpeg, 48 kbps mono, as the book renderer writes them) and read-along text on the
// first, sealed under baton-book-1 keys, created, uploaded and finalized through the real service
// routes. Then a real browser authenticates it, starts one listener, plays on from chapter to chapter,
// follows the text, resumes after a reload without a second listener, and reads as expired when
// revoked. Local fixtures only; the key goes in the fragment and nowhere else, and is never printed.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { seal } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";
import { chapterKey, manifestKey, textKey } from "../../Sources/BatonShareServer/Web/share-book-crypto.mjs";

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

/** A chapter as the book renderer writes it: AAC, 48 kbps, mono, in an .m4a. */
function chapterAudio(work, name, frequency, seconds) {
  const path = join(work, `${name}.m4a`);
  execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", `sine=frequency=${frequency}:duration=${seconds}`,
    "-c:a", "aac", "-b:a", "48k", "-ac", "1", "-movflags", "+faststart", path]);
  const bytes = new Uint8Array(readFileSync(path));
  assert.equal(Buffer.from(bytes.subarray(4, 8)).toString("latin1"), "ftyp", "ffmpeg wrote an MP4 chapter");
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
// A browser with storage blocked: every localStorage access throws, as in some private modes.
const blockStorage = () => {
  const refuse = () => { throw new DOMException("blocked", "SecurityError"); };
  for (const name of ["getItem", "setItem", "removeItem", "clear", "key"]) Storage.prototype[name] = refuse;
  try { Object.defineProperty(window, "localStorage", { configurable: true, get: refuse }); } catch {}
};

const TITLE = "A Short Synthetic Book", AUTHOR = "A. Writer", FROM = "Anatoli", NOTE = "Chapter two is the good one.";
const CHAPTERS = ["Chapter 1: Arrival", "Chapter 2: The House", "Chapter 3: Leaving"];
const SECONDS = 6;
const SEGMENTS = [
  { text: "The train came in slowly.", paragraph: 0, start: 0, end: 2.4 },
  { text: "Nobody was waiting on the platform.", paragraph: 0, start: 2.4, end: 4.2 },
  { text: "A new paragraph begins here.", paragraph: 1, start: 4.2, end: 6 },
];

// Returns null when it ran, or the reason it was skipped.
export async function verifyBookPage({ browser, base, direct, api, evidence, dataDir, external, work, step, screenshot, monitor, problems, activate = () => {} }) {
  const config = await fetch(`${base}/v1/share/config`).then((r) => r.json());
  if (config.books !== 1) return "book page: the service has books off";
  const results = { checks: [] };
  activate(null); // until a book page opens, a failure has no page of its own to capture
  const passed = (name) => { results.checks.push(name); step(`book page: ${name}`); };

  step("book page: making three AAC chapters and read-along text");
  const audio = [440, 550, 660].map((frequency, i) => chapterAudio(work, `whole-book-${i}`, frequency, SECONDS));
  const root = crypto.getRandomValues(new Uint8Array(16)), key = b64u(root);
  const chapters = [], blobs = {}, sealedBlobs = {};
  for (const [i, plain] of audio.entries()) {
    const id = newID();
    const encrypted = await seal(plain, await chapterKey(root, id), "audio");
    const chapter = { id, title: CHAPTERS[i], durationSeconds: SECONDS, audioBytes: encrypted.length, audioSHA256: await sha256(encrypted) };
    blobs[id] = { role: "audio", bytes: encrypted.length, sha256: chapter.audioSHA256 }; sealedBlobs[id] = encrypted;
    if (i === 0) {
      const textID = newID();
      const text = await seal(new TextEncoder().encode(JSON.stringify({ schema: "baton-book-text-1", segments: SEGMENTS })), await textKey(root, id), "meta");
      chapter.text = { id: textID, bytes: text.length, sha256: await sha256(text) };
      blobs[textID] = { role: "text", bytes: text.length, sha256: chapter.text.sha256 }; sealedBlobs[textID] = text;
    }
    chapters.push(chapter);
  }
  const manifest = { schema: "baton-book-1", title: TITLE, author: AUTHOR, from: FROM, note: NOTE, chapters };
  const encryptedManifest = Buffer.from(await seal(new TextEncoder().encode(JSON.stringify(manifest)), await manifestKey(root), "meta")).toString("base64");

  async function mint({ listenerCap = 3, preview = null, finalize = true } = {}) {
    const created = await api("POST", "/v1/share/books", JSON.stringify({ schema: "baton-book-1", requestID: crypto.randomUUID(), encryptedManifest, blobs,
      totalDurationSeconds: SECONDS * 3, expiresInSeconds: 86400, listenerCap, ...(preview ? { preview } : {}),
      client: { platform: "macos", appVersion: "e2e" } }), json);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    for (const [id, encrypted] of Object.entries(sealedBlobs)) {
      assert.equal((await api("PUT", created.json.uploads[id], encrypted)).status, 200, `upload ${id}`);
    }
    const id = created.json.id;
    if (finalize) assert.equal((await api("POST", `/v1/share/books/${id}/finalize`)).status, 200);
    return { id, link: `${base}/b/${id}#${key}`, finalize: async () => assert.equal((await api("POST", `/v1/share/books/${id}/finalize`)).status, 200) };
  }
  const summary = async (id) => (await api("GET", `/v1/share/books/${id}`)).json.share;
  const text = (page, selector) => page.locator(selector).textContent();
  const current = (page) => page.evaluate(() => [...document.querySelectorAll("#chapters .row")].findIndex((row) => row.getAttribute("aria-current") === "true"));
  const playingPast = (page, seconds) => page.waitForFunction((s) => {
    const a = document.getElementById("audio"); return !a.paused && a.error === null && a.currentTime > s && document.getElementById("play").dataset.mode === "pause";
  }, seconds, { timeout: 20000 });
  const stored = (page, id) => page.evaluate((k) => { const v = localStorage.getItem(k); return v === null ? null : JSON.parse(v); }, `baton-book:${id}`);
  const allStorage = (page) => page.evaluate(() => JSON.stringify([Object.entries(localStorage), Object.entries(sessionStorage), document.cookie]));

  const contextFor = async (options) => {
    const context = await browser.newContext(options);
    context.on("page", monitor);
    context.on("page", activate); // a failure is captured on the book page in use, not the song page
    await context.addInitScript(watchBlobs);
    return context;
  };
  // Diagnosis for the phone context, the one that reloads: a HAR (timings, no bodies) in every engine and,
  // in Chromium, the DevTools network events per request (sent, connection, response, finished or failed).
  // Request URLs never carry the fragment, so neither holds the key.
  const phone = await contextFor({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: "dark",
    recordHar: { path: join(evidence, "book-phone.har"), content: "omit" } });
  const network = [];
  if (browser.browserType().name() === "chromium") {
    let pages = 0;
    phone.on("page", async (opened) => {
      const tab = ++pages, cdp = await phone.newCDPSession(opened).catch(() => null);
      if (!cdp) return;
      const note = (event, fields) => { if (network.length < 5000) network.push({ tab, event, wall: Date.now(), ...fields }); };
      cdp.on("Network.requestWillBeSent", (e) => note("sent", { id: e.requestId, url: e.request.url.split("#")[0], type: e.type, ts: e.timestamp, initiator: e.initiator?.type, redirect: Boolean(e.redirectResponse) }));
      cdp.on("Network.responseReceived", (e) => note("response", { id: e.requestId, status: e.response.status, ts: e.timestamp, connectionId: e.response.connectionId,
        reused: e.response.connectionReused, fromCache: e.response.fromDiskCache || e.response.fromServiceWorker || e.response.fromPrefetchCache, timing: e.response.timing }));
      cdp.on("Network.loadingFinished", (e) => note("finished", { id: e.requestId, ts: e.timestamp, bytes: e.encodedDataLength }));
      cdp.on("Network.loadingFailed", (e) => note("failed", { id: e.requestId, ts: e.timestamp, error: e.errorText, canceled: e.canceled, blocked: e.blockedReason ?? null }));
      cdp.on("Page.frameStartedLoading", () => note("frameStartedLoading", {}));
      cdp.on("Page.loadEventFired", (e) => note("load", { ts: e.timestamp }));
      cdp.on("Page.domContentEventFired", (e) => note("domContentLoaded", { ts: e.timestamp }));
      await cdp.send("Network.enable").catch(() => {}); await cdp.send("Page.enable").catch(() => {});
    });
  }
  try {
    // ---------- Shell, headers and private Open Graph ----------
    const listening = await mint({ listenerCap: 3 });
    const shell = await fetch(`${base}/b/${listening.id}`);
    assert.equal(shell.status, 200);
    // One Referrer-Policy: deploy/nginx/default.conf maps ^/b/ like ^/m/ and share-proxy.inc hides the
    // service's copy, so a duplicate would read here as "no-referrer, no-referrer".
    assert.equal(shell.headers.get("referrer-policy"), "no-referrer", "one Referrer-Policy for /b/");
    assert.equal(shell.headers.get("cache-control"), "no-store");
    assert.equal(shell.headers.get("x-content-type-options"), "nosniff");
    assert.match(shell.headers.get("content-security-policy") ?? "", /default-src 'none'.*script-src 'self'; style-src 'self'.*connect-src 'self'/);
    const html = await shell.text();
    assert.ok(html.includes('<meta name="referrer" content="no-referrer">'));
    for (const asset of ["book.css", "book.mjs", "share-book-crypto.mjs", "mixtape-manifest.mjs", "icon.svg"]) {
      const response = await fetch(`${base}/b/_/${asset}?v=retired`);
      assert.equal(response.status, 200, asset); assert.equal(response.headers.get("cache-control"), "public, no-cache", asset);
    }
    const bot = await fetch(`${base}/b/${listening.id}`, { headers: { "User-Agent": "facebookexternalhit/1.1" } }).then((r) => r.text());
    assert.match(bot, /property="og:title" content="Someone sent you a book"/);
    for (const secret of [TITLE, AUTHOR, FROM, NOTE, ...CHAPTERS, key, "encryptedManifest"]) assert.ok(!bot.includes(secret) && !html.includes(secret), `private page shell leaks ${secret}`);
    passed("nginx sends one no-referrer for /b/, strict CSP, private Open Graph names nothing");

    // ---------- Details and the explicit admission ----------
    const page = await phone.newPage();
    await page.goto(listening.link);
    await page.locator("#player").waitFor({ state: "visible" });
    assert.equal(await text(page, ".kicker"), "Baton book");
    assert.equal(await text(page, "#title"), TITLE);
    assert.equal(await text(page, "#byline"), `By ${AUTHOR}`);
    assert.equal(await text(page, "#from"), `From ${FROM}`);
    assert.equal(await text(page, "#note"), NOTE);
    assert.equal(await text(page, "#length"), "3 chapters · 18 sec");
    assert.match(await text(page, "#ends"), /^Ends /);
    assert.equal(await text(page, "#listeners"), "3 listeners left");
    assert.deepEqual(await page.locator("#chapters .row-title").allTextContents(), CHAPTERS);
    assert.deepEqual(await page.locator("#chapters .row-time").allTextContents(), ["0:06", "0:06", "0:06"]);
    assert.equal(await page.locator("#chapters .row-by").count(), 1, "only chapter 1 says it has read-along text");
    assert.equal(await current(page), -1);
    assert.equal(await text(page, "#current"), CHAPTERS[0]);
    assert.equal(await text(page, "#current-of"), "Chapter 1 of 3");
    assert.equal(new URL(page.url()).hash, `#${key}`, "the key stays in the fragment so a reload can resume");
    assert.equal(await page.isVisible("#admission"), true, "Start listening is offered, not taken");
    assert.equal(await text(page, "#admission-text"), "Start listening? It uses 1 of the 3 listeners on this link.");
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, "no horizontal scroll at 390 px");
    assert.equal(await page.evaluate(() => [...document.getElementById("player").children].map((n) => n.id).join(",")), "readalong,chapters,reactions,card",
      "on a phone the docked card follows the list in the DOM");
    assert.equal(await stored(page, listening.id), null, "nothing stored before a listener is spent");
    await page.waitForTimeout(300);
    assert.equal((await summary(listening.id)).stats.fetches, 0, "opening the page spends no listener");
    await page.click("#play");
    assert.equal(await page.evaluate(() => document.activeElement.id), "confirm", "Play asks first");
    await page.getByRole("button", { name: "Not now", exact: true }).click();
    assert.equal(await page.isVisible("#admission"), false);
    assert.equal((await summary(listening.id)).stats.fetches, 0, "Not now spends nothing");
    await screenshot(page, join(evidence, "book-390-dark-details.png"));
    passed("details authenticate; title, author, From, note, chapters, length and listeners left; no admission yet");

    // Keyboard: Play, then Start listening, from the keyboard.
    await page.focus("#play"); await page.keyboard.press("Enter");
    await page.locator("#admission").waitFor({ state: "visible" });
    await page.keyboard.press("Enter"); // focus is on Start listening
    await playingPast(page, 1);
    assert.equal(await current(page), 0);
    assert.equal(await text(page, "#listeners"), "2 listeners left");
    assert.equal((await summary(listening.id)).stats.fetches, 1, "Start listening spends exactly one listener");
    assert.ok(parseFloat(await page.evaluate(() => document.getElementById("seek").style.getPropertyValue("--progress"))) > 0, "progress moves");
    passed("Start listening (keyboard) spends exactly one listener; chapter 1 plays on a moving media clock");

    // ---------- Read-along ----------
    await page.locator("#readalong").waitFor({ state: "visible" });
    const sentence = () => page.evaluate(() => document.querySelector("#paragraph .current")?.textContent ?? null);
    await page.waitForFunction((s) => { const a = document.getElementById("audio"); return a.currentTime > 2.6 && a.currentTime < 4 &&
      document.querySelector("#paragraph .current")?.textContent === s; }, SEGMENTS[1].text, { timeout: 10000 });
    assert.equal(await text(page, "#paragraph"), `${SEGMENTS[0].text} ${SEGMENTS[1].text}`, "the sentence shows inside its paragraph");
    await screenshot(page, join(evidence, "book-390-dark-readalong.png"));
    await page.waitForFunction((s) => document.querySelector("#paragraph .current")?.textContent === s, SEGMENTS[2].text, { timeout: 10000 });
    assert.equal(await sentence(), SEGMENTS[2].text);
    passed("read-along shows the current sentence and its paragraph, following the audio clock");

    // ---------- Continuous play ----------
    await page.waitForFunction((t) => document.getElementById("current").textContent === t, CHAPTERS[1], { timeout: 15000 });
    await playingPast(page, 0.8);
    assert.equal(await current(page), 1);
    assert.equal(await page.isVisible("#admission"), false, "no second admission");
    assert.equal(await page.isVisible("#readalong"), false, "chapter 2 has no text and nothing breaks");
    assert.equal((await summary(listening.id)).stats.fetches, 1, "chapter 2 plays in the same listener");
    const blobLog = await page.evaluate(() => window.__blobs);
    assert.deepEqual(blobLog.made.map((b) => b.type), ["audio/mp4", "audio/mp4"], "one decrypted chapter at a time, labelled audio/mp4");
    assert.ok(blobLog.revoked.includes(blobLog.made[0].url), "chapter 1's Blob URL is revoked");
    passed("play continues from chapter 1 into chapter 2 with no second admission; previous Blob URL revoked");

    // ---------- What the browser keeps ----------
    const entry = await stored(page, listening.id);
    assert.deepEqual(Object.keys(entry).sort(), ["chapter", "expiresAt", "seconds", "token"], "only token, expiry, chapter and seconds");
    assert.equal(entry.chapter, chapters[1].id);
    assert.match(entry.token, /^[A-Za-z0-9_-]{43}$/);
    assert.ok(Number.isSafeInteger(entry.expiresAt) && entry.expiresAt > Date.now());
    const everything = await allStorage(page);
    for (const secret of [key, TITLE, AUTHOR, FROM, NOTE, ...CHAPTERS, ...SEGMENTS.map((s) => s.text)]) assert.ok(!everything.includes(secret), "storage holds no key or title");
    results.storageKeys = Object.keys(entry).sort();
    passed("localStorage holds only {token, expiresAt, chapter, seconds}; no key, no title");

    // ---------- Seek and reload resume ----------
    await page.focus("#seek"); await page.keyboard.press("Home");
    await page.waitForFunction(() => document.getElementById("audio").currentTime < 0.75);
    await playingPast(page, 1.6);
    await page.click("#play");
    await page.waitForFunction(() => document.getElementById("audio").paused);
    const pausedAt = await page.evaluate(() => document.getElementById("audio").currentTime);
    assert.ok(pausedAt > 1.5 && pausedAt < 5, `paused inside chapter 2 at ${pausedAt}`);
    // Extending the link extends the session; the reloaded page moves the stored deadline with it.
    const before = (await stored(page, listening.id)).expiresAt;
    const extended = await api("PATCH", `/v1/share/books/${listening.id}`, JSON.stringify({ extendBySeconds: 3600 }), json);
    assert.equal(extended.status, 200, JSON.stringify(extended.json));
    const deadline = Date.parse(extended.json.share.expiresAt);
    assert.ok(deadline > before, "the link now ends later");
    // Every book page load sweeps other links' expired or unreadable entries and keeps live ones.
    const others = { [`baton-book:${newID()}`]: { token: b64u(crypto.getRandomValues(new Uint8Array(32))), expiresAt: Date.now() - 1000, chapter: newID(), seconds: 3 },
      [`baton-book:${newID()}`]: "not json", [`baton-book:${newID()}`]: { token: b64u(crypto.getRandomValues(new Uint8Array(32))), expiresAt: Date.now() + 3600000, chapter: newID(), seconds: 3 },
      "unrelated-key": { expiresAt: 1 } };
    await page.evaluate((entries) => { for (const [k, v] of Object.entries(entries)) localStorage.setItem(k, typeof v === "string" ? v : JSON.stringify(v)); }, others);
    await page.reload();
    await page.locator("#player").waitFor({ state: "visible" });
    assert.match(await text(page, "#status"), /^Welcome back\. Play resumes chapter 2 at 0:0\d\.$/);
    assert.equal(await page.isVisible("#admission"), false, "a reload asks for nothing");
    assert.equal(await text(page, "#current"), CHAPTERS[1]);
    assert.equal((await stored(page, listening.id)).expiresAt, deadline, "the stored deadline follows the extended link");
    const kept = await page.evaluate((keys) => keys.filter((k) => localStorage.getItem(k) !== null), Object.keys(others));
    assert.deepEqual(kept, Object.keys(others).slice(2), "expired and unreadable entries of other links are swept; live ones and other keys stay");
    await page.evaluate((keys) => keys.forEach((k) => localStorage.removeItem(k)), kept);
    await page.click("#play");
    await page.waitForFunction(() => !document.getElementById("audio").paused && document.getElementById("play").dataset.mode === "pause", null, { timeout: 20000 });
    const resumedAt = await page.evaluate(() => document.getElementById("audio").currentTime);
    assert.ok(resumedAt >= pausedAt - 0.6 && resumedAt < pausedAt + 2, `resumed at ${resumedAt}, paused at ${pausedAt}`);
    assert.equal(await current(page), 1);
    assert.equal((await summary(listening.id)).stats.fetches, 1, "a reload spends no second listener");
    results.resume = { pausedAt, resumedAt };
    passed("reload resumes chapter 2 at its position with the stored token and no second listener; the stored deadline follows an extension; expired entries are swept");

    // Choose a chapter from the keyboard; the last one ends the book.
    await page.locator("#chapters .row").nth(2).focus(); await page.keyboard.press("Enter");
    await page.waitForFunction((t) => document.getElementById("current").textContent === t, CHAPTERS[2]);
    await playingPast(page, 0.5);
    await page.getByRole("button", { name: "React ❤️", exact: true }).click();
    await page.getByText("Reaction sent.", { exact: true }).waitFor();
    await page.waitForFunction(() => document.getElementById("status").textContent === "You reached the end of the book.", null, { timeout: 15000 });
    await page.waitForTimeout(300);
    const owner = await summary(listening.id);
    assert.equal(owner.stats.fetches, 1); assert.equal(owner.stats.plays, 1, "one play started, not one per reload");
    assert.equal(owner.stats.completed, 1, "finishing the last chapter completes the book");
    assert.deepEqual(owner.reactions.map((r) => r.emoji), ["❤️"]);
    results.owner = owner.stats;
    passed("choose a chapter by keyboard; completion and a reaction reach the sender through the session");

    // ---------- Wrong key, missing key, unknown ----------
    const wrong = await phone.newPage();
    await wrong.goto(`${base}/b/${listening.id}#${b64u(new Uint8Array(16))}`);
    await wrong.waitForFunction(() => document.body.dataset.state === "failed");
    assert.equal(await text(wrong, "#status"), "This link’s key does not open this book. Check that you copied all of it.");
    assert.equal(await wrong.isVisible("#player"), false);
    await screenshot(wrong, join(evidence, "book-390-dark-wrong-key.png"));
    await wrong.goto(`${base}/b/${listening.id}`);
    await wrong.waitForFunction(() => document.body.dataset.state === "incomplete");
    await wrong.goto(`${base}/b/AAAAAAAAAAAAAAAAAAAAAA#${key}`);
    await wrong.waitForFunction(() => document.body.dataset.state === "unknown");
    assert.equal(await text(wrong, "#title"), "This link doesn’t lead anywhere");
    await screenshot(wrong, join(evidence, "book-390-dark-unknown.png"));
    await wrong.close();
    assert.equal((await fetch(`${base}/b/AAAAAAAAAAAAAAAAAAAAAA`)).status, 404);
    assert.equal((await summary(listening.id)).stats.fetches, 1, "wrong and missing keys spend nothing");
    passed("wrong key, missing key and unknown link states");

    // ---------- Storage edge cases ----------
    const shots = await mint({ listenerCap: 10, preview: { title: TITLE, author: AUTHOR, from: FROM, note: NOTE } });
    const edge = await phone.newPage();
    await edge.goto(`${base}/b/AAAAAAAAAAAAAAAAAAAAAA`);
    const fake = (expiresAt) => edge.evaluate(([k, value]) => localStorage.setItem(k, JSON.stringify(value)), [`baton-book:${shots.id}`,
      { token: b64u(crypto.getRandomValues(new Uint8Array(32))), expiresAt, chapter: chapters[0].id, seconds: 1 }]);
    // A stored deadline earlier than the live link's means the link was extended (deadlines only move
    // later), and an extension extends the session: the entry is kept and its deadline moves up.
    await fake(Date.now() - 1000);
    await edge.goto(shots.link);
    await edge.locator("#player").waitFor({ state: "visible" });
    assert.match(await text(edge, "#status"), /^Welcome back/);
    assert.equal((await stored(edge, shots.id)).expiresAt, Date.parse((await summary(shots.id)).expiresAt), "the entry takes the live link's deadline");
    const before401 = problems.length;
    await edge.click("#play");
    await edge.locator("#admission").waitFor({ state: "visible" });
    assert.equal(await text(edge, "#status"), "This listening session has ended. Starting again uses another listener.");
    assert.equal(await stored(edge, shots.id), null, "a 401 session deletes the entry");
    const logged401 = problems.splice(before401);
    assert.ok(logged401.every((line) => /status of 401/.test(line)), JSON.stringify(logged401));
    assert.equal((await summary(shots.id)).stats.fetches, 0, "a refused token spends nothing");
    await edge.close();
    const blocked = await contextFor({ viewport: { width: 390, height: 844 }, colorScheme: "light" });
    await blocked.addInitScript(blockStorage);
    const noStorage = await blocked.newPage();
    await noStorage.goto(shots.link);
    await noStorage.locator("#player").waitFor({ state: "visible" });
    assert.equal(await noStorage.evaluate(() => { try { localStorage.getItem("x"); return false; } catch { return true; } }), true, "storage is really blocked");
    await noStorage.getByRole("button", { name: "Start listening", exact: true }).click();
    await playingPast(noStorage, 1);
    await blocked.close();
    passed("a stale stored deadline takes the live link's, a 401 session deletes the entry, and blocked storage still plays");

    // ---------- A link extended while its page is open (TBX-1000000495 D-11) ----------
    // A book session lasts as long as the link, so after an extension the admission's deadline is
    // later than the one the page loaded with.
    const extending = await mint({ listenerCap: 2 });
    const open = await phone.newPage();
    await open.goto(extending.link);
    await open.locator("#player").waitFor({ state: "visible" });
    const endsBefore = await text(open, "#ends");
    const longer = await api("PATCH", `/v1/share/books/${extending.id}`, JSON.stringify({ extendBySeconds: 86400 }), json);
    assert.equal(longer.status, 200, JSON.stringify(longer.json));
    await open.getByRole("button", { name: "Start listening", exact: true }).click();
    await open.waitForFunction(() => document.body.dataset.state !== "ready"
      || (!document.getElementById("audio").paused && document.getElementById("audio").currentTime > 0.5), null, { timeout: 20000 });
    assert.equal(await open.evaluate(() => document.body.dataset.state), "ready", `the later session deadline is accepted: ${await text(open, "#status")}`);
    assert.notEqual(await text(open, "#ends"), endsBefore, "the page shows the link's new end");
    assert.equal((await stored(open, extending.id)).expiresAt, Date.parse(longer.json.share.expiresAt), "the stored session ends with the link");
    assert.equal((await summary(extending.id)).stats.fetches, 1);
    await open.click("#play");
    await open.waitForFunction(() => document.getElementById("audio").paused);
    await open.close();
    // A sharer may hold three live books, and the walk still needs two more.
    assert.equal((await api("DELETE", `/v1/share/books/${extending.id}`)).status, 204);
    passed("a link extended while its page is open still admits, and the page shows the new end");

    // ---------- Screenshots ----------
    const publicBot = await fetch(`${base}/b/${shots.id}`, { headers: { "User-Agent": "facebookexternalhit/1.1" } }).then((r) => r.text());
    assert.match(publicBot, new RegExp(`property="og:title" content="${FROM} sent you ${TITLE} by ${AUTHOR}"`));
    assert.ok(!publicBot.includes(CHAPTERS[0]), "even a public preview names no chapter");
    for (const [width, height, scheme] of [[390, 844, "light"], [390, 844, "dark"], [1280, 860, "light"], [1280, 860, "dark"]]) {
      const shot = await browser.newPage({ viewport: { width, height }, colorScheme: scheme });
      monitor(shot); activate(shot);
      await shot.goto(shots.link);
      await shot.locator("#player").waitFor({ state: "visible" });
      assert.equal(await shot.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal scroll at ${width}`);
      assert.equal(await shot.evaluate(() => getComputedStyle(document.getElementById("card")).position), width < 641 ? "sticky" : "static");
      assert.equal(await shot.evaluate(() => getComputedStyle(document.body).backgroundColor), scheme === "light" ? "rgb(250, 247, 244)" : "rgb(48, 52, 58)");
      const confirm = await shot.evaluate(() => { const s = getComputedStyle(document.getElementById("confirm")); return [s.color, s.backgroundColor]; });
      assert.ok(contrast(...confirm) >= 4.5, `Start listening contrast ${contrast(...confirm).toFixed(2)}:1 in ${scheme}`);
      await shot.getByRole("button", { name: "Start listening", exact: true }).click();
      await playingPast(shot, 1.2);
      await shot.locator("#readalong").waitFor({ state: "visible" });
      await shot.waitForFunction(() => document.querySelector("#paragraph .current"));
      for (const selector of ["#paragraph", "#paragraph .current"]) {
        const pair = await shot.evaluate((s) => { const node = document.querySelector(s), box = document.getElementById("readalong");
          const bg = getComputedStyle(node).backgroundColor; return [getComputedStyle(node).color, bg === "rgba(0, 0, 0, 0)" ? getComputedStyle(box).backgroundColor : bg]; }, selector);
        assert.ok(contrast(...pair) >= 4.5, `${selector} contrast ${contrast(...pair).toFixed(2)}:1 in ${scheme}`);
      }
      await shot.click("#play");
      await shot.waitForFunction(() => document.getElementById("audio").paused);
      await screenshot(shot, join(evidence, `book-${width}-${scheme}.png`));
      await shot.close();
    }
    passed("390 and 1280 px, light and dark: no horizontal scroll, contrast, screenshots");

    // ---------- Pending to ready ----------
    const pending = await mint({ finalize: false });
    const arriving = await phone.newPage();
    await arriving.bringToFront(); // WebKit can starve a page's timers while another page is in front
    await arriving.goto(pending.link);
    await arriving.waitForFunction(() => /still uploading/.test(document.getElementById("status").textContent));
    assert.equal(await arriving.isVisible("#player"), false);
    await pending.finalize();
    try { await arriving.locator("#player").waitFor({ state: "visible", timeout: 15000 }); }
    catch (error) {
      results.pendingState = await arriving.evaluate(() => ({ state: document.body.dataset.state, status: document.getElementById("status").textContent, visibility: document.visibilityState }));
      results.pendingDetails = (await fetch(`${base}/v1/share/b/${pending.id}`)).status;
      throw error;
    }
    assert.equal(await text(arriving, "#title"), TITLE);
    await arriving.close();
    passed("a pending book polls and opens when it is ready");

    // ---------- Revoke while open, revoked and expired links ----------
    assert.ok(await stored(page, listening.id), "the open page still holds its entry");
    assert.equal((await api("DELETE", `/v1/share/books/${listening.id}`)).status, 204);
    const beforeRevoke = problems.length;
    await page.bringToFront(); // this page has been behind others since the screenshots
    await page.locator("#chapters .row").nth(0).click();
    try { await page.waitForFunction(() => document.body.dataset.state === "expired", null, { timeout: 15000 }); }
    catch (error) {
      results.revokeState = await page.evaluate(() => ({ state: document.body.dataset.state, status: document.getElementById("status").textContent,
        mode: document.getElementById("play").dataset.mode, current: document.getElementById("current").textContent, visibility: document.visibilityState }));
      throw error;
    }
    await page.waitForTimeout(200);
    const logged = problems.splice(beforeRevoke);
    assert.ok(logged.every((line) => /status of 410/.test(line)), JSON.stringify(logged));
    assert.equal(await text(page, "#title"), "This book’s link has expired");
    assert.equal(await page.isVisible("#player"), false);
    assert.equal(await stored(page, listening.id), null, "a 410 deletes the entry");
    await screenshot(page, join(evidence, "book-390-dark-revoked.png"));
    const revokedShell = await fetch(`${base}/b/${listening.id}`);
    assert.equal(revokedShell.status, 410);
    const revokedHTML = await revokedShell.text();
    assert.ok(!/revoked/i.test(revokedHTML), "a revoked page never says revoked"); assert.match(revokedHTML, /"state":"expired"/);
    const revokedDetails = await fetch(`${base}/v1/share/b/${listening.id}`);
    assert.equal(revokedDetails.status, 410); assert.ok(!/revoked/i.test(await revokedDetails.text()));
    // A fresh visit to an ended link clears a leftover entry too.
    await page.evaluate(([k, value]) => localStorage.setItem(k, JSON.stringify(value)), [`baton-book:${listening.id}`,
      { token: b64u(crypto.getRandomValues(new Uint8Array(32))), expiresAt: Date.now() + 3600000, chapter: chapters[0].id, seconds: 1 }]);
    await page.reload();
    await page.waitForFunction(() => document.body.dataset.state === "expired");
    assert.equal(await stored(page, listening.id), null, "the expired page deletes a leftover entry");
    passed("revoking reads as expired on the open page and the shell, and clears localStorage");

    if (!external) {
      const expiring = await mint();
      execFileSync("python3", ["-c", "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('UPDATE shares SET expires_at=? WHERE id=?',(int(time.time())-1,sys.argv[2])); c.commit()",
        join(dataDir, "share.sqlite"), expiring.id]);
      const expired = await phone.newPage();
      await expired.goto(expiring.link);
      await expired.waitForFunction(() => document.body.dataset.state === "expired");
      assert.equal(await text(expired, "#title"), "This book’s link has expired");
      assert.equal(await expired.isVisible("#player"), false);
      await expired.close();
      assert.equal((await fetch(`${base}/v1/share/b/${expiring.id}`)).status, 410);
      passed("an expired link reads as expired");
    } else results.checks.push("SKIP expired link: no database writes against an external service");
    await page.close();
    for (const id of [shots.id, pending.id]) assert.equal((await api("DELETE", `/v1/share/books/${id}`)).status, 204);
    assert.deepEqual(problems, [], "no console errors or CSP violations on the book page");
    results.passed = true;
    return null;
  } finally {
    writeFileSync(join(evidence, "book-page.json"), JSON.stringify({ ...results, problems }, null, 2));
    if (network.length) writeFileSync(join(evidence, "book-network.json"), JSON.stringify(network, null, 1));
    await phone.close(); // writes book-phone.har
  }
}
