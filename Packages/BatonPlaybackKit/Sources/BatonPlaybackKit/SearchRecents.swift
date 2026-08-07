import CryptoKit
import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// The albums and artists you opened from search, most recent first — on every device.
///
/// Search had no memory: every session started from a blank field, and the thing you
/// looked for yesterday cost the same typing today. What's stored is the *entity* you
/// opened — not the query string — because "Dido → 3 albums" is what you wanted, and the
/// string you typed to get there is trivia. `FilterHistory` remembers the strings; the two
/// are complementary and both sync.
///
/// Songs are deliberately not recorded. Tapping a song in search *plays* it; recording it
/// would fill the list with one-off plays and crowd out the artists and albums that are
/// actually worth returning to.
///
/// **Entries are scoped to a server.** They hold Navidrome ids, and an id means nothing on
/// a different server — unscoped, pointing the phone at a second library would show a list
/// of rows that open onto errors. The fingerprint is derived from the server URL and
/// username rather than the local server UUID, because those UUIDs are minted per device:
/// the same physical server added on the Mac and on the phone has two different ones, so
/// syncing on UUID would never match anything.
@MainActor
@Observable
public final class SearchRecents {
    public struct Entry: Identifiable, Codable, Equatable {
        public enum Kind: String, Codable { case album, artist }
        public let kind: Kind
        public let id: String
        public let title: String
        public var subtitle: String?
        public var coverArtID: String?
        /// When this was last opened, on whichever device opened it. The merge needs a real
        /// timestamp: position in a list only says "recent here", which is unorderable
        /// against another device's list.
        public var lastOpened: Date
        /// Which server these ids belong to. `nil` means "written before scoping existed"
        /// and stays visible everywhere, so nobody's list empties on upgrade. Anything
        /// written *now* gets a real value — including the demo library, which uses
        /// `SearchRecents.unscoped`; without that, demo albums would inherit the
        /// legacy rule and follow you onto a real server as rows that open onto errors.
        public var serverID: String?

        public init(kind: Kind, id: String, title: String, subtitle: String? = nil,
                    coverArtID: String? = nil, lastOpened: Date = Date(),
                    serverID: String? = nil) {
            self.kind = kind
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.coverArtID = coverArtID
            self.lastOpened = lastOpened
            self.serverID = serverID
        }

        /// Hand-rolled so entries written before `lastOpened`/`serverID` existed still
        /// decode. A synthesized initializer would throw on them and silently empty the list.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            coverArtID = try c.decodeIfPresent(String.self, forKey: .coverArtID)
            lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? .distantPast
            serverID = try c.decodeIfPresent(String.self, forKey: .serverID)
        }
    }

    /// Everything known, across every server. `visible` is what a screen shows.
    public private(set) var all: [Entry] = []

    public static let storageKey = "baton.search.recents"
    /// Enough to be useful, few enough to scan. Per server, so a second library doesn't
    /// evict the first one's list.
    public static let cap = 10

    /// Stands in for a server when none is configured — the demo library, or before
    /// sign-in. A real value rather than `nil` so these entries are scoped like any other.
    public static let unscoped = "local"

    private let defaults: UserDefaults
    private var serverID: String

    public init(defaults: UserDefaults = .standard, serverID: String? = nil) {
        self.defaults = defaults
        self.serverID = serverID ?? Self.currentServerFingerprint(defaults: defaults) ?? Self.unscoped
        reload()
    }

    /// Re-read from disk — call after a sync has merged in another device's entries.
    public func reload() {
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            all = saved
        } else {
            all = []
        }
    }

    /// Point at a different server (sign-in, or switching servers).
    public func setServer(_ id: String?) {
        serverID = id ?? Self.unscoped
        reload()
    }

    /// What this server's screens show, most recent first.
    public var entries: [Entry] {
        all.filter { $0.serverID == nil || $0.serverID == serverID }
            .sorted { $0.lastOpened > $1.lastOpened }
    }

    public func record(album: NavidromeAlbum) {
        record(Entry(kind: .album, id: album.id, title: album.name,
                     subtitle: album.artist, coverArtID: album.coverArtID,
                     serverID: serverID))
    }

    public func record(artist: NavidromeArtist) {
        let subtitle = artist.albumCount.map { "\($0) album\($0 == 1 ? "" : "s")" }
        record(Entry(kind: .artist, id: artist.id, title: artist.name,
                     subtitle: subtitle, coverArtID: artist.coverArtID,
                     serverID: serverID))
    }

    /// Re-opening something moves it to the top rather than duplicating it — the list is
    /// "what I come back to", and a duplicate says nothing a promotion doesn't.
    private func record(_ entry: Entry) {
        all.removeAll { $0.kind == entry.kind && $0.id == entry.id && $0.serverID == entry.serverID }
        all.insert(entry, at: 0)
        all = Self.capped(all)
        persist()
    }

    /// Clears this server's entries only. Another library's list isn't yours to discard.
    public func clear() {
        all.removeAll { $0.serverID == nil || $0.serverID == serverID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - Merge

    /// Union two devices' lists rather than letting one replace the other.
    ///
    /// Last-write-wins is right for a scalar and wrong for a list that accumulates: it
    /// would drop everything opened on the quieter device the moment the other one wrote.
    /// Same entity on both sides keeps the later `lastOpened`, and the cap is applied per
    /// server so a second library can't evict the first one's list.
    public static func merge(_ a: [Entry], _ b: [Entry]) -> [Entry] {
        var best: [String: Entry] = [:]
        for entry in a + b {
            let key = "\(entry.serverID ?? "")|\(entry.kind.rawValue)|\(entry.id)"
            if let existing = best[key], existing.lastOpened >= entry.lastOpened { continue }
            best[key] = entry
        }
        return capped(best.values.sorted { $0.lastOpened > $1.lastOpened })
    }

    /// Newest first, capped per server.
    static func capped(_ entries: [Entry]) -> [Entry] {
        let ordered = entries.sorted { $0.lastOpened > $1.lastOpened }
        var perServer: [String: Int] = [:]
        return ordered.filter { entry in
            let key = entry.serverID ?? ""
            let count = perServer[key, default: 0]
            guard count < cap else { return false }
            perServer[key] = count + 1
            return true
        }
    }

    // MARK: - Server identity

    /// A stable id for "this server, this account", equal on every device that signs in the
    /// same way. Hashed rather than stored raw: it travels through the shared state
    /// document, and a LAN hostname is not something to scatter further than it needs to go.
    public static func fingerprint(urlString: String, username: String) -> String {
        var url = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while url.hasSuffix("/") { url.removeLast() }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data("\(url)|\(user)".utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    /// The active server's fingerprint, or `nil` when nothing is configured.
    ///
    /// Reads the **server list**, not the legacy `tonebox.navidrome.url` /
    /// `.username` keys. `NavidromeConfig.save` has routed every sign-in through
    /// `addServer`/`updateServer` since multi-server support landed, so on a current
    /// install those legacy keys are simply absent — and reading them yields "no server
    /// configured" on a machine that plainly has one. That scopes each device's history
    /// under a different id, and two devices that never share a scope never share a list:
    /// the sync would run, report success, and move nothing. Found by driving the Mac, not
    /// by a test — every unit test here passed with it broken.
    ///
    /// `server` is a defaulted parameter rather than a direct call so tests can supply one;
    /// default arguments are evaluated per call, so the lookup still happens at call time.
    public static func currentServerFingerprint(
        defaults: UserDefaults = .standard,
        server: NavidromeServerEntry? = NavidromeConfig.activeServer()
    ) -> String? {
        if let server, !server.urlString.isEmpty, !server.username.isEmpty {
            return fingerprint(urlString: server.urlString, username: server.username)
        }
        // Pre-multi-server installs that haven't signed in again since.
        guard let url = defaults.string(forKey: NavidromeConfig.urlKey), !url.isEmpty,
              let user = defaults.string(forKey: NavidromeConfig.usernameKey), !user.isEmpty
        else { return nil }
        return fingerprint(urlString: url, username: user)
    }

    // MARK: - Navigation

    /// Rebuilds the navigable entity. The detail screens fetch their own truth from the
    /// id; what's stored is only enough to draw the row and open the door.
    public func album(for entry: Entry) -> NavidromeAlbum? {
        guard entry.kind == .album else { return nil }
        return NavidromeAlbum(id: entry.id, name: entry.title,
                              artist: entry.subtitle, coverArtID: entry.coverArtID)
    }

    public func artist(for entry: Entry) -> NavidromeArtist? {
        guard entry.kind == .artist else { return nil }
        return NavidromeArtist(id: entry.id, name: entry.title, coverArtID: entry.coverArtID)
    }
}
