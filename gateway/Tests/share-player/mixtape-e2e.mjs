// Local-only real browser/real MP3 acceptance. Never contacts owner apps or external services.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createRequire } from "node:module";
import { verifyMixtapeTimeouts } from "./mixtape-timeouts.mjs";
const require = createRequire(import.meta.url);
let playwright;
const binary = resolve(process.argv[2]);
const evidence = resolve(process.argv[3]);
const python = process.argv[4] ?? "python3";
const engine = process.argv[5] ?? "chromium";
const safetyOnly = ["safety", "fragment", "restore"].includes(process.argv[6]);
const restoreOnly = process.argv[6] === "restore";
const timeoutOnly = process.argv[6] === "timeouts";
const disposalOnly = process.argv[6] === "dispose";
const fragmentOnly = process.argv[6] === "fragment";
assert.ok(["chromium", "webkit"].includes(engine));
assert.ok(evidence.startsWith("/private/tmp/")); mkdirSync(evidence, { recursive: true });
const work = mkdtempSync("/private/tmp/baton-mixtape-browser-"); chmodSync(work, 0o700);
const port = 19000 + Math.floor(Math.random() * 1000), base = `http://127.0.0.1:${port}`;
const serviceRoot = join(work, "service");
let server, material, owner;
const materialRoot = join(work, "material");
let stage = "fixture spawn", activeCheck = null;
const receipt = { engine, checks: [], errors: [], physicalSafariQualified: false, cellularQualified: false, servedEdgeQualified: false };
let browser, page;
const pause = ms => new Promise(r => setTimeout(r, ms));
async function api(path, method = "GET", body) {
  const response = await fetch(base + path, { method, headers: { Authorization: `Bearer ${owner}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  assert.ok(response.ok, `fixture API ${method} failed HTTP${response.status}`);
  return response.status === 204 ? null : response.json();
}
async function check(name, fn) { activeCheck=name; await fn(); receipt.checks.push({ name, outcome: "PASS" }); activeCheck=null; console.log(`PASS ${name}`); }
try {
  server = spawn(binary, [serviceRoot, String(port)], { stdio: ["ignore", "ignore", "ignore"] });
  let spawnFailed=false; server.once("error",()=>{spawnFailed=true;});
  receipt.ownedPID = server.pid ?? null; receipt.ownedPort = port;
  stage = "material generation";
  execFileSync(python, [new URL("./make-mixtape-media.py", import.meta.url).pathname, materialRoot], { stdio: "ignore" });
  stage = "material parsing";
  material = JSON.parse(readFileSync(join(materialRoot, "material.json")));
  owner = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
  stage = "Playwright loading";
  playwright = require(process.env.SHARE_E2E_PLAYWRIGHT ?? "playwright");
  stage = "fixture readiness";
  for (let i = 0; i < 100; ++i) {
    if (spawnFailed || server.exitCode !== null) throw new Error("fixture exited before readiness");
    try { if ((await fetch(base + "/health")).ok) break; } catch {}
    if (i === 99) throw new Error("fixture readiness deadline");
    await pause(100);
  }
  await check("fixture local-only refusal and advertised capability", async () => {
    const refusal = spawn(binary, [serviceRoot, String(port + 1)], { stdio: "ignore" });
    assert.equal(await new Promise(resolve => refusal.on("exit", resolve)), 64);
    assert.equal((await api("/v1/share/config")).mixtapes, 1);
  });
  const created = await api("/v1/share/mixtapes", "POST", { schema: "baton-mixtape-1", requestID: crypto.randomUUID(), encryptedManifest: material.encryptedManifest,
    tracks: material.tracks, totalDurationSeconds: 36, expiresInSeconds: 86400, playCap: timeoutOnly ? 12 : 2, client: { platform: "macos", appVersion: "synthetic" } });
  assert.equal(created.url, `${base}/m/${created.id}`);
  for (const [id, encrypted] of Object.entries(material.blobs)) {
    assert.equal(created.uploads[id], `/v1/share/mixtapes/${created.id}/tracks/${id}`);
    const response = await fetch(base + created.uploads[id], { method: "PUT", headers: { Authorization: `Bearer ${owner}` }, body: Buffer.from(encrypted, "base64") });
    assert.equal(response.status, 200);
  }
  await api(`/v1/share/mixtapes/${created.id}/finalize`, "POST");
  const url = created.url + "#" + material.rootKey;
  writeFileSync(join(work, "invitation.json"), JSON.stringify({ schema:"baton-mixtape-local-fixture-1", url, publicBase:base,
    dataDirectory:join(serviceRoot,"data"), ownerToken:owner, orderedTracks:material.orderedTracks, playCap:timeoutOnly ? 12 : 2, expiresAt:created.expiresAt,
    fixturePID:server.pid, fixtureRoot:serviceRoot, fixtureLive:true }), {mode:0o600});
  stage = "browser launch";
  browser = await playwright[engine].launch({ headless: true, ...(restoreOnly && engine === "chromium" ? {ignoreDefaultArgs:["--disable-back-forward-cache"],channel:"chromium"} : {}) });
  receipt.browserVersion = browser.version();
  stage = "browser acceptance";
  const context = await browser.newContext();
  page = await context.newPage();
  if (restoreOnly && engine === "chromium") {
    const cdp = await context.newCDPSession(page); await cdp.send("Page.enable");
    cdp.on("Page.backForwardCacheNotUsed", event => { receipt.backForwardCacheNotUsed = event.notRestoredExplanations?.map(e => e.reason); });
  }
  const requests = [], events = [];
  page.on("pageerror", () => receipt.errors.push("script error"));
  await page.addInitScript(() => {
    window.__violations = [];
    window.__pageShows = [];
    addEventListener("pageshow", e => window.__pageShows.push(e.persisted));
    document.addEventListener("securitypolicyviolation", e => window.__violations.push(e.violatedDirective));
    window.__blobLifecycle = { created: 0, revoked: 0, live: 0, peak: 0 };
    const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
    URL.createObjectURL = blob => { const s = window.__blobLifecycle; s.created++; s.live++; s.peak = Math.max(s.peak, s.live); return create(blob); };
    URL.revokeObjectURL = url => { const s = window.__blobLifecycle; s.revoked++; s.live--; return revoke(url); };
  });
  page.on("request", request => {
    const target = new URL(request.url());
    const headers = request.headers();
    requests.push({ path: target.pathname, fragmentLeak: target.hash !== "", foreign: target.origin !== base && target.protocol !== "blob:",
      storageKeyLeak: request.url().includes(material.rootKey) || (request.postData() ?? "").includes(material.rootKey), referrer: Boolean(headers.referer),
      tokenInBody: (request.postData() ?? "").includes('"token"'), auth: Boolean(headers.authorization), method: request.method() });
    if (target.pathname.endsWith("/events")) events.push(JSON.parse(request.postData()).type);
  });
  const sessions = () => requests.filter(r => r.path.endsWith("/sessions")).length;
  const tracks = () => requests.filter(r => /\/tracks\//.test(r.path));
  await check("private page and authenticated ordered list before admission", async () => {
    const response = await fetch(created.url); assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal(response.headers.get("referrer-policy"), "no-referrer");
    const html = await response.text(); assert.ok(!html.includes("synthetic") && !html.includes("encryptedManifest"));
    await page.goto(url); await page.locator("#player").waitFor({ state: "visible" });
    assert.deepEqual(await page.locator("#tracks .row-title").allTextContents(), ["Second synthetic", "First synthetic"]);
    assert.equal(await page.locator("#plays-left").textContent(), `${timeoutOnly ? 12 : 2} plays left`); assert.equal(await page.isVisible("#admission"), false);
    assert.equal(sessions(), 0); assert.equal(tracks().length, 0); assert.equal(new URL(page.url()).hash, "");
  });
  if (disposalOnly) {
    await check("page disposal cancels the owned authenticated analytics request", async () => {
      await verifyMixtapeTimeouts({browser,serviceBase:base,id:created.id,fragment:material.rootKey,receipt,disposalOnly:true});
    });
  } else if (timeoutOnly) {
    await check("absolute 60-second public recipient response deadlines", async () => {
      await verifyMixtapeTimeouts({browser,serviceBase:base,id:created.id,fragment:material.rootKey,receipt});
      const summary=await api(`/v1/share/mixtapes/${created.id}`);
      assert.equal(summary.share.stats.fetches,6);assert.equal(summary.share.stats.plays,0);
    });
  } else if (restoreOnly) {
    await check("real back navigation after in-memory key disposal fails closed", async () => {
      await page.goto(base + "/health"); await page.goBack();
      await page.waitForTimeout(300);
      const shows = await page.evaluate(() => window.__pageShows);
      receipt.backForwardCachePersisted = shows.includes(true);
      assert.equal(await page.locator("#player").isVisible(),false);
      await page.getByText("This link is incomplete. Copy all of it, including the part after #.",{exact:true}).waitFor({timeout:5000});
      assert.equal(sessions(),0); assert.equal(tracks().length,0);
    });
  } else if (!safetyOnly) {
  await check("real clock, pause resume seek reuse one authenticated track", async () => {
    await page.locator("#play").click();
    await page.waitForFunction(() => document.getElementById("audio").currentTime > 2);
    await page.locator("#play").click();
    const time = await page.locator("#audio").evaluate(a => a.currentTime); await pause(300);
    assert.equal(await page.locator("#audio").evaluate(a => a.paused), true);
    assert.ok(Math.abs(await page.locator("#audio").evaluate(a => a.currentTime) - time) < .1);
    await page.locator("#seek").press("Home"); await page.locator("#seek").press("ArrowRight"); await page.locator("#play").click();
    await page.waitForFunction(() => !document.getElementById("audio").paused && document.getElementById("audio").currentTime > 2.5);
    assert.equal(sessions(), 1); assert.equal(tracks().length, 1); assert.equal(tracks()[0].auth, true);
  });
  await check("automatic authenticated order and container listening analytics", async () => {
    await page.waitForFunction(() => document.getElementById("current").textContent === "First synthetic", { timeout: 22000 });
    await page.waitForFunction(() => document.getElementById("audio").currentTime > 15, { timeout: 20000 });
    assert.equal(tracks().length, 2); assert.equal(sessions(), 1);
    assert.ok(tracks()[0].path.endsWith("/ICEiIyQlJicoKSorLC0uLw"));
    assert.ok(tracks()[1].path.endsWith("/EBESExQVFhcYGRobHB0eHw"));
    await page.waitForFunction(() => document.getElementById("status").textContent.includes("end of the mixtape"), { timeout: 8000 });
    await pause(200);
    assert.ok(events.includes("play_started") && events.includes("play_30s") && events.includes("play_completed"));
    await page.getByRole("button", { name: "React ❤️", exact: true }).click();
    await page.getByText("Reaction sent.", { exact: true }).waitFor();
    const summary = await api(`/v1/share/mixtapes/${created.id}`);
    assert.equal(summary.share.stats.fetches, 1); assert.equal(summary.share.stats.plays, 1);
    assert.equal(summary.share.stats.listened30s, 1); assert.equal(summary.share.stats.completed, 1);
    assert.equal(summary.share.reactions[0].emoji, "❤️");
  });
  await check("spent transfer budget requires confirmation and cancel spends nothing", async () => {
    await page.locator("#previous").click(); await page.locator("#admission").waitFor({ state: "visible" });
    assert.equal(await page.locator("#admission-text").textContent(), "Start a new listen? It uses your last play.");
    assert.equal(sessions(), 1); assert.equal(tracks().length, 2);
    await page.locator("#cancel").click(); assert.equal(sessions(), 1);
    await page.locator("#previous").click(); await page.locator("#confirm").click();
    // The card names the selected track at once; the Pause state means its own audio is playing.
    await page.waitForFunction(() => document.getElementById("current").textContent === "Second synthetic" && document.getElementById("play").dataset.mode === "pause" && document.getElementById("audio").currentTime > 1);
    assert.equal(sessions(), 2); assert.equal(tracks().length, 3); assert.equal(await page.locator("#plays-left").textContent(), "No plays left");
    const blobs = await page.evaluate(() => window.__blobLifecycle);
    assert.equal(blobs.peak, 1); assert.equal(blobs.live, 1); assert.equal(blobs.revoked, 2);
    receipt.blobLifecycle = blobs;
  });
  await check("expired session response never silently readmits and exhausted cap stays explicit", async () => {
    await page.route(`**/v1/share/m/${created.id}/tracks/EBESExQVFhcYGRobHB0eHw`, route => route.fulfill({ status: 401, contentType: "application/json", body: '{"code":"session"}' }));
    await page.locator("#next").click(); await page.locator("#admission").waitFor({ state: "visible" });
    assert.equal(sessions(), 2);
    await page.locator("#confirm").click(); await page.getByText("No new listening sessions remain. Ask the sender for a fresh link.", { exact: true }).waitFor();
    assert.equal(sessions(), 3); assert.equal((await api(`/v1/share/mixtapes/${created.id}`)).share.stats.fetches, 2);
  });
  await check("missing and wrong keys refuse before admission; memory credentials and CSP stay private", async () => {
    const missing = await context.newPage(); await missing.goto(created.url);
    await missing.getByText("This link is incomplete. Copy all of it, including the part after #.", { exact: true }).waitFor();
    const wrong = await context.newPage(); await wrong.goto(created.url + "#" + Buffer.alloc(16, 1).toString("base64url"));
    await wrong.getByText("This mixtape could not be authenticated. Ask the sender for a fresh link.", { exact: true }).waitFor();
    assert.equal((await api(`/v1/share/mixtapes/${created.id}`)).share.stats.fetches, 2);
    assert.equal(await page.evaluate(() => localStorage.length + sessionStorage.length), 0);
    assert.deepEqual(await context.cookies(), []);
    assert.ok(requests.every(r => !r.fragmentLeak && !r.storageKeyLeak && !r.tokenInBody && !r.referrer && !r.foreign));
    assert.deepEqual(await page.evaluate(() => window.__violations), []); assert.deepEqual(receipt.errors, []);
    receipt.requestCount = requests.length; receipt.eventTypes = events;
    await missing.close(); await wrong.close();
  });
  } else {
    await check("desktop and mobile player layout", async () => {
      await page.screenshot({path:join(evidence,"desktop-player.png")});
      await page.setViewportSize({width:375,height:812});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await page.screenshot({path:join(evidence,"mobile-player.png")});
    });
    await check("same-document changed fragment reauthenticates instead of retaining prior invitation", async () => {
      await page.goto(created.url + "#" + Buffer.alloc(16,1).toString("base64url"));
      await page.getByText("This mixtape could not be authenticated. Ask the sender for a fresh link.",{exact:true}).waitFor({timeout:5000});
      assert.equal(sessions(),0); assert.equal(tracks().length,0);
    });
    if (!fragmentOnly) {
    await check("altered public descriptors reject before admission or track fetch", async () => {
      await page.route(`**/v1/share/m/${created.id}`, async route => {
        const response = await route.fetch(), details = await response.json();
        details.tracks[Object.keys(details.tracks)[0]].audioBytes++;
        await route.fulfill({response,json:details});
      });
      await page.goto(url); await page.getByText("This mixtape could not be authenticated. Ask the sender for a fresh link.", {exact:true}).waitFor();
      assert.equal(sessions(),0); assert.equal(tracks().length,0);
      await page.unroute(`**/v1/share/m/${created.id}`);
    });
    await check("complete ciphertext authentication fails before any playable plaintext", async () => {
      await page.route(`**/v1/share/m/${created.id}/tracks/ICEiIyQlJicoKSorLC0uLw`, route => {
        const encrypted = Buffer.from(material.blobs["ICEiIyQlJicoKSorLC0uLw"],"base64"); encrypted[encrypted.length-1] ^= 1;
        return route.fulfill({status:200,contentType:"application/octet-stream",body:encrypted});
      });
      await page.goto(url); await page.locator("#player").waitFor({state:"visible"}); await page.locator("#play").click();
      await page.getByText("This track could not be authenticated. Ask the sender for a fresh link.",{exact:true}).waitFor();
      assert.equal(sessions(),1); assert.equal(tracks().length,1);
      assert.equal(await page.locator("#audio").evaluate(a => a.currentTime),0);
      assert.equal(await page.evaluate(() => window.__blobLifecycle.created),0);
      assert.equal((await api(`/v1/share/mixtapes/${created.id}`)).share.stats.plays,0);
      assert.deepEqual(await page.evaluate(() => window.__violations),[]); assert.deepEqual(receipt.errors,[]);
    });
  }
    }
  receipt.outcome = "PASS";
} catch {
  receipt.outcome = "FAIL"; receipt.failedAfter = receipt.checks.length; receipt.failureStage=stage; receipt.failedCheck=activeCheck;
  if (page) receipt.state = await page.evaluate(() => ({state:document.body.dataset.state,status:document.getElementById("status")?.textContent,current:document.getElementById("current")?.textContent,elapsed:document.getElementById("elapsed")?.textContent})).catch(() => null);
  process.exitCode = 1;
} finally {
  receipt.mode = disposalOnly ? "public owned-request disposal" : timeoutOnly ? "actual 60-second resource deadlines" : restoreOnly ? "real back navigation" : safetyOnly ? "focused safety/layout" : "ordered media";
  receipt.counts = { executed: receipt.checks.length + (receipt.outcome === "FAIL" && activeCheck ? 1 : 0), passed: receipt.checks.length, failed: receipt.outcome === "FAIL" && activeCheck ? 1 : 0, skipped: 0 };
  receipt.fixturePath = join(work, "invitation.json"); // private local path only, no invitation payload
  if (page && engine !== "webkit") await page.screenshot({ path: join(evidence, "final.png") }).catch(() => {});
  await browser?.close().catch(() => {});
  if (server?.pid && server.exitCode === null && server.signalCode === null) {
    const exited = new Promise(resolve => server.once("exit", resolve));
    server.kill("SIGTERM"); await exited;
  }
  receipt.ownedServiceExited = !server?.pid || server.exitCode !== null || server.signalCode !== null;
  const invitationPath = join(work,"invitation.json");
  try {
    const invitation = JSON.parse(readFileSync(invitationPath)); invitation.fixtureLive=false;
    writeFileSync(invitationPath, JSON.stringify(invitation), {mode:0o600});
  } catch {}
  writeFileSync(join(evidence, "result.json"), JSON.stringify(receipt, null, 2) + "\n");
  console.log(`${receipt.outcome}: ${receipt.counts.passed}/${receipt.counts.executed}; ${receipt.counts.skipped} skipped`);
}
