// The browser half of the book format check (baton-book-1, specs/book-sharing.md): the player's
// own module on Node's WebCrypto, against the "book" vectors the Swift kit is also checked
// against (ShareBookVectorTests), both written by make_vectors.py.
//
//   node --test gateway/Tests/share-player/share-book-crypto.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { base64Decode, base64UrlDecode, open, seal, ShareCryptoError } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";
import { authenticateBook, BOOK_SCHEMA, canonicalID, chapterKey, LABELS, LIMITS, manifestKey, openChapter, openManifest, openText, textKey }
  from "../../Sources/BatonShareServer/Web/share-book-crypto.mjs";

const book = JSON.parse(readFileSync(fileURLToPath(new URL("../../../specs/share-crypto/vectors.json", import.meta.url)), "utf8")).book;
const hex = h => Uint8Array.from(h.match(/../g).map(b => parseInt(b, 16)));
const sha256 = async bytes => Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
const key = (kind, root, chapterID) => kind === "manifest" ? manifestKey(root) : kind === "chapter" ? chapterKey(root, chapterID) : textKey(root, chapterID);
const manifestVector = book.positive.find(v => v.kind === "manifest");
const root = base64UrlDecode(manifestVector.rootKey);

test("labels, limits and counts match the vector file", () => {
  assert.equal(book.format, BOOK_SCHEMA);
  assert.deepEqual(book.labels, LABELS);
  assert.deepEqual(book.limits, LIMITS);
  assert.equal(book.positive.filter(v => v.kind === "chapter").length, 12);
  assert.equal(book.positive.filter(v => v.kind === "text").length, 1);
  assert.ok(book.negative.length >= 13, "the vector file lost negatives");
  assert.ok(book.invalidManifests.length >= 15, "the vector file lost invalid manifests");
});

for (const v of book.positive) {
  test(`book positive: ${v.name}`, async () => {
    const r = base64UrlDecode(v.rootKey);
    const derived = await key(v.kind, r, v.chapterID);
    assert.deepEqual(derived, base64UrlDecode(v.derivedKey));
    const sealed = await seal(base64Decode(v.plaintext), derived, v.purpose, v.recordSize, hex(v.baseNonce));
    assert.equal(Buffer.from(sealed).toString("base64"), v.ciphertext, "seal must reproduce the vector");
    assert.equal(await sha256(sealed), v.ciphertextSHA256);
    assert.deepEqual(await open(sealed, derived, v.purpose), base64Decode(v.plaintext));
  });
}

for (const v of book.negative) {
  test(`book negative: ${v.name}`, async () => {
    assert.equal(v.reason, "auth");
    const derived = await key(v.kind, base64UrlDecode(v.rootKey), v.chapterID);
    await assert.rejects(open(base64Decode(v.ciphertext), derived, v.kind === "chapter" ? "audio" : "meta"), error => {
      assert.ok(error instanceof ShareCryptoError, `${error}`);
      assert.equal(error.reason, "auth", v.name);
      return true;
    });
  });
}

for (const v of book.invalidManifests) {
  test(`book invalid manifest: ${v.name}`, async () => {
    const r = base64UrlDecode(v.rootKey), encrypted = base64Decode(v.ciphertext);
    await open(encrypted, await manifestKey(r), "meta"); // it decrypts
    await assert.rejects(openManifest(encrypted, r), error => {
      assert.ok(error instanceof ShareCryptoError, `${error}`);
      assert.equal(error.reason, "format", v.name);
      return true;
    });
  });
}

test("the manifest opens, authenticates its descriptors and every chapter and text", async () => {
  const encryptedManifest = manifestVector.ciphertext;
  const opened = await openManifest(base64Decode(encryptedManifest), root);
  const blobs = {};
  for (const c of opened.chapters) {
    blobs[c.id] = { role: "audio", bytes: c.audioBytes, sha256: c.audioSHA256 };
    if (c.text) blobs[c.text.id] = { role: "text", bytes: c.text.bytes, sha256: c.text.sha256 };
  }
  const details = { schema: BOOK_SCHEMA, encryptedManifest, blobs };
  const authenticated = await authenticateBook(details, root);
  assert.equal(authenticated.title, "A Short Book");
  assert.equal(authenticated.author, "A. Writer");
  assert.equal(authenticated.note, "For the train.\nEnjoy.");
  assert.equal(authenticated.chapters.length, 12);
  assert.equal(authenticated.chapters.at(-1).title, "Épilogue");

  const chapters = book.positive.filter(v => v.kind === "chapter");
  assert.deepEqual(authenticated.chapters.map(c => c.id), chapters.map(v => v.chapterID), "order is the manifest's");
  for (const [i, v] of chapters.entries()) {
    assert.deepEqual(await openChapter(base64Decode(v.ciphertext), root, authenticated.chapters[i]), base64Decode(v.plaintext), v.name);
  }
  await assert.rejects(openChapter(base64Decode(chapters[1].ciphertext), root, authenticated.chapters[0]), "substituted chapter");
  const textVector = book.positive.find(v => v.kind === "text");
  const segments = await openText(base64Decode(textVector.ciphertext), root, authenticated.chapters[1]);
  assert.deepEqual(segments.map(s => s.text), ["Chapter Two: The Road", "The road went on."]);
  await assert.rejects(openText(base64Decode(textVector.ciphertext), root, authenticated.chapters[0]), "chapter 1 has no text");

  // The service's descriptors must be exactly the manifest's.
  const firstID = authenticated.chapters[0].id, textID = authenticated.chapters[1].text.id;
  for (const altered of [
    { ...blobs, [firstID]: { ...blobs[firstID], bytes: blobs[firstID].bytes + 1 } },
    { ...blobs, [textID]: { ...blobs[textID], role: "audio" } },
    Object.fromEntries(Object.entries(blobs).filter(([id]) => id !== textID)),
    { ...blobs, AAAAAAAAAAAAAAAAAAAAAA: { role: "text", bytes: 100, sha256: "0".repeat(64) } },
  ]) await assert.rejects(authenticateBook({ ...details, blobs: altered }, root));
  await assert.rejects(authenticateBook({ ...details, schema: "baton-mixtape-1" }, root));
  await assert.rejects(authenticateBook(details, new Uint8Array(16)), "wrong key");
});

test("IDs are canonical and the root key size is enforced", async () => {
  const id = book.positive.find(v => v.kind === "chapter").chapterID;
  assert.ok(canonicalID(id));
  for (const bad of [null, "", "../secret", id + "=", id.slice(0, -1) + "B"]) assert.equal(canonicalID(bad), null);
  await assert.rejects(chapterKey(new Uint8Array(15), id));
});
