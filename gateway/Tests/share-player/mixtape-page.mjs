// The mixtape page (/m/) through the same service and nginx as e2e.mjs: the TBX-1000000067 layout,
// the play flow, the session prompt, Previous/Next, reactions and ended links. Local fixtures only.
// Material comes from make-mixtape-media.py (independent Python crypto, ffmpeg MP3s). The key is
// fixed synthetic bytes, never printed, and only ever placed in the URL fragment.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { join } from "node:path";

// WCAG contrast ratio of two computed "rgb(r, g, b)" colors.
function contrast(...colors) {
  const [a, b] = colors.map((color) => {
    const [r, g, bl] = color.match(/\d+(\.\d+)?/g).slice(0, 3).map((v) => { const c = Number(v) / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  });
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

// Returns null when it ran, or the reason it was skipped.
export async function verifyMixtapePage({ browser, context, base, direct, api, evidence, dataDir, external, step, screenshot, monitor, problems }) {
  const config = await fetch(`${base}/v1/share/config`).then((r) => r.json());
  if (config.mixtapes !== 1) return "mixtape page: the service has mixtapes off";
  const python = process.env.SHARE_E2E_PYTHON ?? "python3";
  let material;
  try {
    const root = join(mkdtempSync("/private/tmp/baton-mixtape-page-"), "material");
    execFileSync(python, [new URL("./make-mixtape-media.py", import.meta.url).pathname, root], { stdio: "ignore" });
    material = JSON.parse(readFileSync(join(root, "material.json")));
  } catch {
    return "mixtape page: no synthetic material (needs /private/tmp, ffmpeg and SHARE_E2E_PYTHON with cryptography)";
  }
  const json = { "Content-Type": "application/json" };
  async function mint(playCap) {
    const created = await api("POST", "/v1/share/mixtapes", JSON.stringify({ schema: "baton-mixtape-1", requestID: crypto.randomUUID(),
      encryptedManifest: material.encryptedManifest, tracks: material.tracks, totalDurationSeconds: 36, expiresInSeconds: 86400, playCap,
      client: { platform: "macos", appVersion: "e2e" } }), json);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    for (const [id, encrypted] of Object.entries(material.blobs)) {
      assert.equal((await api("PUT", created.json.uploads[id], Buffer.from(encrypted, "base64"))).status, 200);
    }
    assert.equal((await api("POST", `/v1/share/mixtapes/${created.json.id}/finalize`)).status, 200);
    return { id: created.json.id, link: `${base}/m/${created.json.id}#${material.rootKey}` };
  }
  const summary = async (id) => (await api("GET", `/v1/share/mixtapes/${id}`)).json.share;
  const text = (page, selector) => page.locator(selector).textContent();
  const current = (page) => page.evaluate(() => [...document.querySelectorAll("#tracks .row")].findIndex((row) => row.getAttribute("aria-current") === "true"));
  const audioAfter = (page, seconds) => page.waitForFunction((s) => document.getElementById("play").dataset.mode === "pause"
    && !document.getElementById("audio").paused && document.getElementById("audio").currentTime > s, seconds, { timeout: 20000 });

  step("mixtape page: shell, headers and assets through nginx");
  const tape = await mint(2);
  const shell = await fetch(`${base}/m/${tape.id}`);
  assert.equal(shell.status, 200);
  assert.equal(shell.headers.get("cache-control"), "no-store");
  // One Referrer-Policy, no-referrer: deploy/nginx/default.conf maps ^/m/ like ^/s/, and share-proxy.inc
  // hides the service's own copy so the header is not sent twice (TBX-1000000079).
  assert.equal(shell.headers.get("referrer-policy"), "no-referrer", "one Referrer-Policy, the mixtape page's");
  assert.equal((await fetch(`${base}/m/${tape.id}`.replace(base, direct))).headers.get("referrer-policy"), "no-referrer", "the service says no-referrer");
  assert.equal(shell.headers.get("x-content-type-options"), "nosniff");
  assert.match(shell.headers.get("content-security-policy") ?? "", /default-src 'none'.*connect-src 'self'/);
  const html = await shell.text();
  assert.ok(html.includes('<meta name="referrer" content="no-referrer">'), "the page sets no-referrer for itself");
  for (const secret of ["synthetic", "Fixture", "encryptedManifest", material.rootKey]) assert.ok(!html.includes(secret), `page shell leaks ${secret}`);
  for (const asset of ["mixtape.css", "mixtape.mjs", "icon.svg"]) {
    const response = await fetch(`${base}/m/_/${asset}?v=retired`);
    assert.equal(response.status, 200, asset); assert.equal(response.headers.get("cache-control"), "public, no-cache", asset);
  }
  for (const unknown of [`${base}/m/AAAAAAAAAAAAAAAAAAAAAA`, `${base}/s/AAAAAAAAAAAAAAAAAAAAAA`]) {
    const response = await fetch(unknown);
    assert.equal(response.status, 404, unknown); assert.match(response.headers.get("content-type") ?? "", /text\/html/);
  }

  step("mixtape page: header, chips and track list before any play (phone, dark)");
  const page = await context.newPage();
  await page.goto(tape.link);
  await page.locator("#player").waitFor({ state: "visible" });
  assert.equal(new URL(page.url()).hash, "", "the key leaves the address bar");
  assert.equal(await text(page, ".kicker"), "Baton mixtape");
  assert.equal(await text(page, "#title"), "Ordered synthetic mixtape");
  assert.equal(await text(page, "#byline"), "2 tracks · 36 sec");
  assert.match(await text(page, "#ends"), /^Ends /);
  assert.equal(await text(page, "#plays-left"), "2 plays left");
  assert.deepEqual(await page.locator("#tracks .row-title").allTextContents(), ["Second synthetic", "First synthetic"]);
  assert.deepEqual(await page.locator("#tracks .row-by").allTextContents(), ["Fixture", "Fixture"]);
  assert.deepEqual(await page.locator("#tracks .row-time").allTextContents(), ["0:18", "0:18"]);
  assert.equal(await current(page), -1, "nothing is marked playing before a play");
  assert.equal(await text(page, "#current"), "Second synthetic");
  assert.equal(await text(page, "#current-by"), "Fixture");
  assert.equal(await text(page, "#remaining"), "-0:18");
  // A plain span's aria-label is ignored by most screen readers; the label is visually hidden text.
  assert.equal(await page.getAttribute("#remaining", "aria-label"), null);
  assert.equal(await page.evaluate(() => document.getElementById("remaining").parentElement.textContent), "Time remaining -0:18");
  assert.equal(await page.evaluate(() => document.querySelector(".times .visually-hidden").getBoundingClientRect().width <= 1), true);
  assert.equal(await page.isVisible("#admission"), false, "no session prompt before one is needed");
  assert.equal(await page.isVisible(".disclosure"), false, "the rules paragraph is gone");
  assert.equal(await page.getAttribute("#play", "aria-label"), "Play");
  assert.equal(await page.getAttribute("#previous", "aria-label"), "Previous track");
  assert.equal(await page.getAttribute("#next", "aria-label"), "Next track");
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, "no horizontal scroll at 390 px");
  assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById("card")).position), "sticky", "the phone player sticks");
  assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById("card")).bottom), "0px");
  assert.equal(await page.evaluate(() => getComputedStyle(document.body).backgroundColor), "rgb(48, 52, 58)", "charcoal in dark");
  // WCAG 2.4.3: the card is docked under the list on a phone, and the DOM and Tab order say so too.
  const order = () => page.evaluate(() => [...document.getElementById("player").children].map((node) => node.id).join(","));
  assert.equal(await order(), "tracks,reactions,card", "on a phone the card follows the list in the DOM");
  // WebKit on macOS tabs only to fields and links unless the system's keyboard navigation setting is
  // on, as Safari does, so the Tab key is checked in the other engines; the DOM order holds in all.
  const tabsToButtons = browser.browserType().name() !== "webkit";
  if (tabsToButtons) {
    await page.locator("#tracks .row").last().focus(); await page.keyboard.press("Tab");
    assert.equal(await page.evaluate(() => document.activeElement.id), "play", "Tab goes from the last row to the docked player");
  }
  await page.locator("#tracks .row").last().focus();
  await page.setViewportSize({ width: 1280, height: 860 });
  await page.waitForFunction(() => document.getElementById("player").firstElementChild.id === "card");
  assert.equal(await order(), "card,tracks,reactions", "wide, the card leads in the DOM as it does on screen");
  assert.equal(await page.evaluate(() => document.activeElement === [...document.querySelectorAll("#tracks .row")].at(-1)), true, "focus survives the move");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForFunction(() => document.getElementById("player").lastElementChild.id === "card");
  assert.equal((await summary(tape.id)).stats.fetches, 0, "opening the page spends no play");

  step("mixtape page: Play from the keyboard starts one listening session");
  await page.focus("#play");
  await page.keyboard.press("Enter");
  await audioAfter(page, 1.5);
  assert.equal(await page.getAttribute("#play", "aria-label"), "Pause");
  assert.equal(await current(page), 0);
  assert.equal(await page.locator("#tracks .row").nth(0).locator(".row-speaker").isVisible(), true, "speaker marks the playing row");
  assert.equal(await page.locator("#tracks .row").nth(0).locator(".row-num").isVisible(), false);
  assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector('#tracks .row[aria-current="true"] .row-title')).color),
    "rgb(237, 152, 111)", "copper marks the playing row in dark");
  assert.equal(await text(page, "#plays-left"), "1 play left");
  assert.notEqual(await text(page, "#elapsed"), "0:00");
  assert.ok(parseFloat(await page.evaluate(() => document.getElementById("seek").style.getPropertyValue("--progress"))) > 0, "copper progress moves");
  assert.equal((await summary(tape.id)).stats.fetches, 1);
  await screenshot(page, join(evidence, "mixtape-390-dark-playing.png"));

  step("mixtape page: pause and resume keep the session; the range seeks");
  await page.click("#play");
  await page.waitForFunction(() => document.getElementById("audio").paused);
  assert.equal(await page.getAttribute("#play", "aria-label"), "Play");
  await page.focus("#seek"); await page.keyboard.press("Home");
  await page.waitForFunction(() => document.getElementById("audio").currentTime < .5);
  assert.equal(await text(page, "#elapsed"), "0:00");
  await page.focus("#play"); await page.keyboard.press("Space");
  await audioAfter(page, .8);
  assert.equal((await summary(tape.id)).stats.fetches, 1);

  step("mixtape page: Next plays the second track in the same session");
  await page.click("#next");
  await page.waitForFunction(() => document.getElementById("current").textContent === "First synthetic");
  await audioAfter(page, 1);
  assert.equal(await current(page), 1);
  assert.equal((await summary(tape.id)).stats.fetches, 1);

  step("mixtape page: Previous needs a new listen; Not now spends nothing; Start listening spends one");
  await page.click("#previous");
  await page.locator("#admission").waitFor({ state: "visible" });
  assert.equal(await text(page, "#admission-text"), "Start a new listen? It uses your last play.");
  assert.equal(await page.evaluate(() => document.activeElement.id), "confirm");
  assert.equal(await page.getByRole("button", { name: "Start listening", exact: true }).isVisible(), true);
  await screenshot(page, join(evidence, "mixtape-390-dark-prompt.png"));
  await page.getByRole("button", { name: "Not now", exact: true }).click();
  assert.equal(await page.isVisible("#admission"), false);
  assert.equal((await summary(tape.id)).stats.fetches, 1);
  await page.click("#previous");
  await page.getByRole("button", { name: "Start listening", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("current").textContent === "Second synthetic");
  await audioAfter(page, 1);
  assert.equal(await current(page), 0);
  assert.equal(await text(page, "#plays-left"), "No plays left");
  assert.equal((await summary(tape.id)).stats.fetches, 2);

  step("mixtape page: a reaction reaches the sender");
  await page.getByRole("button", { name: "React ❤️", exact: true }).click();
  await page.getByText("Reaction sent.", { exact: true }).waitFor();
  assert.equal((await summary(tape.id)).reactions[0].emoji, "❤️");
  await page.click("#play");
  await page.waitForFunction(() => document.getElementById("audio").paused);

  step("mixtape page: screenshots at 390 and 1280 px, light and dark");
  const shots = await mint(10);
  for (const [width, height, scheme] of [[390, 844, "light"], [390, 844, "dark"], [1280, 860, "light"], [1280, 860, "dark"]]) {
    const shot = await browser.newPage({ viewport: { width, height }, colorScheme: scheme });
    monitor(shot);
    await shot.goto(shots.link);
    await shot.locator("#player").waitFor({ state: "visible" });
    assert.equal(await shot.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal scroll at ${width}`);
    assert.equal(await shot.evaluate(() => getComputedStyle(document.getElementById("card")).position), width < 641 ? "sticky" : "static");
    assert.equal(await shot.evaluate(() => getComputedStyle(document.body).backgroundColor), scheme === "light" ? "rgb(250, 247, 244)" : "rgb(48, 52, 58)");
    // "Start listening" is 0.9rem text on a copper fill: it needs AA 4.5:1 in both schemes.
    const confirm = await shot.evaluate(() => { const style = getComputedStyle(document.getElementById("confirm")); return [style.color, style.backgroundColor]; });
    assert.ok(contrast(...confirm) >= 4.5, `Start listening contrast ${contrast(...confirm).toFixed(2)}:1 in ${scheme}`);
    if (width > 640 && tabsToButtons) {
      await shot.focus("#next"); await shot.keyboard.press("Tab");
      assert.equal(await shot.evaluate(() => document.activeElement.className), "row", "wide, Tab goes from the player to the first row");
    }
    await shot.click("#play");
    await audioAfter(shot, 1.2);
    await shot.click("#play");
    await shot.waitForFunction(() => document.getElementById("audio").paused);
    await screenshot(shot, join(evidence, `mixtape-${width}-${scheme}.png`));
    await shot.close();
  }

  step("mixtape page: revoking while open, and revoked/expired links, read as ended");
  const open = await context.newPage();
  await open.goto(shots.link);
  await open.locator("#player").waitFor({ state: "visible" });
  assert.equal((await api("DELETE", `/v1/share/mixtapes/${shots.id}`)).status, 204);
  const before = problems.length;
  await open.click("#play");
  await open.waitForFunction(() => document.body.dataset.state === "expired");
  await open.waitForTimeout(200);
  // The refused admission is a deliberate 410 fetch; Chromium logs it as a resource error. Nothing else may appear.
  const logged = problems.splice(before);
  assert.ok(logged.every((line) => /^Failed to load resource: the server responded with a status of 410/.test(line)), JSON.stringify(logged));
  assert.equal(await text(open, "#status"), "This mixtape is unavailable or has ended.");
  assert.equal(await open.isVisible("#player"), false); assert.equal(await open.isVisible("#chips"), false);
  await open.close();
  assert.equal((await api("DELETE", `/v1/share/mixtapes/${tape.id}`)).status, 204);
  const revokedShell = await fetch(`${base}/m/${tape.id}`);
  assert.equal(revokedShell.status, 410);
  const revokedHTML = await revokedShell.text();
  assert.ok(!/revoked/i.test(revokedHTML), "a revoked page never says revoked, page data included");
  assert.match(revokedHTML, /"state":"expired"/);
  const revokedDetails = await fetch(`${base}/v1/share/m/${tape.id}`);
  assert.equal(revokedDetails.status, 410); assert.ok(!/revoked/i.test(await revokedDetails.text()));
  const ended = await context.newPage();
  await ended.goto(tape.link);
  await ended.waitForFunction(() => document.body.dataset.state === "expired");
  assert.equal(await text(ended, "#title"), "This mixtape’s link has expired");
  assert.equal(await ended.isVisible("#player"), false);
  assert.equal(await ended.isVisible(".listen-note"), false);
  await screenshot(ended, join(evidence, "mixtape-390-dark-ended.png"));
  await ended.close();
  if (!external) {
    const expiring = await mint(2);
    execFileSync("python3", ["-c", "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('UPDATE shares SET expires_at=? WHERE id=?',(int(time.time())-1,sys.argv[2])); c.commit()",
      join(dataDir, "share.sqlite"), expiring.id]);
    const expired = await context.newPage();
    await expired.goto(expiring.link);
    await expired.waitForFunction(() => document.body.dataset.state === "expired");
    assert.equal(await expired.isVisible("#player"), false);
    await expired.close();
    assert.equal((await fetch(`${base}/v1/share/m/${expiring.id}`)).status, 410);
  }
  const unknown = await context.newPage();
  await unknown.goto(`${base}/m/AAAAAAAAAAAAAAAAAAAAAA#${material.rootKey}`);
  await unknown.waitForFunction(() => document.body.dataset.state === "unknown");
  assert.equal(await text(unknown, "#title"), "This link doesn’t lead anywhere");
  await screenshot(unknown, join(evidence, "mixtape-390-dark-unknown.png"));
  await unknown.close();
  await page.close();
  assert.deepEqual(problems, [], "no console errors or CSP violations on the mixtape page");
  return null;
}
