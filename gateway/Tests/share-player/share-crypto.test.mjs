// The browser half of the cross-implementation check (specs/song-sharing.md §2): the player's
// own module, run on Node's WebCrypto (the same API the browser has), against the vectors the
// Swift kit is also checked against.
//
//   node --test gateway/Tests/share-player/*.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { base64Decode, base64UrlDecode, layout, open, seal, ShareCryptoError } from "../../Sources/BatonShareServer/Web/share-crypto.mjs";

const vectors = JSON.parse(readFileSync(fileURLToPath(new URL("../../../specs/share-crypto/vectors.json", import.meta.url)), "utf8"));
const hex = (h) => Uint8Array.from(h.match(/../g).map((b) => parseInt(b, 16)));
const sha256 = async (bytes) => Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");

test("the vector file has every entry", () => {
  assert.ok(vectors.positive.length >= 9);
  assert.ok(vectors.negative.length >= 14);
});

for (const v of vectors.positive) {
  test(`positive: ${v.name}`, async () => {
    const key = base64UrlDecode(v.key);
    const plaintext = base64Decode(v.plaintext);
    const expected = base64Decode(v.ciphertext);
    const sealed = await seal(plaintext, key, v.purpose, v.recordSize, hex(v.baseNonce));
    assert.equal(Buffer.from(sealed).toString("base64"), v.ciphertext, "seal must reproduce the vector");
    assert.equal(await sha256(sealed), v.ciphertextSHA256);
    let last = 0;
    const opened = await open(expected, key, v.purpose, (f) => { last = f; });
    assert.equal(await sha256(opened), v.plaintextSHA256);
    assert.equal(last, 1, "progress reaches 1");
  });
}

for (const v of vectors.negative) {
  test(`negative: ${v.name}`, async () => {
    await assert.rejects(open(base64Decode(v.ciphertext), base64UrlDecode(v.key), v.purpose), (error) => {
      assert.ok(error instanceof ShareCryptoError, `${error}`);
      assert.equal(error.reason, v.reason);
      return true;
    });
  });
}

test("base64url decoding refuses anything else", () => {
  assert.equal(base64UrlDecode(""), null);
  assert.equal(base64UrlDecode("abc+def"), null);
  assert.equal(base64UrlDecode("ab=c"), null);
  assert.equal(base64UrlDecode("AAECAwQFBgcICQoLDA0ODw").length, 16);
});

test("layout reports the record count", () => {
  const v = vectors.positive.find((p) => p.name === "three records and a tail");
  assert.equal(layout(base64Decode(v.ciphertext)).records, 4);
});
