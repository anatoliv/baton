// The browser half of the album and playlist format check (baton-collection-1,
// specs/collection-sharing.md): the player's own module on Node's WebCrypto, against the
// "collection" vectors the Swift kit is also checked against (ShareCollectionVectorTests), both
// written by make_vectors.py.
//
//   node --test gateway/Tests/share-player/share-collection-crypto.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { base64Decode, base64UrlDecode, open, seal, ShareCryptoError } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";
import { authenticateBook, BOOK_SCHEMA, chapterKey, COLLECTION_KINDS, COLLECTION_SCHEMA, COVER, LABELS, LIMITS, manifestKey, openChapter, openManifest }
  from "../../Sources/BatonShareServer/Web/share-book-crypto.mjs";

const collection = JSON.parse(readFileSync(fileURLToPath(new URL("../../../specs/share-crypto/vectors.json", import.meta.url)), "utf8")).collection;
const hex = h => Uint8Array.from(h.match(/../g).map(b => parseInt(b, 16)));
const sha256 = async bytes => Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
const key = (kind, root, trackID) => kind === "manifest" ? manifestKey(root) : chapterKey(root, trackID);
const albumVector = collection.positive.find(v => v.name === "album manifest");
const playlistVector = collection.positive.find(v => v.name === "playlist manifest");
const root = base64UrlDecode(albumVector.rootKey);
const descriptors = opened => Object.fromEntries(opened.chapters.map(c => [c.id, { role: "audio", bytes: c.audioBytes, sha256: c.audioSHA256 }]));

test("labels, kinds, limits and counts match the vector file", () => {
  assert.equal(collection.format, COLLECTION_SCHEMA);
  assert.deepEqual(collection.kinds, COLLECTION_KINDS);
  assert.deepEqual(collection.labels, { manifest: LABELS.manifest, track: LABELS.chapter });
  assert.deepEqual(collection.limits, { maxTracks: LIMITS.maxChapters, maxTrackAudioBytes: LIMITS.maxChapterAudioBytes,
    maxCollectionBytes: LIMITS.maxBookBytes, maxEncryptedManifestBytes: LIMITS.maxEncryptedManifestBytes,
    maxTrackSeconds: LIMITS.maxChapterSeconds, maxCollectionSeconds: LIMITS.maxBookSeconds,
    maxCoverBytes: COVER.maxBytes, maxTrackNumber: COVER.maxTrackNumber });
  assert.equal(collection.positive.filter(v => v.kind === "manifest").length, 2);
  assert.equal(collection.positive.filter(v => v.kind === "track").length, 3);
  assert.ok(collection.negative.length >= 9, "the vector file lost negatives");
  assert.ok(collection.invalidManifests.length >= 30, "the vector file lost invalid manifests");
});

for (const v of collection.positive) {
  test(`collection positive: ${v.name}`, async () => {
    const r = base64UrlDecode(v.rootKey);
    const derived = await key(v.kind, r, v.trackID);
    assert.deepEqual(derived, base64UrlDecode(v.derivedKey));
    const sealed = await seal(base64Decode(v.plaintext), derived, v.purpose, v.recordSize, hex(v.baseNonce));
    assert.equal(Buffer.from(sealed).toString("base64"), v.ciphertext, "seal must reproduce the vector");
    assert.equal(await sha256(sealed), v.ciphertextSHA256);
    assert.deepEqual(await open(sealed, derived, v.purpose), base64Decode(v.plaintext));
  });
}

for (const v of collection.negative) {
  test(`collection negative: ${v.name}`, async () => {
    assert.equal(v.reason, "auth");
    const derived = await key(v.kind, base64UrlDecode(v.rootKey), v.trackID);
    await assert.rejects(open(base64Decode(v.ciphertext), derived, v.kind === "track" ? "audio" : "meta"), error => {
      assert.ok(error instanceof ShareCryptoError, `${error}`);
      assert.equal(error.reason, "auth", v.name);
      return true;
    });
  });
}

for (const v of collection.invalidManifests) {
  test(`collection invalid manifest: ${v.name}`, async () => {
    const r = base64UrlDecode(v.rootKey), encrypted = base64Decode(v.ciphertext);
    await open(encrypted, await manifestKey(r), "meta"); // it decrypts
    await assert.rejects(openManifest(encrypted, r), error => {
      assert.ok(error instanceof ShareCryptoError, `${error}`);
      assert.equal(error.reason, "format", v.name);
      return true;
    });
  });
}

test("the album opens with its cover, authenticates its descriptors and plays its tracks", async () => {
  const opened = await openManifest(base64Decode(albumVector.ciphertext), root);
  const details = { schema: COLLECTION_SCHEMA, kind: "album", encryptedManifest: albumVector.ciphertext, blobs: descriptors(opened) };
  const album = await authenticateBook(details, root);
  assert.equal(album.kind, "album");
  assert.equal(album.title, "A Long Album");
  assert.equal(album.author, "The Band");
  assert.equal(album.chapters.length, 14);
  assert.deepEqual(album.chapters.map(c => c.trackNumber), Array.from({ length: 14 }, (_, i) => i + 1));
  assert.equal(album.chapters[1].title, "Ça plane pour moi");
  assert.equal(album.chapters[2].artist, "Guest Player");
  assert.equal(album.chapters[0].artist, null);
  assert.equal(album.cover.type, "image/png");
  assert.deepEqual([...album.cover.bytes.slice(0, 4)], [0x89, 0x50, 0x4e, 0x47]);
  const tracks = collection.positive.filter(v => v.kind === "track");
  assert.deepEqual(album.chapters.slice(0, 3).map(c => c.id), tracks.map(v => v.trackID));
  for (const [i, v] of tracks.entries()) {
    assert.deepEqual(await openChapter(base64Decode(v.ciphertext), root, album.chapters[i]), base64Decode(v.plaintext));
  }
  await assert.rejects(openChapter(base64Decode(tracks[1].ciphertext), root, album.chapters[0]));

  // The descriptor's schema and kind must agree with the authenticated manifest.
  await assert.rejects(authenticateBook({ ...details, kind: "playlist" }, root));
  await assert.rejects(authenticateBook({ ...details, kind: undefined }, root));
  await assert.rejects(authenticateBook({ ...details, schema: BOOK_SCHEMA, kind: undefined }, root));
  await assert.rejects(authenticateBook({ ...details, kind: "book" }, root));
  const extra = { ...details.blobs, AAAAAAAAAAAAAAAAAAAAAA: { role: "text", bytes: 100, sha256: "0".repeat(64) } };
  await assert.rejects(authenticateBook({ ...details, blobs: extra }, root));
});

test("the playlist opens with per-track artists and albums and no cover", async () => {
  const r = base64UrlDecode(playlistVector.rootKey);
  const opened = await openManifest(base64Decode(playlistVector.ciphertext), r);
  const playlist = await authenticateBook({ schema: COLLECTION_SCHEMA, kind: "playlist", encryptedManifest: playlistVector.ciphertext,
    blobs: descriptors(opened) }, r);
  assert.equal(playlist.kind, "playlist");
  assert.equal(playlist.title, "Road Trip");
  assert.equal(playlist.author, "");
  assert.equal(playlist.cover, null);
  assert.deepEqual(playlist.chapters.map(c => c.artist), ["Ana", "Bo", "Cy"]);
  assert.deepEqual(playlist.chapters.map(c => c.album), ["First", "Second", "Third"]);
});
