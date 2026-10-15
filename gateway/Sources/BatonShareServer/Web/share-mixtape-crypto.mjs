// Default-off protocol slice; not imported by the shipping player.
// specs/song-sharing-mixtapes.md; existing BSH1 records stay unchanged.
import { base64UrlDecode, open, ShareCryptoError } from "./share-crypto.mjs";

export function canonicalTrackID(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(text)) return null;
  const id = base64UrlDecode(text);
  if (!id || id.length !== 16) return null;
  const canonical = btoa(String.fromCharCode(...id)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return canonical === text ? id : null;
}

async function derive(root, info) {
  if (!(root instanceof Uint8Array) || root.length !== 16) throw new ShareCryptoError("format", "bad root key");
  const key = await crypto.subtle.importKey("raw", root, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(), info }, key, 128));
}

export async function manifestKey(root) {
  return derive(root, new TextEncoder().encode("baton-share mixtape v1 manifest"));
}

export async function trackKey(root, trackID) {
  const id = canonicalTrackID(trackID);
  if (!id) throw new ShareCryptoError("format", "bad track ID");
  const prefix = new TextEncoder().encode("baton-share mixtape v1 track\0");
  const info = new Uint8Array(prefix.length + id.length);
  info.set(prefix); info.set(id, prefix.length);
  return derive(root, info);
}

// The UI/wire metadata validator is intentionally not duplicated here. Native and
// browser manifest handling must share its reviewed contract before activation.
export async function openTrack(ciphertext, root, descriptor) {
  if (!(ciphertext instanceof Uint8Array) || !descriptor ||
      !Number.isSafeInteger(descriptor.audioBytes) || descriptor.audioBytes < 36 ||
      descriptor.audioBytes > 26214400 || ciphertext.length !== descriptor.audioBytes ||
      typeof descriptor.audioSHA256 !== "string" || !/^[0-9a-f]{64}$/.test(descriptor.audioSHA256)) {
    throw new ShareCryptoError("format", "invalid track descriptor");
  }
  const key = await trackKey(root, descriptor.id);
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", ciphertext)), b => b.toString(16).padStart(2, "0")).join("");
  if (digest !== descriptor.audioSHA256) throw new ShareCryptoError("auth", "track does not match manifest");
  return open(ciphertext, key, "audio");
}
