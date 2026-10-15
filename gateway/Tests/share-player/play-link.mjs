#!/usr/bin/env node
// Drives an app-created LOCAL fixture. Input is a mode-0600 file containing its link,
// or JSON { "url": "..." }. Never prints the URL, fragment key, or request payloads.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const [input, output, engine = "chromium"] = process.argv.slice(2);
assert.ok(input && output, "Usage: play-link.mjs link-file evidence-dir [chromium|firefox|webkit]");
assert.equal(statSync(input).mode & 0o777, 0o600, "link input must be mode 0600");
const raw = readFileSync(input, "utf8").trim();
let config;
try { config = raw.startsWith("{") ? JSON.parse(raw) : { url: raw }; }
catch { console.error("Invalid link input JSON (contents withheld)"); process.exit(1); }
const link = config.url;
let url;
try { url = new URL(link); }
catch { console.error("Invalid link input URL (contents withheld)"); process.exit(1); }
const redact = (text) => String(text).replaceAll(link, "[redacted link]").replaceAll(url.hash, "[redacted fragment]")
  .replace(/https?:\/\/[^\s'"<>]+/g, "[redacted URL]");
assert.ok(["localhost", "127.0.0.1", "[::1]"].includes(url.hostname), "only synthetic localhost links are allowed");
assert.match(url.pathname, /^\/s\/[A-Za-z0-9_-]+$/);
assert.ok(url.hash.length > 1, "the complete fragment key is required");
assert.ok(["chromium", "firefox", "webkit"].includes(engine));
const require = createRequire(import.meta.url);
const playwright = require(process.env.SHARE_E2E_PLAYWRIGHT ?? "playwright");
const evidence = resolve(output);
mkdirSync(evidence, { recursive: true });
let browser;
let stage = "launch";
let errors = 0;
const browserErrors = [];
const beacons = [];
const snapshotErrors = [];
let actualPlaybackSeconds = 0;
let eventRequestCount = 0;
let acceptedEventRequests = 0;
let unavailableBeaconBodies = 0;
let receivedEvents = null;
try {
  browser = await playwright[engine].launch({
    ...(engine === "chromium" ? { args: ["--autoplay-policy=user-gesture-required"] } : {}),
    ...(process.env.SHARE_E2E_BROWSER_PATH ? { executablePath: process.env.SHARE_E2E_BROWSER_PATH } : {}),
  });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, colorScheme: "dark" });
  let capturingArtifacts = false;
  const rememberError = (message) => {
    if (capturingArtifacts) snapshotErrors.push(message);
    else { errors++; browserErrors.push(message); }
  };
  page.on("pageerror", (error) => rememberError(error.message));
  page.on("console", (message) => { if (message.type() === "error") rememberError(message.text()); });
  page.on("request", (request) => {
    if (request.url().endsWith("/events")) {
      eventRequestCount++;
      const body = request.postData();
      if (body === null) unavailableBeaconBodies++;
      else {
        try {
          const type = JSON.parse(body).type;
          if (typeof type === "string") beacons.push(type);
          else errors++;
        } catch { errors++; }
      }
    }
  });
  page.on("response", (response) => {
    if (response.url().endsWith("/events") && response.status() === 204) acceptedEventRequests++;
  });
  stage = "ready";
  await page.goto(link);
  await page.waitForSelector("#player:not([hidden])", { timeout: 20000 });
  stage = "play";
  await page.click("#play");
  await page.waitForSelector("body.is-playing", { timeout: 20000 });
  await page.waitForFunction(() => document.getElementById("elapsed").textContent !== "0:00", null, { timeout: 10000 });
  stage = "listen";
  await page.waitForFunction(() => {
    const parts = document.getElementById("elapsed").textContent.split(":").map(Number);
    return parts[0] * 60 + parts[1] >= 31;
  }, null, { timeout: 45000 });
  await page.waitForSelector("#after:not([hidden])");
  actualPlaybackSeconds = await page.evaluate(() => {
    const [minutes, seconds] = document.getElementById("elapsed").textContent.split(":").map(Number);
    return minutes * 60 + seconds;
  });
  stage = "reaction";
  await page.click('#reactions button[aria-label="React with ❤️"]');
  await page.fill("#reply-name", "Synthetic Listener");
  await page.fill("#reply-text", "Local end-to-end fixture heard");
  await page.click("#send");
  await page.waitForSelector("#sent:not([hidden])");
  stage = "assertions";
  assert.equal(errors, 0, "no browser errors or CSP violations");
  if (config.dataDirectory) {
    const data = realpathSync(config.dataDirectory);
    assert.ok(["/private/tmp", realpathSync(tmpdir())].some((root) => data.startsWith(root + "/")), "SQLite evidence is synthetic temporary data only");
    const db = realpathSync(join(data, "share.sqlite"));
    assert.ok(["/private/tmp", realpathSync(tmpdir())].some((root) => db.startsWith(root + "/")), "database symlinks cannot escape temporary fixtures");
    for (let attempt = 0; attempt < 50; attempt++) {
      receivedEvents = JSON.parse(execFileSync("python3", ["-c",
        "import sqlite3,sys,json,urllib.parse; c=sqlite3.connect('file:'+urllib.parse.quote(sys.argv[1])+'?mode=ro',uri=True); print(json.dumps(dict(c.execute('SELECT type,COUNT(*) FROM events WHERE share_id=? GROUP BY type',(sys.argv[2],)))))",
        db, url.pathname.split("/").at(-1)], { encoding: "utf8" }));
      if (receivedEvents.play_started >= 1 && receivedEvents.play_30s >= 1 && receivedEvents.reaction_sent >= 1) break;
      await page.waitForTimeout(100);
    }
    assert.ok(receivedEvents.play_started >= 1, "service received play-start beacon");
    assert.ok(receivedEvents.play_30s >= 1, "service received 30-second beacon");
    assert.ok(receivedEvents.reaction_sent >= 1, "service stored reaction");
  } else {
    // Blob sendBeacon bodies are not always exposed by Playwright. Preserve this
    // observation honestly; the caller must check owner/server counters separately.
    for (let attempt = 0; attempt < 50 && acceptedEventRequests < 2; attempt++) await page.waitForTimeout(100);
    assert.ok(acceptedEventRequests >= 2, "at least two event requests accepted by the service");
  }
  // Capture only after strict behavior checks. WebKit's screenshot preparation
  // injects <style>body {}</style> and can violate CSP itself; record it separately.
  stage = "artifacts";
  capturingArtifacts = true;
  await page.screenshot({ path: join(evidence, "3-reaction-sent.png") });
  capturingArtifacts = false;
  const result = { passed: true, engine, errors, beacons, actualPlaybackSeconds, reactionSent: true, snapshotErrors: snapshotErrors.map(redact),
    eventRequestCount, acceptedEventRequests, unavailableBeaconBodies, receivedEvents,
    beaconVerification: receivedEvents ? "service SQLite events" : "HTTP acknowledgements; caller must verify counters" };
  writeFileSync(join(evidence, "result.json"), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result));
} catch (error) {
  // Playwright errors can embed the full navigation URL. Never publish it.
  const result = { passed: false, engine, stage, errors, beacons, actualPlaybackSeconds,
    eventRequestCount, acceptedEventRequests, unavailableBeaconBodies, receivedEvents,
    error: { name: error.name, message: redact(error.message) }, browserErrors: browserErrors.map(redact), snapshotErrors: snapshotErrors.map(redact) };
  writeFileSync(join(evidence, "result.json"), JSON.stringify(result, null, 2));
  console.error(JSON.stringify(result));
  process.exitCode = 1;
} finally {
  await browser?.close();
}
