import Foundation

private let configLog = Logger(subsystem: "io.tonebox.baton", category: "NavidromeConfig")

/// One saved server in the multi-server list: everything needed to rebuild a
/// connection except the secret (which lives in the Keychain, keyed by `id`).
public struct NavidromeServerEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var urlString: String
    public var username: String
    public var authMode: NavidromeAuthMode
    /// Extra HTTP headers sent with every request to this server — the Cloudflare
    /// Access / Authelia pattern (e.g. CF-Access-Client-Id/Secret). Optional so
    /// existing persisted server lists decode unchanged.
    public var customHeaders: [String: String]?

    public init(
        id: UUID = UUID(),
        displayName: String,
        urlString: String,
        username: String,
        authMode: NavidromeAuthMode
    ) {
        self.id = id
        self.displayName = displayName
        self.urlString = urlString
        self.username = username
        self.authMode = authMode
    }
}

/// Persistence for Navidrome connections. Multi-server: a list of saved servers
/// plus an "active" one, stored in `UserDefaults`; each server's secret (password
/// or API key) is in the Keychain via `NavidromeKeychain`, keyed by the server id.
///
/// The historical single-server static API (`serverURLString`, `username`,
/// `authMode`, `secret`, `save`, `clear`, `credentials`, `isConfigured`,
/// `makeClient`, `verify`) is preserved verbatim and now transparently refers to
/// the *active* server, so every existing call-site behaves identically when there
/// is one server. A legacy single-server config is migrated into the list on first
/// access (zero data loss — the existing Keychain secret is adopted as-is).
public enum NavidromeConfig {
    // Legacy single-server keys (still the migration source, and still the
    // Keychain account for the migrated server so an existing secret is reused).
    public static let urlKey = "tonebox.navidrome.url"
    public static let usernameKey = "tonebox.navidrome.username"
    public static let authModeKey = "tonebox.navidrome.authMode"
    /// Keychain-backed (via `NavidromeKeychain`); the value is the account
    /// name under the shared `io.tonebox.secrets` service.
    public static let secretKey = "tonebox.navidromeSecret"

    // Multi-server keys.
    public static let serversKey = "tonebox.navidrome.servers"
    public static let activeServerKey = "tonebox.navidrome.activeServerId"

    // MARK: - Test isolation

    /// The `UserDefaults` suite backing config. Overridable in tests so a temp
    /// suite can be used without clobbering the user's real config. Defaults to
    /// `.standard` (production behavior, unchanged for every existing call-site).
    public nonisolated(unsafe) static var defaults: UserDefaults = BatonStorage.defaults

    /// The Keychain account used for a server with the given id. The migrated
    /// legacy server keeps the historical account (`secretKey`) so its existing
    /// stored secret is reused with no re-entry; new servers key by id.
    public static func keychainAccount(for id: UUID) -> String {
        migratedLegacyID == id ? secretKey : "tonebox.navidromeSecret.\(id.uuidString)"
    }

    /// A stable id derived from the legacy config, so migration is idempotent:
    /// re-running it (or running it on two builds) yields the same server id and
    /// reuses the same Keychain account. Derived from the legacy account name.
    nonisolated(unsafe) static let migratedLegacyID = UUID(
        uuidString: "0AB1E900-0000-4000-A000-000000000001"
    )!

    // MARK: - Server list

    /// All saved servers, migrating a legacy single-server config in on first read.
    public static func servers() -> [NavidromeServerEntry] {
        migrateLegacyIfNeeded()
        return storedServers()
    }

    /// The id of the active server, or nil when none is configured.
    public static func activeServerID() -> UUID? {
        migrateLegacyIfNeeded()
        let list = storedServers()
        if let raw = defaults.string(forKey: activeServerKey),
           let id = UUID(uuidString: raw),
           list.contains(where: { $0.id == id }) {
            return id
        }
        return list.first?.id
    }

    /// The active server entry, or nil when none is configured.
    public static func activeServer() -> NavidromeServerEntry? {
        guard let id = activeServerID() else { return nil }
        return storedServers().first { $0.id == id }
    }

    /// Adds a server (secret to the Keychain, metadata to the list) and returns
    /// its entry. If no server was active, the new one becomes active.
    @discardableResult
    public static func addServer(
        displayName: String,
        urlString: String,
        username: String,
        secret: String,
        authMode: NavidromeAuthMode
    ) -> NavidromeServerEntry {
        migrateLegacyIfNeeded()
        let entry = NavidromeServerEntry(
            displayName: displayName,
            urlString: urlString.trimmingCharacters(in: .whitespaces),
            username: username,
            authMode: authMode
        )
        var list = storedServers()
        list.append(entry)
        // The secret follows the list, not the other way round: a Keychain entry for a server
        // that is not in the list is orphaned, and nothing ever finds it again.
        guard writeServers(list) else { return entry }
        NavidromeKeychain.setSecret(secret, account: keychainAccount(for: entry.id))
        if defaults.string(forKey: activeServerKey) == nil {
            defaults.set(entry.id.uuidString, forKey: activeServerKey)
        }
        return entry
    }

    /// Updates an existing server's metadata (and secret, if non-nil). No-op if
    /// the id isn't in the list.
    public static func updateServer(
        id: UUID,
        displayName: String,
        urlString: String,
        username: String,
        authMode: NavidromeAuthMode,
        secret: String? = nil
    ) {
        migrateLegacyIfNeeded()
        var list = storedServers()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].displayName = displayName
        list[idx].urlString = urlString.trimmingCharacters(in: .whitespaces)
        list[idx].username = username
        list[idx].authMode = authMode
        writeServers(list)
        if let secret { NavidromeKeychain.setSecret(secret, account: keychainAccount(for: id)) }
    }

    /// Removes a server and its Keychain secret. If it was active, the first
    /// remaining server becomes active (or none if the list is now empty).
    public static func removeServer(id: UUID) {
        migrateLegacyIfNeeded()
        var list = storedServers()
        list.removeAll { $0.id == id }
        writeServers(list)
        NavidromeKeychain.deleteSecret(account: keychainAccount(for: id))
        if activeIDRaw() == id.uuidString {
            if let first = list.first {
                defaults.set(first.id.uuidString, forKey: activeServerKey)
            } else {
                defaults.removeObject(forKey: activeServerKey)
            }
        }
    }

    /// Makes the given server active. No-op if the id isn't in the list.
    public static func setActiveServer(id: UUID) {
        migrateLegacyIfNeeded()
        guard storedServers().contains(where: { $0.id == id }) else { return }
        defaults.set(id.uuidString, forKey: activeServerKey)
    }

    // MARK: - Active-server accessors (historical single-server API)

    public static var serverURLString: String {
        activeServer()?.urlString ?? ""
    }

    public static var serverURL: URL? {
        validatedURL(serverURLString)
    }

    /// A usable server URL: http/https only, with a host. Rejects `file://`, `ftp://`, and a
    /// hostless `https://` — a `file://` here would make `URLSession` read local files.
    public static func validatedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Whether the active server connects over cleartext http:// (for an "insecure" indicator).
    public static var isInsecureConnection: Bool {
        serverURL?.scheme?.lowercased() == "http"
    }

    /// Whether a candidate server URL string would connect over cleartext http:// — drives the
    /// connect flow's "unencrypted connection" warning. False for an invalid or https URL.
    public static func isInsecure(_ raw: String) -> Bool {
        validatedURL(raw)?.scheme?.lowercased() == "http"
    }

    public static var username: String {
        activeServer()?.username ?? ""
    }

    public static var authMode: NavidromeAuthMode {
        activeServer()?.authMode ?? .tokenSalt
    }

    /// The secret (password or API key) of the active server, read from the Keychain.
    public static var secret: String {
        guard let id = activeServerID() else { return "" }
        return NavidromeKeychain.secret(account: keychainAccount(for: id)) ?? ""
    }

    /// Persists the connection as the active server. When there's already an
    /// active server it's updated in place; otherwise a new server is added and
    /// made active. Preserves the legacy behavior of "one slot" for callers that
    /// still use it (e.g. a single-server disconnect/reconnect). The secret goes
    /// to the Keychain (no plaintext copy); everything else to `UserDefaults`.
    public static func save(urlString: String, username: String, secret: String, authMode: NavidromeAuthMode) {
        migrateLegacyIfNeeded()
        if let active = activeServer() {
            updateServer(
                id: active.id,
                displayName: active.displayName,
                urlString: urlString,
                username: username,
                authMode: authMode,
                secret: secret
            )
        } else {
            addServer(
                displayName: Self.defaultName(urlString: urlString, username: username),
                urlString: urlString,
                username: username,
                secret: secret,
                authMode: authMode
            )
        }
    }

    /// Clears the active server (used by a "Disconnect" button). Removes only the
    /// active server from the list, matching the historical single-server behavior
    /// when there is exactly one server.
    public static func clear() {
        migrateLegacyIfNeeded()
        if let id = activeServerID() {
            removeServer(id: id)
        }
        // Belt-and-suspenders: also drop legacy single-server keys if any linger.
        defaults.removeObject(forKey: urlKey)
        defaults.removeObject(forKey: usernameKey)
        defaults.removeObject(forKey: authModeKey)
    }

    /// Resolved credentials for building a `NavidromeClient`, or nil when the
    /// connection isn't fully configured. `.tokenSalt` needs a username; `.apiKey`
    /// does not.
    public static func credentials() -> NavidromeCredentials? {
        guard let url = serverURL else { return nil }
        let secret = secret
        guard !secret.isEmpty else { return nil }
        let mode = authMode
        if mode == .tokenSalt, username.isEmpty { return nil }
        return NavidromeCredentials(
            baseURL: url, username: username, secret: secret, authMode: mode,
            customHeaders: customHeaders()
        )
    }

    /// True when a client can be built (server + credentials present).
    public static var isConfigured: Bool {
        credentials() != nil
    }

    /// Shared URLSession with a sane request timeout for JSON endpoints — a wedged LAN server
    /// (a sleeping NAS, a half-up reverse proxy) then fails fast instead of stalling on
    /// URLSession.shared's 60 s default, which the interactive search/connect paths inherit.
    ///
    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        #if !os(Linux)
        config.waitsForConnectivity = false
        #endif // swift-corelibs-foundation exposes this read-only
        return URLSession(configuration: config)
    }()

    /// Builds a client from the stored config.
    ///
    /// Throws `.credentialsUnreadable` rather than `.notConfigured` when a server is on file
    /// and the Keychain will not answer. `credentials()` returns nil for both, and telling
    /// someone with a configured server to go and configure one is a dead end: the
    /// `storeReadFailure()` banner is only wired into Settings and Onboarding, which nobody
    /// visits when the library screen says they never set anything up (TBX-5268's other half).
    public static func makeClient(session: URLSession = sharedSession) throws -> NavidromeClient {
        if let credentials = credentials() {
            return NavidromeClient(credentials: credentials, session: session)
        }
        if let id = activeServerID(),
           case let .unreadable(status) = NavidromeKeychain.availability(account: keychainAccount(for: id)) {
            throw NavidromeError.credentialsUnreadable(status: status)
        }
        throw NavidromeError.notConfigured
    }

    /// The active server's extra HTTP headers ([:] when none).
    public static func customHeaders() -> [String: String] {
        activeServer()?.customHeaders ?? [:]
    }

    /// Replaces the active server's extra headers (empty dict clears them).
    public static func setCustomHeaders(_ headers: [String: String]) {
        guard var entry = activeServer() else { return }
        entry.customHeaders = headers.isEmpty ? nil : headers
        var list = servers()
        if let index = list.firstIndex(where: { $0.id == entry.id }) {
            list[index] = entry
            writeServers(list)
        }
    }

    // MARK: - Connect / verify

    /// Result of a connection test: reachable + authenticated, plus the
    /// OpenSubsonic extensions the server advertises (for the API-key path).
    public struct ConnectInfo: Equatable, Sendable {
        public var extensions: [String]

        /// Whether the OpenSubsonic extensions probe actually got a real answer from the
        /// server. False when it never completed — a classic (non-OpenSubsonic) server 404s
        /// the endpoint, and any other transport failure collapses here too — in which case
        /// `extensions` is empty but that must not be read as "the server confirmed it has no
        /// extensions." It means we don't know. Defaults to `true` so existing call sites that
        /// construct a `ConnectInfo` directly from a known extensions list (tests, mainly)
        /// keep their previous meaning.
        public var extensionsProbed: Bool

        public init(extensions: [String], extensionsProbed: Bool = true) {
            self.extensions = extensions
            self.extensionsProbed = extensionsProbed
        }

        public var supportsAPIKey: Bool {
            extensions.contains("apiKeyAuthentication") ||
                extensions.contains("apikeyauth") // pre-spec name used by older servers
        }

        /// True only when we have positive evidence the server does NOT support API-key
        /// auth: the probe completed and didn't report the extension. False — meaning
        /// "don't treat API key as broken" — whenever the probe never got a real answer,
        /// so a classic-Subsonic 404 (or any other probe failure) reads as unknown rather
        /// than as unsupported.
        public var apiKeyKnownUnsupported: Bool {
            extensionsProbed && !supportsAPIKey
        }
    }

    /// Verifies a candidate connection WITHOUT persisting it: pings (which
    /// authenticates) then best-effort probes extensions. Throws `NavidromeError`
    /// on failure so Settings can show the reason.
    public static func verify(
        urlString: String,
        username: String,
        secret: String,
        authMode: NavidromeAuthMode,
        customHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) async throws -> ConnectInfo {
        guard let url = validatedURL(urlString) else { // http/https + host only
            throw NavidromeError.invalidURL
        }
        if authMode == .tokenSalt, username.isEmpty {
            throw NavidromeError.notConfigured
        }
        guard !secret.isEmpty else { throw NavidromeError.notConfigured }
        let client = NavidromeClient(
            credentials: NavidromeCredentials(
                baseURL: url, username: username, secret: secret, authMode: authMode,
                customHeaders: customHeaders
            ),
            session: session
        )
        try await client.ping()
        // Extensions are informational — a classic server 404s this endpoint, and any other
        // failure here is equally uninformative (a flaky proxy, a timeout). Never fail the
        // connect over it, and keep track of whether the probe actually completed: an empty
        // result from a failed probe means "unknown", not "confirmed no extensions" — the
        // distinction `apiKeyKnownUnsupported` relies on.
        var extensions: [String] = []
        var extensionsProbed = false
        if let probed = try? await client.openSubsonicExtensions() {
            extensions = probed
            extensionsProbed = true
        }
        return ConnectInfo(extensions: extensions, extensionsProbed: extensionsProbed)
    }

    // MARK: - Naming helper

    /// A friendly default display name from a URL (host) falling back to username.
    public static func defaultName(urlString: String, username: String) -> String {
        let raw = urlString.trimmingCharacters(in: .whitespaces)
        if let host = URL(string: raw)?.host, !host.isEmpty { return host }
        if !username.isEmpty { return username }
        return raw.isEmpty ? "Server" : raw
    }

    // MARK: - Storage internals

    private static func activeIDRaw() -> String? {
        defaults.string(forKey: activeServerKey)
    }

    /// Where a server list that could not be read is kept, once, before anything overwrites it.
    ///
    /// The list used to decode all-or-nothing and fall back to `[]`, so a single bad entry
    /// dropped every configured server, the app said "no music server is configured", and the
    /// moment the user added one `writeServers` replaced the blob with a one-element list.
    /// Recovery was impossible by construction: `migrateLegacyIfNeeded` returns early while
    /// `serversKey` has data, and the Keychain secrets are keyed by the now-lost server UUIDs.
    /// The realistic trigger is a schema change, which means it would have hit everyone at once
    /// on one upgrade.
    public static let unreadableServersKey = "tonebox.navidrome.servers.unreadable"

    /// One element that failed to decode does not take the others with it.
    private struct SkippableEntry: Decodable {
        let entry: NavidromeServerEntry?
        init(from decoder: Decoder) throws {
            entry = try? NavidromeServerEntry(from: decoder)
        }
    }

    /// True when `serversKey` holds bytes that did not fully decode, so the next write must
    /// preserve them before overwriting.
    private static func storedServersAreDamaged(_ data: Data) -> Bool {
        if let clean = try? JSONDecoder().decode([NavidromeServerEntry].self, from: data) {
            // A clean decode of a shorter list than the array holds is not possible; if it
            // decoded at all, nothing was lost.
            _ = clean
            return false
        }
        return true
    }

    private static func storedServers() -> [NavidromeServerEntry] {
        guard let data = defaults.data(forKey: serversKey) else { return [] }
        if let list = try? JSONDecoder().decode([NavidromeServerEntry].self, from: data) { return list }
        // Whatever survives: an array whose elements changed shape (a new non-optional field,
        // an unknown auth mode after a downgrade) still yields every entry that did decode.
        // A blob damaged at the JSON level yields nothing here, and is preserved on write.
        let salvaged = (try? JSONDecoder().decode([SkippableEntry].self, from: data))?
            .compactMap(\.entry) ?? []
        configLog.error(
            "the saved server list did not decode; recovered \(salvaged.count, privacy: .public) of its entries"
        )
        return salvaged
    }

    /// Writes the list, preserving an unreadable blob first.
    ///
    /// A flat "refuse to write" would be worse than the bug: `writeServers` is on the add,
    /// update, remove, setActive and setCustomHeaders paths, so refusing would leave the app
    /// permanently unable to persist anything. Instead the unreadable bytes are copied aside,
    /// once, and the write proceeds, so the entries are still there to recover by hand.
    @discardableResult
    private static func writeServers(_ list: [NavidromeServerEntry]) -> Bool {
        if let existing = defaults.data(forKey: serversKey),
           defaults.data(forKey: unreadableServersKey) == nil,
           storedServersAreDamaged(existing) {
            defaults.set(existing, forKey: unreadableServersKey)
            configLog.error(
                "kept the unreadable server list under \(unreadableServersKey, privacy: .public) before overwriting it"
            )
        }
        // Add, update, remove, setActive and setCustomHeaders all land here, so this is where
        // a server that has been removed or re-pointed stops having a token held for it. A
        // secret changed on its own is caught by the cache itself, which revalidates the
        // stored token against the current password before reusing a salt.
        NavidromeSaltCache.removeAll()
        do {
            defaults.set(try JSONEncoder().encode(list), forKey: serversKey)
            return true
        } catch {
            // Was silent, which produced a server that existed in the Keychain and not in the
            // list: `addServer` writes the secret whether or not this landed.
            configLog.error(
                "couldn't encode the server list, so it was not saved: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Migrates a legacy single-server config into the list exactly once. Runs
    /// only when: no server list has been written yet AND legacy keys / secret
    /// exist. The migrated server adopts the historical Keychain account so its
    /// secret is reused with no re-entry, and becomes the active server.
    private static func migrateLegacyIfNeeded() {
        // Already migrated (or already multi-server): the list key exists.
        if defaults.data(forKey: serversKey) != nil { return }

        let legacyURL = (defaults.string(forKey: urlKey) ?? "").trimmingCharacters(in: .whitespaces)
        let legacyUser = defaults.string(forKey: usernameKey) ?? ""
        let legacyModeRaw = defaults.string(forKey: authModeKey) ?? ""
        let legacyMode = NavidromeAuthMode(rawValue: legacyModeRaw) ?? .tokenSalt
        // The legacy secret lives under the historical account (this also runs
        // that account's own plaintext-UserDefaults migrate-on-read).
        let legacySecret = NavidromeKeychain.secret(account: secretKey) ?? ""

        // Nothing to migrate → start with an empty list so this guard short-circuits
        // on subsequent calls (avoids re-probing the Keychain every access).
        guard !legacyURL.isEmpty || !legacySecret.isEmpty else {
            writeServers([])
            return
        }

        let entry = NavidromeServerEntry(
            id: migratedLegacyID,
            displayName: defaultName(urlString: legacyURL, username: legacyUser),
            urlString: legacyURL,
            username: legacyUser,
            authMode: legacyMode
        )
        writeServers([entry])
        // Secret already sits under `secretKey` (== keychainAccount(for: migratedLegacyID)),
        // so no Keychain write is needed — reuse it in place.
        defaults.set(entry.id.uuidString, forKey: activeServerKey)
        // Drop the legacy metadata keys now that they live in the list entry.
        defaults.removeObject(forKey: urlKey)
        defaults.removeObject(forKey: usernameKey)
        defaults.removeObject(forKey: authModeKey)
    }
}
