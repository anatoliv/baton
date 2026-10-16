// Browser manifest boundary. No track is requested before this returns authenticated order.
import { base64Decode, open, ShareCryptoError } from "./share-crypto.mjs";
import { canonicalTrackID, manifestKey } from "./share-mixtape-crypto.mjs";
const fail = () => { throw new ShareCryptoError("format", "Invalid mixtape manifest"); };
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
function text(value, maximum, required = false, multiline = false) {
  if (typeof value !== "string") fail();
  const cleaned = value.normalize("NFC").trim();
  if ([...cleaned].length > maximum || (required && !cleaned) || [...cleaned].some(c => {
    const n = c.codePointAt(0); return (n < 32 || (n >= 127 && n <= 159)) && !(multiline && c === "\n");
  })) fail();
  return cleaned;
}
function metadata(value) {
  if (!object(value) || !Number.isSafeInteger(value.durationSeconds) || value.durationSeconds < 1 || value.durationSeconds > 1200) fail();
  const result = { title: text(value.title, 200, true), artist: text(value.artist ?? "", 200), album: text(value.album ?? "", 200),
    from: text(value.from ?? "", 60), note: text(value.note ?? "", 280, false, true), durationSeconds: value.durationSeconds };
  if (value.accent != null && (typeof value.accent !== "string" || !/^#[0-9a-f]{6}$/i.test(value.accent))) fail();
  if (value.peaks != null && (!Array.isArray(value.peaks) || value.peaks.length > 512 || value.peaks.some(n => !Number.isSafeInteger(n) || n < 0 || n > 255))) fail();
  if (value.recordingID != null && (typeof value.recordingID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value.recordingID))) fail();
  return result;
}
export async function authenticateManifest(details, root) {
  if (!object(details) || details.schema !== "baton-mixtape-1" || !object(details.tracks) || typeof details.encryptedManifest !== "string" ||
      details.encryptedManifest.length > 87384 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(details.encryptedManifest)) fail();
  const encrypted = base64Decode(details.encryptedManifest);
  if (encrypted.length < 36 || encrypted.length > 65536) fail();
  const plain = await open(encrypted, await manifestKey(root), "meta");
  let manifest;
  try { manifest = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain)); } finally { plain.fill(0); }
  if (!object(manifest) || manifest.schema !== "baton-mixtape-1" || !Array.isArray(manifest.tracks) || manifest.tracks.length < 2 || manifest.tracks.length > 12 || Object.keys(details.tracks).length !== manifest.tracks.length) fail();
  const title = text(manifest.title, 200, true), seen = new Set();
  let bytes = 0, duration = 0;
  const tracks = manifest.tracks.map(track => {
    if (!object(track) || !canonicalTrackID(track.id) || seen.has(track.id) || !Number.isSafeInteger(track.audioBytes) || track.audioBytes < 36 || track.audioBytes > 26214400 - bytes ||
        typeof track.audioSHA256 !== "string" || !/^[0-9a-f]{64}$/.test(track.audioSHA256)) fail();
    const descriptor = Object.hasOwn(details.tracks, track.id) ? details.tracks[track.id] : null;
    if (!object(descriptor) || descriptor.audioBytes !== track.audioBytes || descriptor.audioSHA256 !== track.audioSHA256) fail();
    const meta = metadata(track.metadata);
    if (meta.durationSeconds > 1200 - duration) fail();
    seen.add(track.id); bytes += track.audioBytes; duration += meta.durationSeconds;
    return { id: track.id, audioBytes: track.audioBytes, audioSHA256: track.audioSHA256, metadata: meta };
  });
  return { title, tracks, audioBytes: bytes, durationSeconds: duration };
}

// Transport ceilings precede parsing/decryption and apply even without Content-Length.
export async function readBounded(response, maximum, exact = false) {
  const header = response.headers.get("Content-Length");
  if (header !== null && (!/^\d+$/.test(header) || Number(header) > maximum || (exact && Number(header) !== maximum))) {
    await response.body?.cancel(); fail();
  }
  if (!response.body) fail();
  const out = new Uint8Array(maximum), reader = response.body.getReader();
  let offset = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value.length > maximum - offset) fail();
      out.set(value, offset); offset += value.length;
    }
    if (exact && offset !== maximum) fail();
    return out.subarray(0, offset);
  } catch (error) { await reader.cancel().catch(() => {}); throw error; }
  finally { reader.releaseLock(); }
}
