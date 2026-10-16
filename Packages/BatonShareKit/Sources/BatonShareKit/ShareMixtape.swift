#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Protocol primitives for the default-off mixtape capability.
/// Contract: specs/song-sharing-mixtapes.md. Existing BSH1 records are unchanged.
public enum ShareMixtapeCrypto {
    public static func manifestKey(rootKey: Data) throws -> Data {
        try derive(rootKey, info: Data("baton-share mixtape v1 manifest".utf8))
    }

    public static func trackKey(rootKey: Data, trackID: String) throws -> Data {
        guard let id = canonicalID(trackID) else {
            throw ShareValidationError("trackID", "must be a canonical 16-byte ID")
        }
        return try derive(rootKey, info: Data("baton-share mixtape v1 track\0".utf8) + id)
    }

    public static func isCanonicalTrackID(_ text: String) -> Bool { canonicalID(text) != nil }

    static func canonicalID(_ text: String) -> Data? {
        guard text.utf8.count == 22, let data = Base64URL.decode(text),
              data.count == 16, Base64URL.encode(data) == text else { return nil }
        return data
    }

    private static func derive(_ root: Data, info: Data) throws -> Data {
        guard root.count == ShareCrypto.keyLength else { throw ShareCrypto.Failure.badKey }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root),
            salt: Data(), info: info, outputByteCount: ShareCrypto.keyLength)
        return key.withUnsafeBytes { Data($0) }
    }
}

public struct ShareMixtapeManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = "baton-mixtape-1"
    public static let maximumEncryptedBytes = 65_536
    public var schema: String
    public var title: String
    public var tracks: [Track]

    public struct Track: Codable, Equatable, Sendable {
        public var id: String
        public var metadata: ShareMetadata
        public var audioBytes: Int
        public var audioSHA256: String

        public init(id: String, metadata: ShareMetadata, audioBytes: Int, audioSHA256: String) {
            self.id = id; self.metadata = metadata; self.audioBytes = audioBytes
            self.audioSHA256 = audioSHA256
        }
    }

    public init(title: String, tracks: [Track]) {
        self.schema = Self.schemaVersion; self.title = title; self.tracks = tracks
    }

    public func validated(limits: ShareLimits = .standard) throws -> Self {
        guard schema == Self.schemaVersion else { throw ShareValidationError("schema", "unsupported mixtape") }
        guard (2...12).contains(tracks.count) else { throw ShareValidationError("tracks", "must contain 2 to 12 tracks") }
        var result = self
        result.title = try ShareText.clean(title, field: "title", max: ShareLimits.maxTitleLength)
        guard !result.title.isEmpty else { throw ShareValidationError("title", "is required") }
        var seen = Set<String>(), totalBytes = 0, totalDuration = 0
        result.tracks = try tracks.map { track in
            guard ShareMixtapeCrypto.canonicalID(track.id) != nil, seen.insert(track.id).inserted else {
                throw ShareValidationError("tracks.id", "invalid or duplicate track ID")
            }
            guard track.audioBytes >= ShareCrypto.headerLength + ShareCrypto.tagLength,
                  track.audioBytes <= limits.maxAudioBytes - totalBytes else {
                throw ShareValidationError("tracks.audioBytes", "exceeds aggregate audio limit")
            }
            guard track.audioSHA256.utf8.count == 64,
                  track.audioSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ShareValidationError("tracks.audioSHA256", "must be lower-case SHA-256")
            }
            var normalized = track
            normalized.metadata = try track.metadata.validated(limits: limits)
            guard normalized.metadata.durationSeconds <= limits.maxDurationSeconds - totalDuration else {
                throw ShareValidationError("tracks.durationSeconds", "exceeds aggregate duration limit")
            }
            totalBytes += track.audioBytes; totalDuration += normalized.metadata.durationSeconds
            return normalized
        }
        return result
    }

    public func seal(rootKey: Data) throws -> Data {
        let encoded = try JSONEncoder().encode(validated())
        guard ShareCrypto.sealedLength(plaintextLength: encoded.count) <= Self.maximumEncryptedBytes else {
            throw ShareValidationError("manifest", "exceeds encrypted manifest limit")
        }
        return try ShareCrypto.seal(encoded, key: ShareMixtapeCrypto.manifestKey(rootKey: rootKey), purpose: .meta)
    }

    public static func open(_ encrypted: Data, rootKey: Data) throws -> Self {
        guard encrypted.count <= maximumEncryptedBytes else {
            throw ShareValidationError("manifest", "exceeds encrypted manifest limit")
        }
        let plain = try ShareCrypto.open(encrypted,
            key: ShareMixtapeCrypto.manifestKey(rootKey: rootKey), purpose: .meta)
        return try JSONDecoder().decode(Self.self, from: plain).validated()
    }

    /// Checks the authenticated descriptor before exposing any playable track bytes.
    public func openAudio(_ ciphertext: Data, trackID: String, rootKey: Data) throws -> Data {
        let checked = try validated()
        guard let track = checked.tracks.first(where: { $0.id == trackID }),
              ciphertext.count == track.audioBytes,
              ShareHash.sha256Hex(ciphertext) == track.audioSHA256 else {
            throw ShareValidationError("audio", "does not match the authenticated manifest")
        }
        return try ShareCrypto.open(ciphertext,
            key: ShareMixtapeCrypto.trackKey(rootKey: rootKey, trackID: trackID), purpose: .audio)
    }
}
