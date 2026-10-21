// The whole-book link format, baton-book-1 (specs/book-sharing.md, "The format").
// A book is an encrypted manifest and, per chapter, one audio blob and an optional read-along
// text blob, each an ordinary BSH1 stream under its own HKDF-derived key. Checked against the
// "book" section of specs/share-crypto/vectors.json, which an independent Python
// implementation wrote; the Swift kit's ShareBook.swift reproduces the same vectors.
// An album or a playlist (baton-collection-1, specs/collection-sharing.md) is the same link under
// the book's keys with its own manifest schema, checked against the "collection" section.
import { base64Decode, open, ShareCryptoError } from "./share-crypto.mjs";
import { canonicalTrackID } from "./share-mixtape-crypto.mjs";

export const BOOK_SCHEMA = "baton-book-1";
export const BOOK_TEXT_SCHEMA = "baton-book-text-1";
export const COLLECTION_SCHEMA = "baton-collection-1";
export const COLLECTION_KINDS = ["album", "playlist"];
export const COVER = { maxBytes: 131072, maxTrackNumber: 9999 };
export const LABELS = { manifest: "baton-share book v1 manifest", chapter: "baton-share book v1 chapter", text: "baton-share book v1 text" };
// The format's own ceilings, the same numbers as ShareLimits' book fields.
export const LIMITS = { maxChapters: 200, maxChapterAudioBytes: 26214400, maxChapterTextBytes: 1048576, maxBookBytes: 268435456,
  maxEncryptedManifestBytes: 262144, maxChapterSeconds: 86400, maxBookSeconds: 172800 };
const MIN_BLOB = 36; // one empty BSH1 record: 20-byte header and 16-byte tag

const fail = (why = "Invalid book manifest") => { throw new ShareCryptoError("format", why); };
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const hash = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);

/** A canonical blob ID (16 random bytes as 22 characters of unpadded base64url), or null. */
export const canonicalID = canonicalTrackID;

async function derive(root, info) {
  if (!(root instanceof Uint8Array) || root.length !== 16) throw new ShareCryptoError("format", "bad root key");
  const key = await crypto.subtle.importKey("raw", root, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(), info }, key, 128));
}

async function bound(root, label, chapterID) {
  const id = canonicalID(chapterID);
  if (!id) throw new ShareCryptoError("format", "bad chapter ID");
  const prefix = new TextEncoder().encode(label + "\0");
  const info = new Uint8Array(prefix.length + id.length);
  info.set(prefix); info.set(id, prefix.length);
  return derive(root, info);
}

export const manifestKey = root => derive(root, new TextEncoder().encode(LABELS.manifest));
export const chapterKey = (root, chapterID) => bound(root, LABELS.chapter, chapterID);
export const textKey = (root, chapterID) => bound(root, LABELS.text, chapterID);

function text(value, maximum, required = false, multiline = false) {
  if (typeof value !== "string") fail();
  const cleaned = value.normalize("NFC").trim();
  if ([...cleaned].length > maximum || (required && !cleaned) || [...cleaned].some(c => {
    const n = c.codePointAt(0); return (n < 32 || (n >= 127 && n <= 159)) && !(multiline && c === "\n");
  })) fail();
  return cleaned;
}

const B64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const startsWith = (bytes, signature) => signature.every((b, i) => bytes[i] === b);

/** A collection's cover: canonical padded base64 of a JPEG or PNG of at most 128 KiB, its type matching its bytes. */
function cover(value) {
  if (!object(value) || !["image/jpeg", "image/png"].includes(value.type) || typeof value.data !== "string" ||
      !value.data || !B64.test(value.data) || value.data.length > Math.ceil(COVER.maxBytes / 3) * 4) fail();
  let bytes;
  try { bytes = base64Decode(value.data); } catch { fail(); }
  if (bytes.length < 1 || bytes.length > COVER.maxBytes) fail();
  // Canonical: the unused bits of the last character are zero, so re-encoding gives the same text.
  let binary = ""; for (const b of bytes) binary += String.fromCharCode(b);
  if (btoa(binary) !== value.data) fail();
  const jpeg = startsWith(bytes, [0xff, 0xd8, 0xff]), png = startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if ((value.type === "image/jpeg" && !jpeg) || (value.type === "image/png" && !png)) fail();
  return { type: value.type, bytes };
}

/**
 * Checks a decrypted album or playlist manifest the way ShareBookManifest.validated does for a
 * collection. The result has the book's shape (`chapters`, `author`) plus `kind`, `cover` and each
 * track's `artist`, `album` and `trackNumber`, so the same session and blob code plays it.
 */
export function validateCollection(manifest, encryptedBytes = 0) {
  if (!object(manifest) || manifest.schema !== COLLECTION_SCHEMA || !COLLECTION_KINDS.includes(manifest.kind) ||
      !Array.isArray(manifest.tracks) || manifest.tracks.length < 1 || manifest.tracks.length > LIMITS.maxChapters) fail();
  const result = { schema: COLLECTION_SCHEMA, kind: manifest.kind, title: text(manifest.title, 200, true),
    author: text(manifest.artist ?? "", 200), from: text(manifest.from ?? "", 60), note: text(manifest.note ?? "", 280, false, true),
    cover: manifest.cover == null ? null : cover(manifest.cover), chapters: [] };
  const seen = new Set();
  let bytes = encryptedBytes, seconds = 0;
  for (const track of manifest.tracks) {
    if (!object(track) || !canonicalID(track.id) || seen.has(track.id) || track.text != null) fail();
    seen.add(track.id);
    const title = text(track.title, 200, true);
    const artist = track.artist == null ? null : text(track.artist, 200);
    const album = track.album == null ? null : text(track.album, 200);
    if (track.trackNumber != null && (!Number.isSafeInteger(track.trackNumber) || track.trackNumber < 1 ||
        track.trackNumber > COVER.maxTrackNumber)) fail();
    if (!Number.isSafeInteger(track.durationSeconds) || track.durationSeconds < 1 ||
        track.durationSeconds > LIMITS.maxChapterSeconds || track.durationSeconds > LIMITS.maxBookSeconds - seconds) fail();
    if (!Number.isSafeInteger(track.audioBytes) || track.audioBytes < MIN_BLOB || track.audioBytes > LIMITS.maxChapterAudioBytes ||
        track.audioBytes > LIMITS.maxBookBytes - bytes || !hash(track.audioSHA256)) fail();
    bytes += track.audioBytes; seconds += track.durationSeconds;
    result.chapters.push({ id: track.id, title, artist, album, trackNumber: track.trackNumber ?? null,
      durationSeconds: track.durationSeconds, audioBytes: track.audioBytes, audioSHA256: track.audioSHA256 });
  }
  result.blobBytes = bytes - encryptedBytes;
  result.durationSeconds = seconds;
  return result;
}

/** Checks a decrypted manifest the way ShareBookManifest.validated does, before any chapter is requested. */
export function validateManifest(manifest, encryptedBytes = 0) {
  if (object(manifest) && manifest.schema === COLLECTION_SCHEMA) return validateCollection(manifest, encryptedBytes);
  if (!object(manifest) || manifest.schema !== BOOK_SCHEMA || !Array.isArray(manifest.chapters) ||
      manifest.chapters.length < 1 || manifest.chapters.length > LIMITS.maxChapters) fail();
  const result = { schema: BOOK_SCHEMA, kind: null, title: text(manifest.title, 200, true), author: text(manifest.author ?? "", 200),
    from: text(manifest.from ?? "", 60), note: text(manifest.note ?? "", 280, false, true), chapters: [] };
  const seen = new Set();
  let bytes = encryptedBytes, seconds = 0;
  for (const chapter of manifest.chapters) {
    if (!object(chapter) || !canonicalID(chapter.id) || seen.has(chapter.id)) fail();
    seen.add(chapter.id);
    const title = text(chapter.title, 200, true);
    if (!Number.isSafeInteger(chapter.durationSeconds) || chapter.durationSeconds < 1 ||
        chapter.durationSeconds > LIMITS.maxChapterSeconds || chapter.durationSeconds > LIMITS.maxBookSeconds - seconds) fail();
    if (!Number.isSafeInteger(chapter.audioBytes) || chapter.audioBytes < MIN_BLOB || chapter.audioBytes > LIMITS.maxChapterAudioBytes ||
        chapter.audioBytes > LIMITS.maxBookBytes - bytes || !hash(chapter.audioSHA256)) fail();
    bytes += chapter.audioBytes; seconds += chapter.durationSeconds;
    const entry = { id: chapter.id, title, durationSeconds: chapter.durationSeconds, audioBytes: chapter.audioBytes, audioSHA256: chapter.audioSHA256 };
    if (chapter.text != null) {
      const t = chapter.text;
      if (!object(t) || !canonicalID(t.id) || seen.has(t.id) || !Number.isSafeInteger(t.bytes) || t.bytes < MIN_BLOB ||
          t.bytes > LIMITS.maxChapterTextBytes || t.bytes > LIMITS.maxBookBytes - bytes || !hash(t.sha256)) fail();
      seen.add(t.id); bytes += t.bytes;
      entry.text = { id: t.id, bytes: t.bytes, sha256: t.sha256 };
    }
    result.chapters.push(entry);
  }
  result.blobBytes = bytes - encryptedBytes;
  result.durationSeconds = seconds;
  return result;
}

/** Opens and validates an encrypted manifest under the link's root key. */
export async function openManifest(encrypted, root) {
  if (!(encrypted instanceof Uint8Array) || encrypted.length < MIN_BLOB || encrypted.length > LIMITS.maxEncryptedManifestBytes) fail();
  const plain = await open(encrypted, await manifestKey(root), "meta");
  let manifest;
  try { manifest = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain)); }
  catch { fail(); }
  finally { plain.fill(0); }
  return validateManifest(manifest, encrypted.length);
}

/**
 * The public details of a /b/ link (GET /v1/share/b/<id>), authenticated: the manifest opens,
 * validates, and declares exactly the blob descriptors the service sent. Nothing is fetched
 * before this returns.
 */
export async function authenticateBook(details, root) {
  if (!object(details) || ![BOOK_SCHEMA, COLLECTION_SCHEMA].includes(details.schema) || !object(details.blobs) ||
      typeof details.encryptedManifest !== "string" || details.encryptedManifest.length > 349528 ||
      !B64.test(details.encryptedManifest)) fail();
  // A collection's descriptor names its kind; a book's names none. The manifest must agree with both.
  const kind = details.kind ?? null;
  if (details.schema === BOOK_SCHEMA ? kind !== null : !COLLECTION_KINDS.includes(kind)) fail();
  const book = await openManifest(base64Decode(details.encryptedManifest), root);
  if (book.schema !== details.schema || book.kind !== kind) fail();
  const declared = new Map();
  for (const c of book.chapters) {
    declared.set(c.id, { role: "audio", bytes: c.audioBytes, sha256: c.audioSHA256 });
    if (c.text) declared.set(c.text.id, { role: "text", bytes: c.text.bytes, sha256: c.text.sha256 });
  }
  const sent = Object.keys(details.blobs);
  if (sent.length !== declared.size) fail();
  for (const id of sent) {
    const mine = declared.get(id), theirs = details.blobs[id];
    if (!mine || !object(theirs) || theirs.role !== mine.role || theirs.bytes !== mine.bytes || theirs.sha256 !== mine.sha256) fail();
  }
  return book;
}

async function sha256Hex(bytes) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), b => b.toString(16).padStart(2, "0")).join("");
}

/** Checks a chapter's ciphertext against its authenticated length and hash, then opens it under the chapter key. */
export async function openChapter(ciphertext, root, chapter, onProgress) {
  if (!(ciphertext instanceof Uint8Array) || !object(chapter) || ciphertext.length !== chapter.audioBytes) fail("chapter does not match manifest");
  if (await sha256Hex(ciphertext) !== chapter.audioSHA256) throw new ShareCryptoError("auth", "chapter does not match manifest");
  return open(ciphertext, await chapterKey(root, chapter.id), "audio", onProgress);
}

/** Opens a chapter's read-along text and checks its shape; a book without text plays the same. */
export async function openText(ciphertext, root, chapter) {
  const t = chapter?.text;
  if (!(ciphertext instanceof Uint8Array) || !object(t) || ciphertext.length !== t.bytes) fail("text does not match manifest");
  if (await sha256Hex(ciphertext) !== t.sha256) throw new ShareCryptoError("auth", "text does not match manifest");
  const plain = await open(ciphertext, await textKey(root, chapter.id), "meta");
  let value;
  try { value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain)); } catch { fail("Invalid read-along text"); }
  if (!object(value) || value.schema !== BOOK_TEXT_SCHEMA || !Array.isArray(value.segments) || value.segments.length > 20000) fail("Invalid read-along text");
  return value.segments.map(s => {
    if (!object(s) || typeof s.text !== "string" || [...s.text].length > 4000 || !Number.isSafeInteger(s.paragraph) || s.paragraph < -1 ||
        !Number.isFinite(s.start) || !Number.isFinite(s.end) || s.start < 0 || s.end < s.start) fail("Invalid read-along text");
    return { text: s.text, paragraph: s.paragraph, start: s.start, end: s.end };
  });
}
