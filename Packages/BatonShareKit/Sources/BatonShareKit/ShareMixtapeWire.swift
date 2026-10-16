import Foundation

public struct MixtapeTrackDescriptor: Codable, Equatable, Sendable {
    public var audioBytes: Int
    public var audioSHA256: String
    public init(audioBytes: Int, audioSHA256: String) { self.audioBytes = audioBytes; self.audioSHA256 = audioSHA256 }
}

public struct MixtapePreview: Codable, Equatable, Sendable {
    public var title: String
    public var from: String
    public var note: String
    public init(title: String, from: String = "", note: String = "") { self.title = title; self.from = from; self.note = note }
    public func validated() throws -> Self {
        .init(title: try ShareText.clean(title, field: "title", max: ShareLimits.maxTitleLength),
              from: try ShareText.clean(from, field: "from", max: ShareLimits.maxFromLength),
              note: try ShareText.clean(note, field: "note", max: ShareLimits.maxNoteLength, allowNewlines: true))
    }
}

public struct CreateMixtapeRequest: Codable, Equatable, Sendable {
    public var schema = ShareMixtapeManifest.schemaVersion
    /// Durable client-generated retry identity; bound to the exact body and installation.
    public var requestID: String
    public var encryptedManifest: String
    public var tracks: [String: MixtapeTrackDescriptor]
    public var totalDurationSeconds: Int
    public var expiresInSeconds: Int
    public var playCap: Int
    public var reviewPreservationConsent: String?
    public var preview: MixtapePreview?
    public var client: ShareClientInfo
    public init(requestID: String = UUID().uuidString, encryptedManifest: String, tracks: [String: MixtapeTrackDescriptor], totalDurationSeconds: Int,
                expiresInSeconds: Int, playCap: Int, preview: MixtapePreview?, client: ShareClientInfo, reviewPreservationConsent: String? = nil) {
        self.requestID = requestID; self.encryptedManifest = encryptedManifest; self.tracks = tracks
        self.totalDurationSeconds = totalDurationSeconds; self.expiresInSeconds = expiresInSeconds; self.playCap = playCap
        self.preview = preview; self.client = client; self.reviewPreservationConsent = reviewPreservationConsent
    }
    public func validated(limits: ShareLimits = .standard) throws -> Self {
        guard schema == ShareMixtapeManifest.schemaVersion, UUID(uuidString: requestID) != nil,
              (2...12).contains(tracks.count), (1...limits.maxDurationSeconds).contains(totalDurationSeconds),
              limits.expiryChoices.contains(expiresInSeconds), (1...limits.maxPlayCap).contains(playCap),
              reviewPreservationConsent == nil || reviewPreservationConsent == CreateShareRequest.reviewConsentVersion,
              ShareClientInfo.platforms.contains(client.platform),
              let manifest = Data(base64Encoded: encryptedManifest), manifest.count <= ShareMixtapeManifest.maximumEncryptedBytes,
              (try? ShareCrypto.layout(headerBytes: Array(manifest.prefix(ShareCrypto.headerLength)), totalLength: manifest.count)) != nil else {
            throw ShareValidationError("mixtape", "invalid container request")
        }
        var total = 0
        for (id, track) in tracks {
            guard ShareMixtapeCrypto.canonicalID(id) != nil,
                  track.audioBytes >= ShareCrypto.headerLength + ShareCrypto.tagLength,
                  track.audioBytes <= limits.maxAudioBytes - total,
                  track.audioSHA256.utf8.count == 64,
                  track.audioSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ShareValidationError("tracks", "invalid track descriptor or aggregate size")
            }
            total += track.audioBytes
        }
        var result = self
        result.preview = try preview?.validated()
        if result.preview?.title.isEmpty == true { throw ShareValidationError("preview.title", "is required") }
        result.client.appVersion = try ShareText.clean(client.appVersion, field: "client.appVersion", max: 40)
        return result
    }
    public var audioBytes: Int { tracks.values.reduce(0) { $0 + $1.audioBytes } }
}

public struct CreateMixtapeResponse: Codable, Equatable, Sendable {
    public var id: String
    public var url: String
    public var expiresAt: String
    public var uploads: [String: String]
    public init(id: String, url: String, expiresAt: String, uploads: [String: String]) {
        self.id = id; self.url = url; self.expiresAt = expiresAt; self.uploads = uploads
    }
}

public struct PublicMixtape: Codable, Equatable, Sendable {
    public var schema: String = ShareMixtapeManifest.schemaVersion
    public var status: ShareStatus
    public var preview: MixtapePreview?
    public var encryptedManifest: String
    public var tracks: [String: MixtapeTrackDescriptor]
    public var expiresAt: String
    public var remainingPlays: Int
    public init(status: ShareStatus, preview: MixtapePreview?, encryptedManifest: String, tracks: [String: MixtapeTrackDescriptor], expiresAt: String, remainingPlays: Int) {
        self.status = status; self.preview = preview; self.encryptedManifest = encryptedManifest; self.tracks = tracks
        self.expiresAt = expiresAt; self.remainingPlays = remainingPlays
    }
    public func open(rootKey: Data) throws -> ShareMixtapeManifest {
        guard schema == ShareMixtapeManifest.schemaVersion, let bytes = Data(base64Encoded: encryptedManifest) else {
            throw ShareValidationError("mixtape", "unsupported or malformed manifest")
        }
        let manifest = try ShareMixtapeManifest.open(bytes, rootKey: rootKey)
        guard manifest.tracks.count == tracks.count, manifest.tracks.allSatisfy({ tracks[$0.id] == .init(audioBytes: $0.audioBytes, audioSHA256: $0.audioSHA256) }) else {
            throw ShareValidationError("mixtape", "descriptors do not match authenticated manifest")
        }
        return manifest
    }
}

public struct MixtapeSession: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "MixtapeSession(credential withheld)" }
    public var debugDescription: String { description }
    public var token: String
    public var expiresAt: String
    public var remainingBytes: Int
    public var remainingPlays: Int
    public init(token: String, expiresAt: String, remainingBytes: Int, remainingPlays: Int) {
        self.token = token; self.expiresAt = expiresAt; self.remainingBytes = remainingBytes; self.remainingPlays = remainingPlays
    }
}

public struct MixtapeSummary: Codable, Equatable, Sendable {
    public var share: ShareSummary
    public var trackCount: Int
    public var reviewDeadline: String?
    public var pausedLifetimeSeconds: Int64?
    public init(share: ShareSummary, trackCount: Int, reviewDeadline: String? = nil, pausedLifetimeSeconds: Int64? = nil) {
        self.share = share; self.trackCount = trackCount; self.reviewDeadline = reviewDeadline; self.pausedLifetimeSeconds = pausedLifetimeSeconds
    }
}
public struct MixtapeList: Codable, Equatable, Sendable {
    public var mixtapes: [MixtapeSummary]
    public init(mixtapes: [MixtapeSummary]) { self.mixtapes = mixtapes }
}
