import Foundation

/// An incoming link, including a recognizable share whose key was omitted or damaged.
/// Keys remain in memory and are never part of a service URL or diagnostic description.
public struct ShareInvitation: Hashable, Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Codable, Sendable { case song, mixtape }
    public let kind: Kind
    public let id: String
    public let key: Data?

    public init(id: String, key: Data?, kind: Kind = .song) {
        self.kind = kind
        self.id = id
        self.key = key.flatMap { $0.count == ShareCrypto.keyLength ? $0 : nil }
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        let shareID: String
        let kind: Kind
        if parts.scheme?.lowercased() == "https",
           let host = parts.host?.lowercased(), ShareLink.hosts.contains(host),
           ["/s/", "/m/"].contains(String(parts.percentEncodedPath.prefix(3))) {
            kind = parts.percentEncodedPath.hasPrefix("/m/") ? .mixtape : .song
            shareID = String(parts.percentEncodedPath.dropFirst(3))
        } else if parts.scheme == "baton", ["share", "mixtape"].contains(parts.host ?? ""), parts.port == nil {
            kind = parts.host == "mixtape" ? .mixtape : .song
            shareID = String(parts.percentEncodedPath.dropFirst())
        } else { return nil }
        guard ShareLink.isValidID(shareID) else { return nil }
        let fragment = parts.percentEncodedFragment
        let key = fragment.flatMap(Base64URL.decode).flatMap { bytes in
            bytes.count == ShareCrypto.keyLength && Base64URL.encode(bytes) == fragment ? bytes : nil
        }
        self.init(id: shareID, key: key, kind: kind)
    }

    public func url(base: URL = ShareLink.defaultBase) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = "/\(kind == .mixtape ? "m" : "s")/\(id)"
        parts.query = nil; parts.fragment = key.map(Base64URL.encode)
        return parts.url!
    }

    public var browserURL: URL {
        var parts = URLComponents(url: ShareLink.defaultBase, resolvingAgainstBaseURL: false)!
        parts.path = "/\(kind == .mixtape ? "m" : "s")/\(id)"
        // AASA excludes this query, so choosing the browser does not reopen Baton.
        parts.queryItems = [URLQueryItem(name: "web", value: "1")]
        parts.fragment = key.map(Base64URL.encode)
        return parts.url!
    }

    public var description: String { "ShareInvitation(\(kind.rawValue), \(id), key withheld)" }
    public var debugDescription: String { description }
}

/// Counts listened time rather than seeking distance. All beacons are once per sheet session.
public struct SharedSongListening: Sendable {
    public private(set) var seconds: Double = 0
    private var lastPosition: Double?
    private var sentStart = false
    private var sent30 = false
    private var sentEnd = false

    public init() {}

    public mutating func resetPosition() { lastPosition = nil }

    public mutating func observe(position: Double, wallSeconds: Double, playing: Bool) -> [PlayerEvent.Kind] {
        guard position.isFinite, wallSeconds.isFinite else { return [] }
        defer { lastPosition = position }
        guard playing, let previous = lastPosition else { return [] }
        let delta = position - previous
        // A seek or an unmeasured/stalled timer interval is not evidence of listening.
        guard delta > 0, wallSeconds > 0, wallSeconds <= 2, delta <= wallSeconds + 0.25 else { return [] }
        seconds += min(delta, wallSeconds)
        var events: [PlayerEvent.Kind] = []
        if !sentStart { sentStart = true; events.append(.playStarted) }
        if seconds >= 30, !sent30 { sent30 = true; events.append(.played30s) }
        return events
    }

    public mutating func finished(successfully: Bool) -> [PlayerEvent.Kind] {
        guard successfully, !sentEnd else { return [] }
        sentEnd = true
        return [.playCompleted]
    }
}
