import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { base64Decode, base64UrlDecode, open, seal } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";
import { canonicalTrackID, manifestKey, openTrack, trackKey } from "../../Sources/BatonShareServer/Web/share-mixtape-crypto.mjs";

const vectors = JSON.parse(readFileSync(new URL("../../../specs/share-crypto/mixtape-vectors.json", import.meta.url), "utf8"));
const hex = h => Uint8Array.from(h.match(/../g).map(b => parseInt(b, 16)));
test("extension vector counts are preserved", () => {
  assert.equal(vectors.positive.length, 3); assert.equal(vectors.negative.length, 4);
  assert.notEqual(vectors.positive[0].derivedKey, vectors.positive[1].derivedKey);
});
for (const v of vectors.positive) test(`mixtape positive: ${v.name}`, async () => {
  const root = base64UrlDecode(v.rootKey);
  const derived = v.trackID ? await trackKey(root, v.trackID) : await manifestKey(root);
  assert.deepEqual(derived, base64UrlDecode(v.derivedKey));
  const encrypted = await seal(base64Decode(v.plaintext), derived, v.purpose, v.recordSize, hex(v.baseNonce));
  assert.deepEqual(encrypted, base64Decode(v.ciphertext));
  assert.deepEqual(await open(encrypted, derived, v.purpose), base64Decode(v.plaintext));
});
for (const v of vectors.negative) test(`mixtape negative: ${v.name}`, async () => {
  const derived = await trackKey(base64UrlDecode(v.rootKey), v.trackID);
  await assert.rejects(open(base64Decode(v.ciphertext), derived, "audio"));
});
test("IDs are exact and root key size is enforced", async () => {
  assert.ok(canonicalTrackID(vectors.positive[0].trackID));
  for (const id of [null, "", "../secret", vectors.positive[0].trackID + "=", vectors.positive[0].trackID.slice(0, -1) + "x"]) assert.equal(canonicalTrackID(id), null);
  await assert.rejects(trackKey(new Uint8Array(15), vectors.positive[0].trackID));
});
test("authenticated descriptor cannot substitute ciphertext or track identity", async () => {
  const [first, second] = vectors.positive;
  const root = base64UrlDecode(first.rootKey), ciphertext = base64Decode(first.ciphertext);
  const descriptor = { id: first.trackID, audioBytes: ciphertext.length, audioSHA256: first.ciphertextSHA256 };
  assert.deepEqual(await openTrack(ciphertext, root, descriptor), base64Decode(first.plaintext));
  await assert.rejects(openTrack(ciphertext, root, { ...descriptor, id: second.trackID }));
  await assert.rejects(openTrack(ciphertext, root, { ...descriptor, audioSHA256: second.ciphertextSHA256 }));
  await assert.rejects(openTrack(ciphertext.subarray(0, ciphertext.length - 1), root, descriptor));
  await assert.rejects(openTrack(ciphertext, root, { ...descriptor, audioBytes: Number.MAX_SAFE_INTEGER }));
});
