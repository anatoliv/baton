// The browser's half of the BSH1 format (specs/song-sharing.md §2), on WebCrypto only.
//
// The Swift kit (Packages/BatonShareKit) is the other half; both are checked against
// specs/share-crypto/vectors.json, which neither of them wrote. Change the format there first.

const MAGIC = [0x42, 0x53, 0x48, 0x31]; // "BSH1"
export const HEADER_LENGTH = 20;
export const TAG_LENGTH = 16;
const MIN_RECORD = 1024;
const MAX_RECORD = 1048576;

/** A refusal, with the reason the player reports (`format` or `auth`). */
export class ShareCryptoError extends Error {
  constructor(reason, message) {
    super(message);
    this.reason = reason;
  }
}

/** Unpadded base64url → bytes, or null if it is not that. */
export function base64UrlDecode(text) {
  if (typeof text !== "string" || text.length === 0 || !/^[A-Za-z0-9_-]+$/.test(text)) return null;
  const base = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  try {
    const binary = atob(base);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

export function base64Decode(text) {
  const binary = atob(text);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** The shape of a BSH1 stream from its header and length alone, or a `format` error. */
export function layout(bytes, totalLength = bytes.length) {
  if (totalLength < HEADER_LENGTH + TAG_LENGTH || bytes.length < HEADER_LENGTH) {
    throw new ShareCryptoError("format", "shorter than one empty record");
  }
  for (let i = 0; i < 4; i++) {
    if (bytes[i] !== MAGIC[i]) throw new ShareCryptoError("format", "not BSH1");
  }
  const recordSize = ((bytes[4] << 24) >>> 0) + (bytes[5] << 16) + (bytes[6] << 8) + bytes[7];
  if (recordSize < MIN_RECORD || recordSize > MAX_RECORD) {
    throw new ShareCryptoError("format", `record size ${recordSize} out of range`);
  }
  const body = totalLength - HEADER_LENGTH;
  const full = recordSize + TAG_LENGTH;
  const records = Math.ceil(body / full);
  const last = body - (records - 1) * full;
  if (last < TAG_LENGTH) throw new ShareCryptoError("format", "the last record is shorter than a tag");
  // Only an empty plaintext ends in an empty record; after full records the last one holds 1 to recordSize bytes.
  if (records > 1 && last === TAG_LENGTH) throw new ShareCryptoError("format", "an empty final record after full records");
  return { recordSize, records, lastRecordLength: last };
}

async function subkey(key, purpose, usage) {
  if (!(key instanceof Uint8Array) || key.length !== 16) {
    throw new ShareCryptoError("format", "the key must be 16 bytes");
  }
  const base = await crypto.subtle.importKey("raw", key, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode(`baton-share v1 ${purpose}`) },
    base,
    { name: "AES-GCM", length: 128 },
    false,
    [usage],
  );
}

function nonce(base, index) {
  const out = new Uint8Array(base);
  let counter = BigInt(index);
  for (let position = 11; position >= 4; position--) {
    out[position] ^= Number(counter & 0xffn);
    counter >>= 8n;
  }
  return out;
}

function aad(header, isFinal) {
  const out = new Uint8Array(HEADER_LENGTH + 1);
  out.set(header, 0);
  out[HEADER_LENGTH] = isFinal ? 1 : 0;
  return out;
}

/**
 * Opens a BSH1 stream. Throws `ShareCryptoError` with reason `format` or `auth`; never returns
 * partial plaintext. `onProgress(fraction)` is called as records are opened.
 */
export async function open(bytes, key, purpose, onProgress) {
  const shape = layout(bytes);
  const aesKey = await subkey(key, purpose, "decrypt");
  const header = bytes.subarray(0, HEADER_LENGTH);
  const base = bytes.slice(8, HEADER_LENGTH);
  const plaintextLength = (shape.records - 1) * shape.recordSize + shape.lastRecordLength - TAG_LENGTH;
  const out = new Uint8Array(plaintextLength);

  // A few records in flight at once: WebCrypto calls are async, and one at a time spends most of
  // a 10 MB song waiting on the event loop rather than decrypting.
  const batch = 8;
  for (let first = 0; first < shape.records; first += batch) {
    const jobs = [];
    for (let index = first; index < Math.min(first + batch, shape.records); index++) {
      const isFinal = index === shape.records - 1;
      const start = HEADER_LENGTH + index * (shape.recordSize + TAG_LENGTH);
      const length = isFinal ? shape.lastRecordLength : shape.recordSize + TAG_LENGTH;
      const record = bytes.subarray(start, start + length);
      jobs.push(
        crypto.subtle
          .decrypt({ name: "AES-GCM", iv: nonce(base, index), additionalData: aad(header, isFinal), tagLength: 128 }, aesKey, record)
          .then(
            (plain) => out.set(new Uint8Array(plain), index * shape.recordSize),
            () => {
              throw new ShareCryptoError("auth", `record ${index} did not authenticate`);
            },
          ),
      );
    }
    await Promise.all(jobs);
    if (onProgress) onProgress(Math.min(1, (first + batch) / shape.records));
  }
  return out;
}

/** Seals a plaintext. The player never needs this; the tests use it to prove the vectors. */
export async function seal(plaintext, key, purpose, recordSize = 65536, baseNonce = crypto.getRandomValues(new Uint8Array(12))) {
  const aesKey = await subkey(key, purpose, "encrypt");
  const header = new Uint8Array(HEADER_LENGTH);
  header.set(MAGIC, 0);
  new DataView(header.buffer).setUint32(4, recordSize);
  header.set(baseNonce, 8);
  const count = Math.max(1, Math.ceil(plaintext.length / recordSize));
  const parts = [header];
  for (let index = 0; index < count; index++) {
    const chunk = plaintext.subarray(index * recordSize, Math.min((index + 1) * recordSize, plaintext.length));
    const sealed = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce(baseNonce, index), additionalData: aad(header, index === count - 1), tagLength: 128 },
      aesKey,
      chunk,
    );
    parts.push(new Uint8Array(sealed));
  }
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/**
 * The media type of decrypted audio, by what it is rather than what it was assumed to be
 * (specs/book-sharing.md): a book chapter is AAC in MP4 (`ftyp` at offset 4), a song is MP3.
 * Labelled truthfully, no browser has to sniff past a wrong type (macOS WebKit and Chromium do;
 * Firefox and iPhone Safari were not measured).
 * Not part of the format; it lives here because both players import this module.
 */
export function audioType(bytes) {
  const ftyp = bytes.length >= 8 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70;
  return ftyp ? "audio/mp4" : "audio/mpeg";
}
