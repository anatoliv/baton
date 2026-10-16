import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { base64UrlDecode } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";
import { authenticateManifest, readBounded } from "../../Sources/BatonShareServer/Web/mixtape-manifest.mjs";
const fixtures = JSON.parse(readFileSync(new URL("./mixtape-manifest-fixtures.json", import.meta.url)));
const root = base64UrlDecode(fixtures.rootKey);
test("independent Python encrypted manifest yields its authenticated reverse order", async () => {
  const manifest = await authenticateManifest(fixtures.valid, root);
  assert.equal(manifest.title, "Independent ordered fixture");
  assert.deepEqual(manifest.tracks.map(t => t.metadata.title), ["Second", "First"]);
  assert.deepEqual(manifest.tracks.map(t => t.id), ["ICEiIyQlJicoKSorLC0uLw", "EBESExQVFhcYGRobHB0eHw"]);
  assert.equal(manifest.audioBytes, 5136); assert.equal(manifest.durationSeconds, 20);
});
test("accepts the twelve-track boundary and preserves authenticated order", async () => {
  const manifest = await authenticateManifest(fixtures.maximum, root);
  assert.equal(manifest.tracks.length, 12); assert.equal(manifest.durationSeconds, 120); assert.equal(manifest.audioBytes, 30816);
  assert.equal(manifest.tracks[0].id, "AQEBAQEBAQEBAQEBAQEBAQ");
  assert.equal(manifest.tracks[11].id, "DAwMDAwMDAwMDAwMDAwMDA");
});
for (const [name, details] of Object.entries(fixtures.invalid)) test(`refuses authenticated invalid manifest: ${name}`, async () => {
  await assert.rejects(authenticateManifest(details, root));
});
test("refuses altered descriptor set, length, hash, root key and encrypted manifest", async () => {
  for (const mutate of [d => delete d.tracks[Object.keys(d.tracks)[0]], d => d.tracks.extra = {},
    d => d.tracks[Object.keys(d.tracks)[0]].audioBytes++, d => d.tracks[Object.keys(d.tracks)[0]].audioSHA256 = "0".repeat(64),
    d => d.encryptedManifest = d.encryptedManifest.slice(0, -8) + "AAAAAAAA", d => d.encryptedManifest = "A".repeat(87388)]) {
    const details = structuredClone(fixtures.valid); mutate(details); await assert.rejects(authenticateManifest(details, root));
  }
  await assert.rejects(authenticateManifest(fixtures.valid, new Uint8Array(16).fill(1)));
});
test("bounded receiving rejects header oversize, streamed oversize, truncation and dishonest exact length", async () => {
  assert.deepEqual([...await readBounded(new Response(Uint8Array.of(1,2)), 2, true)], [1,2]);
  for (const response of [new Response(Uint8Array.of(1,2,3)), new Response(Uint8Array.of(1)),
    new Response(Uint8Array.of(1,2), {headers:{"Content-Length":"3"}}), new Response(Uint8Array.of(1,2), {headers:{"Content-Length":"1"}})]) {
    await assert.rejects(readBounded(response, 2, true));
  }
  await assert.rejects(readBounded(new Response("x".repeat(4097)), 4096));
});
