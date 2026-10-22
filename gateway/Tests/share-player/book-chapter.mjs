// A book's chapters through the real players (specs/book-sharing.md).
//
// A chapter is AAC in MP4, not the MP3 a song is, and Safari and Firefox go by a Blob's label.
// This walk shares one chapter as a song link and two as a mixtape, the way the apps do, then
// plays each in the browser and requires the decrypted Blob to say audio/mp4 and the real media
// clock to move. Local fixtures only; the key goes in the fragment and nowhere else.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { seal } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";
import { manifestKey, trackKey } from "../../Sources/BatonShareServer/Web/share-mixtape-crypto.mjs";

const b64u = (bytes) => Buffer.from(bytes).toString("base64url");
const sha256 = async (bytes) => Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
const json = { "Content-Type": "application/json" };

/** A chapter as the book renderer writes it: AAC, 48 kbps, mono, in an .m4a. */
function chapter(work, name, frequency, seconds) {
  const path = join(work, `${name}.m4a`);
  execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", `sine=frequency=${frequency}:duration=${seconds}`,
    "-c:a", "aac", "-b:a", "48k", "-ac", "1", "-movflags", "+faststart", path]);
  const bytes = new Uint8Array(readFileSync(path));
  assert.equal(Buffer.from(bytes.subarray(4, 8)).toString("latin1"), "ftyp", "ffmpeg wrote an MP4 chapter");
  return bytes;
}

// Records the type of every Blob the page turns into a URL, so the label is observed, not assumed.
const watchBlobs = () => {
  window.__blobTypes = [];
  const create = URL.createObjectURL;
  URL.createObjectURL = function (object) {
    if (object instanceof Blob) window.__blobTypes.push(object.type);
    return create.call(this, object);
  };
};

export async function verifyBookChapters({ browser, base, api, evidence, work, step, screenshot, monitor, problems }) {
  const results = {};
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "light" });
  context.on("page", monitor);
  await context.addInitScript(watchBlobs);
  try {
    step("book chapter: one AAC chapter as a song link plays in the browser");
    const one = chapter(work, "chapter-1", 300, 12);
    const key = crypto.getRandomValues(new Uint8Array(16));
    const sealed = await seal(one, key, "audio");
    const created = await api("POST", "/v1/share/shares", JSON.stringify({
      expiresInSeconds: 86400, playCap: 10, audioBytes: sealed.length, audioSHA256: await sha256(sealed),
      client: { platform: "macos", appVersion: "e2e" },
      preview: { title: "An Essay", artist: "A. Writer", album: "An Essay", durationSeconds: 12, from: "Anatoli", note: "", peaks: [] },
    }), json);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    const id = created.json.id;
    assert.equal((await api("PUT", created.json.uploads.audio, sealed)).status, 200);
    assert.equal((await api("POST", `/v1/share/shares/${id}/finalize`)).status, 200);
    const page = await context.newPage();
    await page.goto(`${base}/s/${id}#${b64u(key)}`);
    await page.waitForSelector("#player:not([hidden])");
    assert.equal(await page.textContent("#title"), "An Essay");
    await page.click("#play");
    await page.waitForSelector("body.is-playing", { timeout: 20000 });
    await page.waitForFunction(() => document.getElementById("elapsed").textContent !== "0:00", null, { timeout: 10000 });
    results.song = { blobTypes: await page.evaluate(() => window.__blobTypes) };
    assert.ok(results.song.blobTypes.includes("audio/mp4"), `the chapter is labelled audio/mp4: ${results.song.blobTypes}`);
    assert.ok(!results.song.blobTypes.includes("audio/mpeg"), "and not as an MP3");
    await screenshot(page, join(evidence, "book-chapter-song.png"));
    await page.close();
    assert.equal((await api("DELETE", `/v1/share/shares/${id}`)).status, 204);

    const config = await fetch(`${base}/v1/share/config`).then((r) => r.json());
    if (config.mixtapes !== 1) return "book chapters as a mixtape: the service has mixtapes off";

    step("book chapter: two AAC chapters as a mixtape play in order");
    const root = crypto.getRandomValues(new Uint8Array(16));
    const titles = ["Chapter 1: Arrival", "Chapter 2: The House"];
    const tracks = [];
    const blobs = {};
    for (const [i, frequency] of [440, 550].entries()) {
      const plain = chapter(work, `book-${i}`, frequency, 8);
      const id = b64u(crypto.getRandomValues(new Uint8Array(16)));
      const encrypted = await seal(plain, await trackKey(root, id), "audio");
      blobs[id] = encrypted;
      tracks.push({ id, metadata: { title: titles[i], artist: "A. Writer", album: "A Short Book", durationSeconds: 8, from: "", note: "", peaks: [] },
        audioBytes: encrypted.length, audioSHA256: await sha256(encrypted) });
    }
    const manifest = { schema: "baton-mixtape-1", title: "A Short Book", tracks };
    const encryptedManifest = await seal(new TextEncoder().encode(JSON.stringify(manifest)), await manifestKey(root), "meta");
    const tape = await api("POST", "/v1/share/mixtapes", JSON.stringify({ schema: "baton-mixtape-1", requestID: crypto.randomUUID(),
      encryptedManifest: Buffer.from(encryptedManifest).toString("base64"),
      tracks: Object.fromEntries(tracks.map((t) => [t.id, { audioBytes: t.audioBytes, audioSHA256: t.audioSHA256 }])),
      totalDurationSeconds: 16, expiresInSeconds: 86400, playCap: 5, client: { platform: "macos", appVersion: "e2e" } }), json);
    assert.equal(tape.status, 201, JSON.stringify(tape.json));
    for (const [id, encrypted] of Object.entries(blobs)) {
      assert.equal((await api("PUT", tape.json.uploads[id], encrypted)).status, 200);
    }
    assert.equal((await api("POST", `/v1/share/mixtapes/${tape.json.id}/finalize`)).status, 200);
    const book = await context.newPage();
    await book.goto(`${base}/m/${tape.json.id}#${b64u(root)}`);
    await book.locator("#player").waitFor({ state: "visible" });
    assert.equal(await book.locator("#title").textContent(), "A Short Book");
    assert.deepEqual(await book.locator("#tracks .row-title").allTextContents(), titles);
    const playingPast = (seconds) => book.waitForFunction((s) => !document.getElementById("audio").paused
      && document.getElementById("audio").error === null && document.getElementById("audio").currentTime > s, seconds, { timeout: 20000 });
    await book.click("#play");
    await playingPast(1.5);
    await book.click("#next");
    await book.waitForFunction((t) => document.getElementById("current").textContent === t, titles[1]);
    await playingPast(1);
    results.mixtape = { blobTypes: await book.evaluate(() => window.__blobTypes) };
    assert.deepEqual(results.mixtape.blobTypes, ["audio/mp4", "audio/mp4"], "each chapter is labelled audio/mp4");
    await screenshot(book, join(evidence, "book-chapters-mixtape.png"));
    await book.close();
    assert.equal((await api("DELETE", `/v1/share/mixtapes/${tape.json.id}`)).status, 204);
    return null;
  } finally {
    writeFileSync(join(evidence, "book-chapters.json"), JSON.stringify({ ...results, problems }, null, 2));
    await context.close();
  }
}
