import BatonSubsonicKit
import CryptoKit
import Foundation
import OSLog

private let songIDLog = Logger(subsystem: "io.tonebox.baton", category: "MCPSongIDs")

/// The song ids agents see: opaque where the real id would say where a song lives
///
///
/// A podcast episode's id is its enclosure URL, and a clipping's or a demo track's is its file
/// URL. Sent as they are, they reach the agent's model provider and, from Telegram or Discord,
/// the chat platform: the Mac's folder names, and feed URLs that can carry tracking parameters.
/// Such an id goes out as `s1_` and the base64url HMAC-SHA256 of the real id, under a random key
/// kept in this Mac's Keychain, so the same song always gets the same id and the id says nothing.
/// A library id is the server's own opaque id already and goes out unchanged.
///
/// The map back lives in memory and in `mcp-song-ids.json` (0600) beside Baton's other files, so
/// an id an agent kept still resolves after a relaunch. It keeps the ids used most recently; an
/// id it has dropped is found again by recomputing the ids of the songs at hand (the queue,
/// history, downloads, clippings and podcast episodes), and one that is not among them is
/// refused as expired rather than passed to a tool that would answer about nothing.
///
/// Inputs are mapped back before any tool sees them, results are mapped on the way out, at one
/// place (`BatonMCPToolCatalog.run` and `BatonMCPResources.read`), so a tool written later gets
/// this without knowing about it.
@MainActor
final class MCPSongIDs {
    static let prefix = "s1_"
    static let keyAccount = "baton.mcp.songIDKey"
    /// The ids kept between calls. One reply may hold more (a long queue): every id in a reply is
    /// kept until the reply has gone, and the least recently used go first after it.
    static let maximumEntries = 5_000

    /// Keys whose value is a song id, in results and in arguments.
    static let idKeys: Set<String> = ["id", "song_id"]
    static let idListKeys: Set<String> = ["song_ids"]

    static var shared = MCPSongIDs.live()

    /// An `s1_` id this Mac cannot place: issued long ago, or by another install.
    struct Expired: Error, Equatable {
        let id: String
        var message: String {
            "This song id (\(id)) has expired; list again to get a current id (music_get_queue, music_search, history or podcast_episodes)."
        }
    }

    private let key: SymmetricKey
    private let storeURL: URL?
    private let capacity: Int
    private var originals: [String: String] = [:]
    private var lastUse: [String: Int] = [:]
    private var clock = 0
    private var unsaved = false

    /// How many arguments carried an old raw id, for the compatibility window and its test.
    private(set) var rawIDUses = 0

    init(key: Data, storeURL: URL?, capacity: Int = MCPSongIDs.maximumEntries) {
        self.key = SymmetricKey(data: key)
        self.storeURL = storeURL
        self.capacity = capacity
        load()
    }

    /// Under XCTest a key for the run and no file: a test that calls a tool must not write the
    /// owner's Keychain or Application Support.
    static func live(environment: BatonEnvironment = .current) -> MCPSongIDs {
        if environment.isTesting {
            return MCPSongIDs(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, storeURL: nil)
        }
        return MCPSongIDs(key: liveKey(), storeURL: BatonStorage.supportDirectory().appendingPathComponent("mcp-song-ids.json"))
    }

    /// The per-install key. A value that is not a key is logged and replaced, once; a locked
    /// Keychain gets a key for this run only, rather than an overwrite that would leave every id
    /// an agent holds pointing nowhere.
    private static func liveKey() -> Data {
        let fresh = { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
        switch NavidromeKeychain.availability(account: keyAccount) {
        case .unreadable:
            songIDLog.error("the Keychain did not answer; MCP song ids use a key for this run only")
            return fresh()
        case .present:
            if let saved = NavidromeKeychain.secret(account: keyAccount),
               let data = Data(base64Encoded: saved), data.count == 32 {
                return data
            }
            songIDLog.error("the MCP song id key in the Keychain is not a key; replacing it")
        case .missing:
            break
        }
        let key = fresh()
        if !NavidromeKeychain.setSecret(key.base64EncodedString(), account: keyAccount) {
            songIDLog.error("could not save the MCP song id key; ids last for this run only")
        }
        return key
    }

    /// Whether an id is a whole address or path: an http(s) URL with a host, a `file:` URL with
    /// a path, or `/` or `~` followed by more path. "/", "~" and "http://" alone are not.
    static func reveals(_ id: String) -> Bool {
        let lower = id.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return !(URL(string: id)?.host ?? "").isEmpty
        }
        if lower.hasPrefix("file:") {
            guard let url = URL(string: id), url.isFileURL else { return false }
            return url.path.contains { $0 != "/" }
        }
        if id.hasPrefix("/") || id.hasPrefix("~") {
            return id.dropFirst().contains { $0 != "/" }
        }
        return false
    }

    // MARK: - One id

    private func token(for id: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: key)
        return Self.prefix + Data(code).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The id an agent sees for `id`.
    func opaque(_ id: String) -> String {
        guard Self.reveals(id) else { return id }
        let token = token(for: id)
        touch(token, id)
        return token
    }

    /// The real id for one an agent sent, from the map alone: nil for an `s1_` id it does not
    /// hold. Anything else comes back as it is.
    ///
    /// **Compatibility window.** An agent may have kept a raw id from before `s1_` ids, so one is
    /// still accepted, and logged (without the id) so the window's use can be seen. Stop
    /// accepting them in the release after the one that introduces `s1_` ids.
    func original(_ id: String) -> String? {
        if id.hasPrefix(Self.prefix) {
            guard let real = originals[id] else { return nil }
            touch(id, real)
            return real
        }
        if Self.reveals(id) {
            rawIDUses += 1
            songIDLog.notice("an agent sent an old raw song id; accepted during the compatibility window")
        }
        return id
    }

    /// `original`, and on a miss the songs at hand searched for the one with this id.
    func resolve(_ id: String, among candidates: () -> [String]) throws -> String {
        if let real = original(id) { return real }
        for real in candidates() where Self.reveals(real) && token(for: real) == id {
            touch(id, real)
            return real
        }
        throw Expired(id: id)
    }

    // MARK: - A whole call

    /// Arguments with every song id mapped back, and the revealing real ids that came in, so a
    /// result that repeats one can be mapped too. `candidates` is asked at most once, and only
    /// when the map has lost an id.
    func incoming(_ arguments: [String: Any], candidates: () -> [String] = { [] }) throws
        -> (arguments: [String: Any], resolved: [String: String]) {
        var resolved: [String: String] = [:]
        var scanned: [String]?
        var failure: Expired?
        let mapped = map(arguments) { id in
            do {
                let real = try resolve(id) {
                    if scanned == nil { scanned = candidates() }
                    return scanned ?? []
                }
                if Self.reveals(real) { resolved[real] = opaque(real) }
                return real
            } catch let expired as Expired {
                failure = failure ?? expired
            } catch {}
            return id
        }
        if let failure { throw failure }
        return ((mapped as? [String: Any]) ?? arguments, resolved)
    }

    /// A result with every revealing song id replaced. In JSON: the id keys by value, and any
    /// other string value that is, or quotes, a revealing id this call was given. In plain text
    /// (an error message): those same ids where it quotes them. Ids that are not a whole address
    /// or path never reach `resolved`, so nothing else in a result is touched.
    func outgoing(_ text: String, resolved: [String: String] = [:]) -> String {
        var pinned = Set(resolved.values)
        var out = text
        if let first = text.first, first == "{" || first == "[",
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            var changed = false
            let mapped = map(object, other: { value in
                let quoted = Self.replacing(resolved, in: value)
                if quoted != value { changed = true }
                return quoted
            }) { id in
                let token = opaque(id)
                if token != id { changed = true; pinned.insert(token) }
                return token
            }
            if changed, let data = try? JSONSerialization.data(withJSONObject: mapped, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                out = string
            }
        } else {
            out = Self.replacing(resolved, in: text)
        }
        trim(keeping: pinned)
        save()
        return out
    }

    private static func replacing(_ resolved: [String: String], in value: String) -> String {
        if let token = resolved[value] { return token }
        var out = value
        for (real, token) in resolved where out.contains(real) {
            out = out.replacingOccurrences(of: real, with: token)
        }
        return out
    }

    /// Song id keys through `transform`; every other string value through `other`.
    private func map(_ value: Any, other: ((String) -> String)? = nil, _ transform: (String) -> String) -> Any {
        if let dictionary = value as? [String: Any] {
            var out = dictionary
            for (key, item) in dictionary {
                if Self.idKeys.contains(key), let id = item as? String {
                    out[key] = transform(id)
                } else if Self.idListKeys.contains(key), let ids = item as? [String] {
                    out[key] = ids.map(transform)
                } else if let string = item as? String, let other {
                    out[key] = other(string)
                } else if item is [String: Any] || item is [Any] {
                    out[key] = map(item, other: other, transform)
                }
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { item -> Any in
                if let string = item as? String, let other { return other(string) }
                return map(item, other: other, transform)
            }
        }
        return value
    }

    // MARK: - Keeping the map

    private func touch(_ token: String, _ id: String) {
        clock += 1
        lastUse[token] = clock
        if originals[token] != id {
            originals[token] = id
            unsaved = true
        }
    }

    /// Least recently used first, never an id in the reply going out now.
    private func trim(keeping pinned: Set<String>) {
        let excess = originals.count - capacity
        guard excess > 0 else { return }
        let oldest = lastUse.filter { !pinned.contains($0.key) }.sorted { $0.value < $1.value }.prefix(excess)
        for (token, _) in oldest {
            originals[token] = nil
            lastUse[token] = nil
        }
        unsaved = true
    }

    private struct Stored: Codable {
        var version = 1
        /// `[token, original]`, least recently used first.
        var ids: [[String]]
    }

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        for pair in stored.ids where pair.count == 2 && pair[0].hasPrefix(Self.prefix) {
            touch(pair[0], pair[1])
        }
        unsaved = false
    }

    private func save() {
        guard unsaved, let storeURL else { return }
        unsaved = false
        let ordered = lastUse.sorted { $0.value < $1.value }.compactMap { token, _ in originals[token].map { [token, $0] } }
        guard let data = try? JSONEncoder().encode(Stored(ids: ordered)) else { return }
        // Written whole to a file that is 0600 from its first byte, then swapped in, so the map
        // is never half written and never readable by anyone else, even for a moment.
        let staging = storeURL.deletingLastPathComponent().appendingPathComponent(".\(storeURL.lastPathComponent).\(UUID().uuidString)")
        do {
            guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if FileManager.default.fileExists(atPath: storeURL.path) {
                _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: storeURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            songIDLog.error("could not save the MCP song id map: \(error.localizedDescription)")
        }
    }
}
