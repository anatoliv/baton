#!/usr/bin/env node
// End to end, in a real browser: a sharer's upload, a friend's page, decoded media clocks.
//
//   swift build --product baton-share            (in gateway/)
//   node gateway/Tests/share-player/e2e.mjs [--nginx|--nginx-docker] [--browser=chromium|firefox|webkit]
//     [--listeners=50|--media-errors-only|--startup-only|--book-only] [--chromium-channel=chromium]
//     [--song-seconds=400 --download-mbps=10 --latency-ms=80] [path/to/baton-share] [evidence-dir]
//
// With --nginx, everything goes through a real nginx running deploy/nginx/default.conf (rewritten
// only for local paths and ports), exactly as on the deploy host: the service answers X-Accel-Redirect and
// nginx serves the blobs. Without it, the service sends the bytes itself.
//
// SHARE_E2E_SERVICE=http://<addr>:8790 SHARE_E2E_DATA=<its data dir> SHARE_E2E_ADMIN=<token> runs
// against a service that is already running (the Docker image, as share.compose.yml starts it)
// instead of spawning the binary. With --nginx, nginx then serves that container's blobs.
//
// SHARE_E2E_PUBLIC=https://<approved-host> also selects public mode. It checks public
// routing and headers, skips the internal admin report and revokes all minted fixtures.
//
// Needs ffmpeg (to make a real MP3 and AAC book chapters) and the selected Playwright browser. Not in the merge gate:
// each engine takes about a minute, mostly listening through the song like a person would. The
// assertions that matter are the ones a unit test cannot make: the browser decrypts with the
// key from the fragment, the <audio> clock moves, the CSP lets every request through, and the
// beacons the page sends arrive as the counts the sharer sees.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { verifyBookChapters } from "./book-chapter.mjs";
import { verifyBookPage } from "./book-page.mjs";
import { verifyMediaErrorRecovery } from "./media-errors.mjs";
import { verifyMixtapePage } from "./mixtape-page.mjs";
import { measureStartup, registerOwnedBrowser, registerOwnedBrowserServer } from "./startup.mjs";

import { seal } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const takeFlag = (flag) => { const i = args.indexOf(flag); if (i < 0) return false; args.splice(i, 1); return true; };
const takeOption = (name, fallback) => {
  const i = args.findIndex((arg) => arg.startsWith(`${name}=`));
  return i < 0 ? fallback : args.splice(i, 1)[0].slice(name.length + 1);
};
const startupOnly = takeFlag("--startup-only");
const chromiumChannel = takeOption("--chromium-channel", "");
const songSeconds = Number(takeOption("--song-seconds", "40"));
const downloadMbps = Number(takeOption("--download-mbps", "0"));
const latencyMs = Number(takeOption("--latency-ms", "0"));
const mediaErrorsOnly = takeFlag("--media-errors-only");
// Only the whole-book page walk (/b/), after the shared nginx checks: a quicker loop for the book page.
const bookOnly = takeFlag("--book-only");
assert.ok(!mediaErrorsOnly || !args.some(arg => arg.startsWith("--listeners=")), "media error cases run separately from listener load");
const dockerNginx = takeFlag("--nginx-docker");
const viaNginx = takeFlag("--nginx") || dockerNginx;
const publicBase = process.env.SHARE_E2E_PUBLIC?.replace(/\/+$/, "");
const publicOnly = takeFlag("--public") || Boolean(publicBase);
const engine = takeOption("--browser", "chromium");
assert.ok(["chromium", "firefox", "webkit"].includes(engine), "--browser must be chromium, firefox or webkit");
const listeners = Number(takeOption("--listeners", "0"));
assert.ok(Number.isInteger(listeners) && listeners >= 0 && listeners <= 50, "--listeners must be 0..50");
assert.ok(!listeners || viaNginx, "the listener load check must run through nginx");
assert.ok(!startupOnly || !process.env.SHARE_E2E_SERVICE, "startup measurement starts its own synthetic localhost service");
assert.ok(!startupOnly || (engine === "chromium" && !publicOnly && !listeners && !mediaErrorsOnly), "startup measurement is a standalone local Chromium check");
assert.ok(!chromiumChannel || (engine === "chromium" && chromiumChannel === "chromium"), "only the cached full Chromium channel is supported");
assert.ok(Number.isInteger(songSeconds) && songSeconds >= 40 && songSeconds <= 800 && (startupOnly || songSeconds === 40), "synthetic song length is 40..800s, extended only for startup measurement");
assert.ok(Number.isFinite(downloadMbps) && downloadMbps >= 0 && downloadMbps <= 100 && (startupOnly || downloadMbps === 0));
assert.ok(Number.isFinite(latencyMs) && latencyMs >= 0 && latencyMs <= 1000 && (startupOnly || latencyMs === 0));
const ownedRunID = process.env.SHARE_E2E_RUN_ID;
assert.ok(!ownedRunID || /^[a-f0-9]{32}$/.test(ownedRunID), "diagnostic run ID must be a fresh UUID hex value");
const binary = resolve(args[0] ?? join(here, "../../.build/debug/baton-share"));
const evidence = resolve(args[1] ?? mkdtempSync(join(tmpdir(), "share-e2e-evidence-")));
mkdirSync(evidence, { recursive: true });

const require = createRequire(import.meta.url);
let playwright;
for (const candidate of [process.env.SHARE_E2E_PLAYWRIGHT, "playwright", "/opt/node22/lib/node_modules/playwright"].filter(Boolean)) {
  try {
    playwright = require(candidate);
    break;
  } catch {}
}
assert.ok(playwright, "Playwright is not installed");

const work = mkdtempSync(join(tmpdir(), "share-e2e-"));
// nginx's workers run as another user, as they do on the deploy host: let them through to the data.
chmodSync(work, 0o755);
const external = publicBase ?? process.env.SHARE_E2E_SERVICE;
assert.ok(!publicOnly || (external && !viaNginx), "public mode requires SHARE_E2E_SERVICE or SHARE_E2E_PUBLIC and no local nginx flag");
assert.ok(!external || publicOnly || ["localhost", "127.0.0.1", "[::1]"].includes(new URL(external).hostname),
  "external public service requires explicit --public (owner approval required before running it)");
const port = 18000 + Math.floor(Math.random() * 1000);
const nginxPort = port + 1000;
const direct = external ?? `http://127.0.0.1:${port}`;
const dataDir = process.env.SHARE_E2E_DATA ?? join(work, "data");
const base = viaNginx ? `http://127.0.0.1:${nginxPort}` : direct;
const admin = process.env.SHARE_E2E_ADMIN ?? "e2e-admin-token-0123456789abcdef0123";
const secret = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const b64u = (bytes) => Buffer.from(bytes).toString("base64url");
const sha256 = async (bytes) => Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");

function step(text) {
  console.log(`  · ${text}`);
}
const deferredScreenshots = [];
async function screenshot(page, path) {
  if (engine === "webkit") deferredScreenshots.push(page);
  else await page.screenshot({ path });
}

// ---------- A real song and a real cover ----------

step(`making a ${songSeconds} s MP3 and a cover with ffmpeg`);
const mp3 = join(work, "song.mp3");
const png = join(work, "cover.png");
execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", `sine=frequency=330:duration=${songSeconds}`,
  "-f", "lavfi", "-i", `sine=frequency=495:duration=${songSeconds}`, "-filter_complex", "amix=inputs=2,volume=0.6",
  "-c:a", "libmp3lame", "-b:a", "192k", mp3]);
execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i",
  "gradients=s=600x600:c0=0x1d3b6f:c1=0xe98345:x0=0:y0=0:x1=600:y1=600:d=1", "-frames:v", "1", png]);
const song = new Uint8Array(readFileSync(mp3));
const cover = new Uint8Array(readFileSync(png));

// ---------- The service ----------

step(external ? `using the running service at ${external}` : `starting ${binary} on ${port}`);
const server = external ? null : spawn(binary, [], {
  env: { ...process.env, BATON_SHARE_DATA: join(work, "data"), BATON_SHARE_PORT: String(port),
    BATON_SHARE_PUBLIC_BASE: base, BATON_SHARE_BLOB_DELIVERY: viaNginx ? "accel" : "direct",
    BATON_SHARE_ADMIN_TOKEN: admin, BATON_SHARE_MIXTAPES: "1", BATON_SHARE_BOOKS: "1" },
  stdio: ["ignore", "pipe", "pipe"],
});
let serverLog = "";
server?.stdout.on("data", (d) => { serverLog += d; });
server?.stderr.on("data", (d) => { serverLog += d; });

// The production site config, with only what must differ on this machine rewritten.
let nginx = null;
const dockerName = ownedRunID ? `baton-share-startup-${ownedRunID}` : `baton-share-e2e-${process.pid}`;
if (viaNginx) {
  step(`starting nginx on ${nginxPort} with deploy/nginx/default.conf`);
  const repo = resolve(here, "../../..");
  const conf = join(work, "conf.d");
  mkdirSync(conf, { recursive: true });
  mkdirSync(join(work, "nginx-tmp"), { recursive: true });
  const swap = (text, from, to) => {
    assert.ok(text.includes(from), `default.conf no longer contains ${from}`);
    return text.split(from).join(to);
  };
  let site = readFileSync(join(repo, "deploy/nginx/default.conf"), "utf8");
  const containerWork = dockerNginx ? "/e2e" : work;
  const confPath = dockerNginx ? "/e2e/conf.d" : conf;
  site = swap(site, "listen 80;", dockerNginx ? "listen 80;" : `listen 127.0.0.1:${nginxPort};`);
  site = swap(site, "root  /usr/share/nginx/html;", `root  ${dockerNginx ? "/site" : join(repo, "website")};`);
  site = swap(site, "/etc/nginx/conf.d/share-proxy.inc", `${confPath}/share-proxy.inc`);
  site = swap(site, "alias /srv/baton-share/blobs/;", `alias ${dockerNginx ? "/data/blobs" : join(dataDir, "blobs")}/;`);
  site = swap(site, '"http://baton-share:8790"', `"${dockerNginx ? direct.replace("127.0.0.1", "host.docker.internal") : direct}"`);
  writeFileSync(join(conf, "default.conf"), site);
  writeFileSync(join(conf, "share-proxy.inc"), readFileSync(join(repo, "deploy/nginx/share-proxy.inc")));
  const tmp = `${containerWork}/nginx-tmp`;
  const mimeTypes = process.env.SHARE_E2E_NGINX_MIME ?? ["/etc/nginx/mime.types", "/opt/homebrew/etc/nginx/mime.types"].find(existsSync);
  assert.ok(dockerNginx || mimeTypes, "set SHARE_E2E_NGINX_MIME to nginx's mime.types");
  // SHARE_E2E_NGINX_LOG=1 (diagnosis): nginx's own view of every request, with its connection and
  // upstream timings, and info-level errors (resolver, upstream). Paths only: no fragment reaches nginx.
  const nginxLog = process.env.SHARE_E2E_NGINX_LOG === "1";
  const accessLog = nginxLog ? `log_format timing '$msec $connection/$connection_requests $status $request_time '
      'up=$upstream_addr connect=$upstream_connect_time response=$upstream_response_time "$request_method $uri"'; access_log /dev/stderr timing;` : "access_log off;";
  writeFileSync(join(work, "nginx.conf"), `daemon off; pid ${containerWork}/nginx.pid; error_log stderr ${nginxLog ? "info" : "warn"};
events {}
http { include ${dockerNginx ? "/etc/nginx/mime.types" : mimeTypes}; ${accessLog} client_body_temp_path ${tmp}/body; proxy_temp_path ${tmp}/proxy;
  fastcgi_temp_path ${tmp}/fcgi; uwsgi_temp_path ${tmp}/uwsgi; scgi_temp_path ${tmp}/scgi; sendfile on;
  include ${confPath}/default.conf; }`);
  mkdirSync(dataDir, { recursive: true });
  if (dockerNginx) execFileSync("docker", ["network", "create", dockerName], { stdio: "ignore" });
  nginx = dockerNginx
    ? spawn("docker", ["run", "--rm", "--name", dockerName, "--network", dockerName, "-p", `127.0.0.1:${nginxPort}:80`,
      "-v", `${work}:/e2e`, "-v", `${join(repo, "website")}:/site:ro`, "-v", `${dataDir}:/data:ro`,
      "nginx:alpine", "nginx", "-c", "/e2e/nginx.conf"], { stdio: ["ignore", "pipe", "pipe"] })
    : spawn(process.env.SHARE_E2E_NGINX ?? "nginx", ["-c", join(work, "nginx.conf")], { stdio: ["ignore", "pipe", "pipe"] });
  nginx.stderr.on("data", (d) => { serverLog += `[nginx] ${d}`; });
}

let failed = false;
let browser;
let browserServer;
let activePage;
const mintedIDs = [];
const skips = [];
try {
  for (let i = 0; i < 50; i++) {
    if (await fetch(`${direct}/${external ? "v1/share/config" : "health"}`, { signal: AbortSignal.timeout(1000) }).then((r) => r.ok, () => false)) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  for (let i = 0; viaNginx && i < 50; i++) {
    if (await fetch(`${base}/v1/share/config`, { signal: AbortSignal.timeout(1000) }).then((r) => r.ok, () => false)) break;
    await new Promise((r) => setTimeout(r, 100));
  }

  async function api(method, path, body, headers = {}) {
    const response = await fetch(base + path, {
      method,
      signal: AbortSignal.timeout(20000),
      headers: { Authorization: `Bearer ${secret}`, "User-Agent": "e2e-sharer", ...headers },
      body,
    });
    const text = await response.text();
    return { status: response.status, json: text ? JSON.parse(text) : null };
  }

  // ---------- The sharer ----------

  step("sealing and uploading the way the app will");
  const key = crypto.getRandomValues(new Uint8Array(16));
  const sealed = await seal(song, key, "audio");
  const peaks = Array.from({ length: 160 }, (_, i) => Math.round(70 + 120 * Math.abs(Math.sin(i / 7)) * (0.6 + 0.4 * Math.sin(i / 23))));
  const created = await api("POST", "/v1/share/shares", JSON.stringify({
    expiresInSeconds: 604800, playCap: 100, audioBytes: sealed.length, audioSHA256: await sha256(sealed),
    client: { platform: "macos", appVersion: "e2e" },
    preview: { title: "Two Tones", artist: "The Test Signals", album: "Sine Sessions", durationSeconds: songSeconds,
      from: "Anatoli", note: "This is the one I was humming in the car.", accent: "#3A7BD5", peaks },
  }), { "Content-Type": "application/json" });
  assert.equal(created.status, 201, JSON.stringify(created.json));
  const id = created.json.id;
  mintedIDs.push(id);
  assert.equal((await api("PUT", created.json.uploads.audio, sealed)).status, 200);
  assert.equal((await api("PUT", created.json.uploads.art, cover)).status, 200);
  assert.equal((await api("POST", `/v1/share/shares/${id}/finalize`)).status, 200);
  const link = `${base}/s/${id}#${b64u(key)}`;
  step("fixture link created (fragment key kept out of logs)");

  if (viaNginx || publicOnly) {
    step("checking what nginx adds and serves");
    const page = await fetch(`${base}/s/${id}`, { headers: { "User-Agent": "e2e-probe" } });
    const header = (name) => page.headers.get(name);
    assert.equal(header("referrer-policy"), "no-referrer", "one Referrer-Policy, the share page's");
    assert.equal(header("x-content-type-options"), "nosniff", "one nosniff, not two");
    assert.equal(header("cache-control"), "no-store", "the service's cache policy, alone");
    assert.match(header("content-security-policy") ?? "", /default-src 'none'/);
    const css = await fetch(`${base}/s/_/player.css`);
    assert.equal(css.headers.get("cache-control"), "public, no-cache", "no second Cache-Control from the site map");
    const cssBytes = Buffer.from(await css.arrayBuffer());
    const oldCSS = await fetch(`${base}/s/_/player.css?v=retired-deployment-hash`);
    assert.equal(oldCSS.headers.get("cache-control"), "public, no-cache", "retired query URLs revalidate through nginx");
    assert.deepEqual(Buffer.from(await oldCSS.arrayBuffer()), cssBytes, "retired query URLs serve current mutable bytes");
    if (!mediaErrorsOnly && !startupOnly) {
    const ranged = await fetch(`${base}/v1/share/p/${id}/audio`, { headers: { Range: "bytes=100-199" } });
    assert.equal(ranged.status, 206, "nginx serves ranges of the blob");
    assert.equal((await ranged.arrayBuffer()).byteLength, 100);
    assert.equal(ranged.headers.get("cache-control"), "private, no-store", "the audio stays uncacheable through nginx");
    }
    assert.equal((await fetch(`${base}/_share_blobs/${id}/audio`)).status, 404, "the blob path is internal-only");
    assert.equal((await fetch(`${base}/v1/share/admin/stats`, { headers: { Authorization: `Bearer ${admin}` } })).status, 404,
      "the admin report is not reachable through the site");
    assert.equal((await fetch(`${base}/`)).status, 200, "the marketing site still serves");
  }

  // ---------- The friend ----------

  const launchOptions = {
    ...(chromiumChannel ? { channel: chromiumChannel } : {}),
    ...(engine === "chromium" ? { args: ["--autoplay-policy=user-gesture-required"] } : {}),
    ...(process.env.SHARE_E2E_BROWSER_PATH ? { executablePath: process.env.SHARE_E2E_BROWSER_PATH } : {}),
  };
  if (ownedRunID && !startupOnly) {
    assert.ok(!publicOnly && !external && !mediaErrorsOnly, "bounded full flow/load is local and standalone");
    browserServer = await playwright[engine].launchServer({...launchOptions, host:"127.0.0.1"});
    const launcher=process.env.SHARE_E2E_BROWSER_PATH ?? playwright[engine].executablePath();
    const runtimeExecutable=engine === "webkit" ? join(dirname(launcher),"Playwright.app/Contents/MacOS/Playwright") : launcher;
    registerOwnedBrowserServer(browserServer,evidence,ownedRunID,{launcher,runtimeExecutable});
    browser = await playwright[engine].connect(browserServer.wsEndpoint());
  } else browser = await playwright[engine].launch(launchOptions);
  const startupLaunch = {headless:true,channel:chromiumChannel,
    args:engine === "chromium" ? ["--autoplay-policy=user-gesture-required"] : [],
    executable:process.env.SHARE_E2E_BROWSER_PATH ?? playwright[engine].executablePath()};
  if (startupOnly) await registerOwnedBrowser(browser,evidence,ownedRunID,startupLaunch.executable);
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: "dark",
    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1 e2e",
  });
  const problems = [];
  const monitor = (page) => {
    const endedDocuments = new Set();
    page.on("response", (response) => {
      if (response.request().isNavigationRequest() && [404, 410].includes(response.status())) endedDocuments.add(response.url());
    });
    page.on("console", (m) => {
      // Unknown/expired/capped pages deliberately have a 404/410 document status.
      // WebKit logs that navigation as a resource error even though our page runs.
      const expectedDocumentError = /^Failed to load resource: the server responded with a status of (404|410) /.test(m.text())
        && endedDocuments.has(m.location().url.split("#")[0]);
      if (m.type() === "error" && !expectedDocumentError) problems.push(m.text());
    });
    page.on("pageerror", (e) => problems.push(String(e)));
  };
  context.on("page", monitor);
  if (!startupOnly && !mediaErrorsOnly) await context.addInitScript(() => {
    // Observe the real element; never replace decode, currentTime or media events.
    const NativeAudio = window.Audio;
    window.Audio = function(...args) {
      const audio = new NativeAudio(...args);
      window.__fullFlowAudio = audio;
      return audio;
    };
    window.Audio.prototype = NativeAudio.prototype;
    Object.setPrototypeOf(window.Audio, NativeAudio);
  });
  const page = await context.newPage();
  activePage = page;

  let mediaErrorScreenshotErrors = [];
  if (startupOnly) {
    step("bounded startup/media-clock and own-browser memory measurement");
    let mine;
    try { await measureStartup({ browser, context, page, link, evidence, problems,
      profile: { chromiumChannel: chromiumChannel || "headless-shell", songSeconds, plainBytes: song.length,
        sealedBytes: sealed.length, downloadMbps, latencyMs }, launch:startupLaunch });
    } finally {
      mine = (await api("GET", "/v1/share/shares")).json.shares.find(share => share.id === id);
      writeFileSync(join(evidence, "startup-receipts.json"), JSON.stringify(mine.stats, null, 2));
    }
    assert.equal(mine.stats.fetches, 1); assert.equal(mine.stats.plays, 1); assert.equal(mine.stats.listeners, 1);
    assert.equal((await api("DELETE", `/v1/share/shares/${id}`)).status, 204);
  } else if (mediaErrorsOnly) {
    step("real decoder errors and explicit retries preserve one fetch/listening session");
    mediaErrorScreenshotErrors = await verifyMediaErrorRecovery({browser,link,api,id,evidence});
    if (!publicOnly) {
      const report = await fetch(`${direct}/v1/share/admin/stats?days=1`, { headers: { Authorization: `Bearer ${admin}` } }).then((r) => r.json());
      assert.deepEqual(report.listening.decryptFailures, {}, "media failures are never crypto failures");
      writeFileSync(join(evidence, "media-error-receipts.json"), JSON.stringify({listening:report.listening}, null, 2));
    }
    assert.equal((await api("DELETE", `/v1/share/shares/${id}`)).status, 204);
  } else if (bookOnly) {
    assert.ok(!publicOnly, "the book page walk is local only");
    const skipped = await verifyBookPage({ browser, base, direct, api, evidence, dataDir, external, work, step, screenshot, monitor, problems,
      activate: (bookPage) => { activePage = bookPage; } });
    if (skipped) { skips.push(skipped); step(`SKIP ${skipped}`); }
    assert.equal((await api("DELETE", `/v1/share/shares/${id}`)).status, 204);
  } else {
  step("opening the link as a friend on a phone");
  await page.goto(link);
  await page.waitForSelector("#player:not([hidden])");
  assert.equal(await page.textContent("#title"), "Two Tones");
  assert.equal(await page.textContent("#eyebrow"), "Anatoli sent you a song");
  assert.equal(await page.textContent("#note-text"), "This is the one I was humming in the car.");
  assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--song").trim()), "#3A7BD5");
  await page.waitForSelector("#art:not([hidden])");
  await screenshot(page, join(evidence, "1-ready.png"));

  step("pressing play: download, decrypt in the browser, advancing media clock");
  await page.click("#play");
  await page.waitForSelector("body.is-playing", { timeout: 20000 });
  await page.waitForFunction(() => document.getElementById("elapsed").textContent !== "0:00", null, { timeout: 10000 });
  await page.waitForTimeout(1500);
  assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById("play")).getPropertyValue("--progress").trim()), "1");
  await screenshot(page, join(evidence, "2-playing.png"));
  step("pause and resume preserve one listening session");
  await page.click("#play");
  await page.waitForFunction(() => !document.body.classList.contains("is-playing"));
  const pausedElapsed = await page.textContent("#elapsed");
  await page.waitForTimeout(1200);
  assert.equal(await page.textContent("#elapsed"), pausedElapsed);
  await page.click("#play");
  await page.waitForSelector("body.is-playing");

  step("seeking backward with the actual range control, then advancing again");
  const beforeSeek = await page.evaluate(() => window.__fullFlowAudio.currentTime);
  assert.ok(beforeSeek > 1, "decoded media advanced before seeking");
  await page.focus("#seek");
  await page.keyboard.press("Home");
  await page.waitForFunction(() => window.__fullFlowAudio.currentTime < .75, null, { timeout: 5000 });
  const afterSeek = await page.evaluate(() => window.__fullFlowAudio.currentTime);
  assert.ok(afterSeek < beforeSeek - 1, "native range input moved the real media clock backward");
  await page.waitForFunction(() => window.__fullFlowAudio.currentTime > 1.5, null, { timeout: 10000 });
  const seekMedia = await page.evaluate(() => ({currentTime: window.__fullFlowAudio.currentTime,
    readyState: window.__fullFlowAudio.readyState, paused: window.__fullFlowAudio.paused,
    error: window.__fullFlowAudio.error?.code ?? null, playing: document.body.classList.contains("is-playing")}));
  writeFileSync(join(evidence, "seek.json"), JSON.stringify({beforeSeek, afterSeek, resumed: seekMedia,
    action: "native range Home key", syntheticClock: false}, null, 2));
  assert.equal(seekMedia.error, null);
  assert.equal(seekMedia.paused, false);
  assert.equal(seekMedia.playing, true);

  step("listening past 30 s, as a person would");
  await page.waitForSelector("#after:not([hidden])", { timeout: 45000 });
  assert.equal(await page.isVisible("#reply"), false, "reply form stays hidden until a reaction is chosen");
  assert.equal(await page.isVisible("#reactions"), true);
  assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById("reactions")).display), "flex");
  await page.click('#reactions button[aria-label="React with ❤️"]');
  assert.equal(await page.isVisible("#reply"), true);
  assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById("reply")).display), "grid");
  await page.fill("#reply-name", "Maya");
  await page.fill("#reply-text", "On repeat");
  await screenshot(page, join(evidence, "3-react.png"));
  await page.click("#send");
  await page.waitForSelector("#sent:not([hidden])");
  assert.equal(await page.textContent("#sent"), "❤️ Sent to Anatoli.");
  assert.equal(await page.isVisible("#reply"), false, "successful send hides the reply form visually");
  assert.equal(await page.isVisible("#reactions"), false, "successful send hides the reaction controls visually");
  assert.equal(await page.isVisible("#sent"), true);
  await screenshot(page, join(evidence, "4-sent.png"));
  step("finishing the song: the completion beacon lands");
  await page.waitForFunction(() => !document.body.classList.contains("is-playing")
    && document.getElementById("elapsed").textContent === "0:40", null, { timeout: 20000 });
  assert.match(await page.getAttribute("#get-baton", "href"), /^https:\/\/apps\.apple\.com\/.+ct=share-link/);
  // Exercise the real attribution handler without sending a request to Apple.
  await page.evaluate(() => document.getElementById("get-baton").addEventListener("click", (event) => event.preventDefault(), { once: true }));
  await page.click("#get-baton");

  step("an incomplete link, and a wrong key");
  const bare = await context.newPage();
  await bare.goto(`${base}/s/${id}`);
  await bare.waitForFunction(() => document.body.dataset.state === "incomplete");
  await screenshot(bare, join(evidence, "5-incomplete.png"));
  const wrong = await context.newPage();
  await wrong.goto(`${base}/s/${id}#${b64u(new Uint8Array(16))}`);
  await wrong.waitForSelector("#player:not([hidden])");
  await wrong.click("#play");
  await wrong.waitForFunction(() => document.body.dataset.state === "failed", null, { timeout: 15000 });

  step("the desktop layout, light theme");
  const desk = await browser.newPage({ viewport: { width: 1280, height: 860 }, colorScheme: "light" });
  monitor(desk);
  await desk.goto(link);
  await desk.waitForSelector("#art:not([hidden])");
  await screenshot(desk, join(evidence, "6-desktop-light.png"));
  assert.match(await desk.getAttribute("#get-baton", "href"), /\?ref=share#get$/);
  await desk.evaluate(() => document.getElementById("get-baton").addEventListener("click", (event) => event.preventDefault(), { once: true }));
  await desk.click("#get-baton");

  await page.waitForTimeout(500); // let the last beacons land
  assert.deepEqual(problems, [], "no console errors, no CSP violations");

  // ---------- What the sharer sees ----------

  step("checking what the sharer sees");
  const mine = (await api("GET", "/v1/share/shares")).json.shares[0];
  console.log(`    stats ${JSON.stringify(mine.stats)} reactions ${JSON.stringify(mine.reactions.map((r) => [r.emoji, r.name, r.reply]))}`);
  assert.equal(mine.stats.plays, 1);
  assert.equal(mine.stats.listened30s, 1);
  assert.equal(mine.stats.completed, 1);
  assert.equal(mine.stats.listeners, 1);
  assert.ok(mine.stats.opens >= 3);
  assert.deepEqual(mine.reactions.map((r) => [r.emoji, r.name, r.reply]), [["❤️", "Maya", "On repeat"]]);

  step("revoking: the friend's page says expired");
  assert.equal((await api("DELETE", `/v1/share/shares/${id}`)).status, 204);
  const after = await context.newPage();
  await after.goto(link);
  await after.waitForFunction(() => document.body.dataset.state === "expired");
  await screenshot(after, join(evidence, "7-expired.png"));

  if (!publicOnly) {
    const report = await fetch(`${direct}/v1/share/admin/stats?days=1`, { headers: { Authorization: `Bearer ${admin}` } }).then((r) => r.json());
    console.log(`    report: sharers ${report.sharers.active}, shares ${report.shares.created}, opens ${report.recipients.pageOpens}, `
      + `listeners ${report.listening.uniqueListeners}, first sound p50 ${report.listening.timeToFirstSoundMsP50} ms, `
      + `decrypt failures ${JSON.stringify(report.listening.decryptFailures)}`);
    assert.equal(report.listening.decryptFailures.missing_key, 1);
    assert.equal(report.listening.decryptFailures.auth, 1);
    assert.equal(report.engagement.getBatonClicks.app_store, 1);
    assert.equal(report.engagement.getBatonClicks.mac_download, 1);
  } else step("SKIP internal admin aggregate report: public route must remain 404");

  // ---------- Lifecycle, private metadata and link previews ----------

  async function fixture({ privateShare = false, expiresInSeconds = 604800, playCap = 100, finalize = true } = {}) {
    const metadata = { title: "Hidden Tones", artist: "Private Signals", album: "Secret Session",
      durationSeconds: 40, from: "Synthetic Sender", note: "Fixture private note", accent: "#3A7BD5", peaks };
    const metadataFields = privateShare
      ? { encryptedMeta: Buffer.from(await seal(new TextEncoder().encode(JSON.stringify(metadata)), key, "meta")).toString("base64"), durationBucket: "<1m" }
      : { preview: metadata };
    const result = await api("POST", "/v1/share/shares", JSON.stringify({ expiresInSeconds, playCap,
      audioBytes: sealed.length, audioSHA256: await sha256(sealed), ...metadataFields,
      client: { platform: "macos", appVersion: "e2e" } }), { "Content-Type": "application/json" });
    assert.equal(result.status, 201, JSON.stringify(result.json));
    mintedIDs.push(result.json.id);
    assert.equal((await api("PUT", result.json.uploads.audio, sealed)).status, 200);
    if (finalize) assert.equal((await api("POST", `/v1/share/shares/${result.json.id}/finalize`)).status, 200);
    return { ...result.json, link: `${base}/s/${result.json.id}#${b64u(key)}` };
  }
  async function state(link, expected, name) {
    const probe = await context.newPage();
    await probe.goto(link);
    await probe.waitForFunction((wanted) => document.body.dataset.state === wanted, expected);
    await screenshot(probe, join(evidence, name));
    assert.equal(await probe.isVisible("#player"), false);
    await probe.close();
  }
  step("unknown, pending-to-ready, expired, capped and extended links");
  await state(`${base}/s/0000000000000000000000#${b64u(key)}`, "unknown", "8-unknown.png");
  const pending = await fixture({ finalize: false });
  const arriving = await context.newPage();
  await arriving.goto(pending.link);
  assert.match(await arriving.textContent("#status"), /Arriving/);
  assert.equal(await arriving.isVisible("#player"), false);
  assert.equal((await api("POST", `/v1/share/shares/${pending.id}/finalize`)).status, 200);
  await arriving.waitForSelector("#player:not([hidden])", { timeout: 10000 });
  await arriving.close();
  if (!external) {
    const expiring = await fixture();
    // Advance this dedicated localhost fixture's deadline instead of waiting seven days.
    execFileSync("python3", ["-c", "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('UPDATE shares SET expires_at=? WHERE id=?',(int(time.time())-1,sys.argv[2])); c.commit()",
      join(dataDir, "share.sqlite"), expiring.id]);
    await state(expiring.link, "expired", "9-natural-expiry.png");
    assert.equal((await fetch(`${base}/v1/share/p/${expiring.id}/audio`)).status, 410);
  } else step("SKIP deadline fixture: no database writes against an external service");
  const capped = await fixture({ playCap: 1 });
  assert.equal((await fetch(`${base}/v1/share/p/${capped.id}/audio`)).status, 200);
  await state(capped.link, "play_cap", "10-play-cap.png");
  assert.equal((await fetch(`${base}/v1/share/p/${capped.id}/audio`)).status, 410);
  const raised = await api("PATCH", `/v1/share/shares/${capped.id}`, JSON.stringify({ playCap: 100, extendBySeconds: 3600 }),
    { "Content-Type": "application/json" });
  assert.equal(raised.status, 200);
  assert.ok(raised.json.expiresAt > capped.expiresAt);
  assert.equal((await fetch(`${base}/v1/share/p/${capped.id}/audio`)).status, 200);

  step("public and private Open Graph; private browser metadata decrypts without leaking to preview bots");
  const publicPage = await fetch(`${base}/s/${pending.id}`, { headers: { "User-Agent": "facebookexternalhit/1.1" } }).then((r) => r.text());
  assert.match(publicPage, /property="og:title" content="Synthetic Sender sent you Hidden Tones by Private Signals"/);
  const privateFixture = await fixture({ privateShare: true });
  const privatePage = await fetch(`${base}/s/${privateFixture.id}`, { headers: { "User-Agent": "facebookexternalhit/1.1" } }).then((r) => r.text());
  assert.match(privatePage, /property="og:title" content="Someone sent you a song"/);
  for (const text of ["Hidden Tones", "Private Signals", "Secret Session", "Fixture private note", b64u(key)]) {
    assert.ok(!privatePage.includes(text), `private page does not expose ${text}`);
  }
  const unlockedPrivate = await context.newPage();
  await unlockedPrivate.goto(privateFixture.link);
  await unlockedPrivate.waitForSelector("#player:not([hidden])");
  assert.equal(await unlockedPrivate.textContent("#title"), "Hidden Tones");
  await unlockedPrivate.click("#play");
  await unlockedPrivate.waitForSelector("body.is-playing", { timeout: 20000 });
  await unlockedPrivate.waitForFunction(() => document.getElementById("elapsed").textContent !== "0:00");
  await screenshot(unlockedPrivate, join(evidence, "11-private-playing.png"));
  await unlockedPrivate.close();

  // No artificial audio-clock advance: every listener fetches and decrypts the MP3,
  // then its actual media clock must move. Start each playback together after loading.
  if (listeners) {
    step(`${listeners} simultaneous ${engine} listeners through real nginx (synthetic localhost only)`);
    assert.ok(new URL(base).hostname === "127.0.0.1" && !external, "load fixtures are local-only");
    const load = await fixture({ playCap: 100 });
    const contexts = await Promise.all(Array.from({ length: listeners }, (_, i) => browser.newContext({
      userAgent: `BatonSyntheticListener/${i}`, viewport: { width: 390, height: 844 },
    })));
    const decoder = Array.from({ length: listeners }, () => []);
    if (engine === "chromium") {
      const session = await browser.newBrowserCDPSession();
      try {
        const version = await session.send("Browser.getVersion");
        writeFileSync(join(evidence, "load-runtime.json"), JSON.stringify({version, requestedLaunch:startupLaunch,
          actualCommandLineAvailable:false, syntheticOnly:true,
          commandLineLimitation:"No enable-automation flag or duplicate mute flag added; runtime hash/identity is in startup-process-registry.json"}, null, 2));
      } finally { await session.detach(); }
    }
    try {
      const pages = await Promise.all(contexts.map(async (ctx, index) => {
        // Retain the real media element for failure evidence, with physical output muted.
        await ctx.addInitScript(() => {
          const OriginalAudio = window.Audio;
          window.Audio = function(...args) {
            const audio = new OriginalAudio(...args);
            audio.muted = true;
            window.__loadAudio = audio;
            window.__loadMediaEvents = [];
            for (const type of ["playing", "pause", "waiting", "stalled", "error", "ended"])
              audio.addEventListener(type, () => window.__loadMediaEvents.push({type, at:performance.now(),
                currentTime:audio.currentTime, paused:audio.paused, error:audio.error?.code ?? null}));
            return audio;
          };
          window.Audio.prototype = OriginalAudio.prototype;
          Object.setPrototypeOf(window.Audio, OriginalAudio);
        });
        const listener = await ctx.newPage();
        if (engine === "chromium") {
          const session = await ctx.newCDPSession(listener);
          // Record renderer errors without synthetic invitation URLs or whole event streams.
          for (const event of ["Media.playerErrorsRaised", "Media.playerMessagesLogged"])
            session.on(event, value => {
              if (decoder[index].length < 128) decoder[index].push({event,
                value:JSON.parse(JSON.stringify(value).replace(/https?:\/\/[^\s"\\]+/g, "[redacted-url]"))});
            });
          await session.send("Media.enable");
        }
        monitor(listener);
        await listener.goto(load.link);
        await listener.waitForSelector("#player:not([hidden])", { timeout: 30000 });
        return listener;
      }));
      const started = Date.now();
      const outcomes = await Promise.allSettled(pages.map(async (listener) => {
        await listener.click("#play", { timeout: 30000 });
        await listener.waitForSelector("body.is-playing", { timeout: 30000 });
        // Hidden tabs may suspend requestAnimationFrame. Poll the DOM on a timer,
        // while the page's real audio/timeupdate path still supplies the value.
        await listener.waitForFunction(() => window.__loadAudio.currentTime >= 30, null,
          { timeout: 45000, polling: 100 });
      }));
      const loadStates = await Promise.all(pages.map((listener) => listener.evaluate(() => ({
        elapsed: document.getElementById("elapsed").textContent,
        playing: document.body.classList.contains("is-playing"), visibility: document.visibilityState,
        media: {currentTime: window.__loadAudio.currentTime, duration: window.__loadAudio.duration,
          readyState: window.__loadAudio.readyState, networkState: window.__loadAudio.networkState,
          paused: window.__loadAudio.paused, muted: window.__loadAudio.muted,
          error: window.__loadAudio.error?.code ?? null},
        mediaEvents: window.__loadMediaEvents,
      }))));
      const passed = outcomes.filter((outcome) => outcome.status === "fulfilled").length;
      writeFileSync(join(evidence, "load-states.json"), JSON.stringify({ listeners, passed, states: loadStates }, null, 2));
      writeFileSync(join(evidence, "load-outcomes.json"), JSON.stringify(outcomes.map((outcome,index) =>
        ({index,status:outcome.status,reason:outcome.status === "rejected" ? String(outcome.reason) : null})), null, 2));
      let counts;
      for (let attempt = 0; attempt < 50; attempt++) {
        const shares = (await api("GET", "/v1/share/shares")).json.shares;
        counts = shares.find((s) => s.id === load.id).stats;
        if (counts.plays === listeners && counts.listeners === listeners && counts.listened30s === listeners) break;
        await new Promise((r) => setTimeout(r, 100));
      }
      // Preserve receipts and CSP evidence before assertions, including a partial load failure.
      writeFileSync(join(evidence, "load.json"), JSON.stringify({ engine, listeners, physicalOutputMuted: true,
        minimumPlaybackSeconds: 30, elapsedMs: Date.now() - started, stats: counts }, null, 2));
      writeFileSync(join(evidence, "load-browser-errors.json"), JSON.stringify(problems, null, 2));
      writeFileSync(join(evidence, "load-decoder-errors.json"), JSON.stringify(decoder, null, 2));
      assert.equal(counts.fetches, listeners);
      assert.equal(counts.opens, listeners);
      assert.equal(counts.plays, listeners);
      assert.equal(counts.listeners, listeners);
      assert.equal(counts.listened30s, listeners);
      assert.equal(passed, listeners, "every concurrent listener's real media clock reaches 30 seconds");
      await screenshot(pages[0], join(evidence, "12-load-playing.png"));
      console.log(`    ${listeners}/${listeners} playing; counts ${JSON.stringify(counts)}`);
    } finally {
      await Promise.all(contexts.map((ctx) => ctx.close()));
    }
  }

  // ---------- A book's chapters (AAC) on both players, TBX-1000000132 ----------

  if (publicOnly) skips.push("book chapters: no book fixtures against a public service");
  else {
    const skipped = await verifyBookChapters({ browser, base, api, evidence, work, step, screenshot, monitor, problems });
    if (skipped) { skips.push(skipped); step(`SKIP ${skipped}`); }
  }

  // ---------- The mixtape page (/m/), TBX-1000000067 ----------

  if (publicOnly) skips.push("mixtape page: no mixtape fixtures against a public service");
  else {
    const skipped = await verifyMixtapePage({ browser, context, base, direct, api, evidence, dataDir, external, step, screenshot, monitor, problems });
    if (skipped) { skips.push(skipped); step(`SKIP ${skipped}`); }
  }

  // ---------- The whole-book page (/b/), TBX-1000000132 ----------

  if (publicOnly) skips.push("book page: no book fixtures against a public service");
  else {
    const skipped = await verifyBookPage({ browser, base, direct, api, evidence, dataDir, external, work, step, screenshot, monitor, problems,
      activate: (bookPage) => { activePage = bookPage; } });
    if (skipped) { skips.push(skipped); step(`SKIP ${skipped}`); }
  }
  }
  assert.deepEqual(problems, [], "no unexpected browser errors");
  // Revoke every remaining fixture, including public runs, leaving tombstones only.
  for (const fixtureShare of (await api("GET", "/v1/share/shares")).json.shares) {
    assert.equal((await api("DELETE", `/v1/share/shares/${fixtureShare.id}`)).status, 204);
  }
  assert.deepEqual(problems, [], "strict behavior verification passed before WebKit screenshot injection");
  const screenshotErrors = [...mediaErrorScreenshotErrors];
  if (engine === "webkit") {
    step("behavior passed with zero CSP errors; capturing final WebKit page states separately");
    let index = 0;
    for (const snapshotPage of new Set(deferredScreenshots)) {
      if (!snapshotPage.isClosed()) {
        await snapshotPage.screenshot({ path: join(evidence, `webkit-final-state-${++index}.png`) });
      }
    }
    screenshotErrors.push(...problems);
  }
  writeFileSync(join(evidence, "result.json"), JSON.stringify({ engine, viaNginx, publicOnly, listeners, mediaErrorsOnly, startupOnly, bookOnly, passed: true,
    appErrors: 0, screenshotErrors,
    skips: [...(external ? ["local deadline acceleration"] : []), ...(publicOnly ? ["internal admin aggregate report"] : []), ...skips] }, null, 2));

  await browser.close();
  console.log(`PASS — screenshots in ${evidence}`);
} catch (error) {
  failed = true;
  if (activePage && !activePage.isClosed()) {
    try {
      await Promise.race([screenshot(activePage, join(evidence, "failure.png")), new Promise((r) => setTimeout(r, 5000))]);
      // The page in use when it failed (the song, mixtape or book page); never its fragment.
      const state = await Promise.race([new Promise((_, reject) => setTimeout(() => reject(new Error("state capture timed out")), 5000)), activePage.evaluate(() => ({ path: location.pathname, readyState: document.readyState, state: document.body?.dataset.state,
        playing: document.body.classList.contains("is-playing"), elapsed: document.getElementById("elapsed")?.textContent,
        status: document.getElementById("status")?.textContent, afterHidden: document.getElementById("after")?.hidden,
        visibility: document.visibilityState })) ]);
      writeFileSync(join(evidence, "failure-state.json"), JSON.stringify(state, null, 2));
      console.error(`browser state: ${JSON.stringify(state)}`);
    } catch {}
  }
  console.error(`FAIL: ${error.stack ?? error}`);
  console.error(`--- server log ---\n${serverLog}`);
} finally {
  await browser?.close();
  await browserServer?.close();
  if (publicOnly) {
    for (const id of mintedIDs) {
      try {
        const response = await fetch(`${base}/v1/share/shares/${id}`, { method: "DELETE",
          headers: { Authorization: `Bearer ${secret}` }, signal: AbortSignal.timeout(5000) });
        if (response.status !== 204) { failed = true; console.error("synthetic fixture cleanup failed"); }
      } catch { failed = true; console.error("synthetic fixture cleanup failed"); }
    }
  }
  server?.kill();
  if (dockerNginx) {
    try { execFileSync("docker", ["stop", "-t", "2", dockerName], { stdio: "ignore" }); } catch {}
    try { execFileSync("docker", ["network", "rm", dockerName], { stdio: "ignore" }); } catch {}
  } else nginx?.kill();
  // The service and nginx logs (paths and timings, never a fragment), including what nginx wrote
  // while the browser closed, after a failure was already reported.
  if (process.env.SHARE_E2E_NGINX_LOG === "1") {
    if (nginx && nginx.exitCode === null) await Promise.race([new Promise((r) => nginx.once("exit", r)), new Promise((r) => setTimeout(r, 3000))]);
    writeFileSync(join(evidence, "server.log"), serverLog);
  }
  rmSync(work, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
