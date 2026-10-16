import BatonShareKit
import Darwin
import Foundation

/// Prepared independent encrypted MP3 fixture. No network or playback is performed here.
/// Later app-hosted checks supply the protected generated file explicitly, never owner audio.
struct MixtapeRealMediaFixture: Decodable, Sendable {
    struct Expected: Decodable, Sendable {
        let orderedTitles: [String]
        let declaredDurations: [Int]
        let firstSessionEvents: [String: Int]
        let renewedSessionBeforeAllTracksEvents: [String: Int]
    }
    enum Failure: Error {
        case unexpectedPath, noncanonicalPath, nonregularFile, unsafePermissions, differentOwner
        case invalidSize, unexpectedSchema, invalidContainerID, invalidKeyLength
        case unexpectedOrder, unexpectedDurationContract, observationTimedOut
    }
    let schema: String
    let rootKey: String
    let containerID: String
    let publicShare: PublicMixtape
    let blobs: [String: String]
    let expected: Expected

    static func load(from url: URL) throws -> Self {
        // Foundation standardization maps the measured /private/tmp root to /tmp.
        // Preserve the selected lexical root and prove physical identity instead.
        let canonical = url
        guard canonical.path.hasPrefix("/private/tmp/") else { throw Failure.unexpectedPath }
        guard let resolved = canonical.path.withCString({ realpath($0, nil) }) else {
            throw Failure.noncanonicalPath
        }
        defer { free(resolved) }
        guard String(cString: resolved) == canonical.path else { throw Failure.noncanonicalPath }
        let attrs = try FileManager.default.attributesOfItem(atPath: canonical.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw Failure.nonregularFile }
        guard (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw Failure.unsafePermissions }
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.differentOwner }
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size > 0, size <= 1_048_576 else {
            throw Failure.invalidSize
        }
        let data = try Data(contentsOf: canonical)
        guard data.count <= 1_048_576 else { throw Failure.invalidSize }
        let fixture = try JSONDecoder().decode(Self.self, from: data)
        guard fixture.schema == "baton-native-mixtape-media-fixture-1" else { throw Failure.unexpectedSchema }
        guard ShareLink.isValidID(fixture.containerID) else { throw Failure.invalidContainerID }
        guard Base64URL.decode(fixture.rootKey)?.count == 16 else { throw Failure.invalidKeyLength }
        guard fixture.expected.orderedTitles == ["Short synthetic MP3", "Long synthetic MP3"] else {
            throw Failure.unexpectedOrder
        }
        guard fixture.expected.declaredDurations == [2, 35] else { throw Failure.unexpectedDurationContract }
        return fixture
    }
    var invitation: ShareInvitation {
        .init(id: containerID, key: Base64URL.decode(rootKey), kind: .mixtape)
    }
}

/// Synthetic public HTTP response boundary only. Actual ShareMixtapeReceiver authentication
/// and SharedMixtapeModel/AVAudioPlayer remain unchanged; no player or clock override exists.
actor MixtapeRealMediaTransport: ShareReceiverTransport {
    struct Observation: Sendable {
        let admissions: Int
        let audioRequests: Int
        let eventsBySession: [Int: [String: Int]]
        let reactionsBySession: [Int: Int]
    }
    private let fixture: MixtapeRealMediaFixture
    private var admissions = 0, audioRequests = 0
    private var tokenOrdinals: [String: Int] = [:]
    private var remainingBySession: [Int: Int] = [:]
    private var events: [Int: [String: Int]] = [:]
    private var reactions: [Int: Int] = [:]
    init(fixture: MixtapeRealMediaFixture) { self.fixture = fixture }
    func observed() -> Observation {
        .init(admissions: admissions, audioRequests: audioRequests,
              eventsBySession: events, reactionsBySession: reactions)
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ShareReceiverResponse {
        let base = "/v1/share/m/" + fixture.containerID
        guard let url = request.url, url.scheme == "https", url.host == "batonmusic.app",
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            return error(400, "invalid")
        }
        if url.path == base && request.httpMethod == "GET" {
            guard request.value(forHTTPHeaderField: "Authorization") == nil else { return error(401, "unexpected_authority") }
            return .init(status: 200, body: try JSONEncoder().encode(fixture.publicShare))
        }
        if url.path == base + "/sessions" && request.httpMethod == "POST" {
            guard request.value(forHTTPHeaderField: "Authorization") == nil else { return error(401, "unexpected_authority") }
            guard admissions < 2 else { return error(410, "play_cap") }
            admissions += 1
            let token = Base64URL.encode(Data(repeating: UInt8(admissions), count: 32))
            tokenOrdinals[token] = admissions
            let bytes = fixture.publicShare.tracks.values.reduce(0) { $0 + $1.audioBytes }
            remainingBySession[admissions] = bytes
            return .init(status: 201, body: try JSONEncoder().encode(MixtapeSession(token: token,
                expiresAt: ShareDate.string(Date().addingTimeInterval(1800)), remainingBytes: bytes, remainingPlays: 2 - admissions)))
        }
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer "), let ordinal = tokenOrdinals[String(authorization.dropFirst(7))] else {
            return error(401, "session_required")
        }
        if url.path == base + "/tracks/" + url.lastPathComponent && request.httpMethod == "GET" {
            audioRequests += 1
            guard let encoded = fixture.blobs[url.lastPathComponent], let data = Data(base64Encoded: encoded),
                  data.count <= maximumBytes else { return error(404, "unknown") }
            guard (remainingBySession[ordinal] ?? 0) >= data.count else { return error(409, "transfer_budget") }
            remainingBySession[ordinal, default: 0] -= data.count
            return .init(status: 200, body: data)
        }
        if url.path == base + "/events" && request.httpMethod == "POST" {
            let event = try JSONDecoder().decode(PlayerEvent.self, from: request.httpBody ?? Data())
            events[ordinal, default: [:]][event.type.rawValue, default: 0] += 1
            return .init(status: 204, body: Data())
        }
        if url.path == base + "/reactions" && request.httpMethod == "POST" {
            _ = try JSONDecoder().decode(ReactionRequest.self, from: request.httpBody ?? Data())
            reactions[ordinal, default: 0] += 1
            return .init(status: 204, body: Data())
        }
        return error(404, "unknown")
    }
    private func error(_ status: Int, _ code: String) -> ShareReceiverResponse {
        .init(status: status, body: Data(("{\"code\":\"" + code + "\"}").utf8))
    }
}
