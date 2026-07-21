import Foundation

/// One saved server in the multi-server list: everything needed to rebuild a
/// connection except the secret (which lives in the Keychain, keyed by `id`).
struct NavidromeServerEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var urlString: String
    var username: String
    var authMode: NavidromeAuthMode

    init(
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
enum NavidromeConfig {
    // Legacy single-server keys (still the migration source, and still the
    // Keychain account for the migrated server so an existing secret is reused).
    static let urlKey = "tonebox.navidrome.url"
    static let usernameKey = "tonebox.navidrome.username"
    static let authModeKey = "tonebox.navidrome.authMode"
    /// Keychain-backed (via `NavidromeKeychain`); the value is the account
    /// name under the shared `io.tonebox.secrets` service.
    static let secretKey = "tonebox.navidromeSecret"

    // Multi-server keys.
    static let serversKey = "tonebox.navidrome.servers"
    static let activeServerKey = "tonebox.navidrome.activeServerId"

    // MARK: - Test isolation

    /// The `UserDefaults` suite backing config. Overridable in tests so a temp
    /// suite can be used without clobbering the user's real config. Defaults to
    /// `.standard` (production behavior, unchanged for every existing call-site).
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The Keychain account used for a server with the given id. The migrated
    /// legacy server keeps the historical account (`secretKey`) so its existing
    /// stored secret is reused with no re-entry; new servers key by id.
    static func keychainAccount(for id: UUID) -> String {
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
    static func servers() -> [NavidromeServerEntry] {
        migrateLegacyIfNeeded()
        return storedServers()
    }

    /// The id of the active server, or nil when none is configured.
    static func activeServerID() -> UUID? {
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
    static func activeServer() -> NavidromeServerEntry? {
        guard let id = activeServerID() else { return nil }
        return storedServers().first { $0.id == id }
    }

    /// Adds a server (secret to the Keychain, metadata to the list) and returns
    /// its entry. If no server was active, the new one becomes active.
    @discardableResult
    static func addServer(
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
        writeServers(list)
        NavidromeKeychain.setSecret(secret, account: keychainAccount(for: entry.id))
        if defaults.string(forKey: activeServerKey) == nil {
            defaults.set(entry.id.uuidString, forKey: activeServerKey)
        }
        return entry
    }

    /// Updates an existing server's metadata (and secret, if non-nil). No-op if
    /// the id isn't in the list.
    static func updateServer(
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
    static func removeServer(id: UUID) {
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
    static func setActiveServer(id: UUID) {
        migrateLegacyIfNeeded()
        guard storedServers().contains(where: { $0.id == id }) else { return }
        defaults.set(id.uuidString, forKey: activeServerKey)
    }

    // MARK: - Active-server accessors (historical single-server API)

    static var serverURLString: String {
        activeServer()?.urlString ?? ""
    }

    static var serverURL: URL? {
        validatedURL(serverURLString)
    }

    /// A usable server URL: http/https only, with a host. Rejects `file://`, `ftp://`, and a
    /// hostless `https://` — a `file://` here would make `URLSession` read local files. (W-16)
    static func validatedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Whether the active server connects over cleartext http:// (for an "insecure" indicator).
    static var isInsecureConnection: Bool {
        serverURL?.scheme?.lowercased() == "http"
    }

    /// Whether a candidate server URL string would connect over cleartext http:// — drives the
    /// connect flow's "unencrypted connection" warning. False for an invalid or https URL. (W-59)
    static func isInsecure(_ raw: String) -> Bool {
        validatedURL(raw)?.scheme?.lowercased() == "http"
    }

    static var username: String {
        activeServer()?.username ?? ""
    }

    static var authMode: NavidromeAuthMode {
        activeServer()?.authMode ?? .tokenSalt
    }

    /// The secret (password or API key) of the active server, read from the Keychain.
    static var secret: String {
        guard let id = activeServerID() else { return "" }
        return NavidromeKeychain.secret(account: keychainAccount(for: id)) ?? ""
    }

    /// Persists the connection as the active server. When there's already an
    /// active server it's updated in place; otherwise a new server is added and
    /// made active. Preserves the legacy behavior of "one slot" for callers that
    /// still use it (e.g. a single-server disconnect/reconnect). The secret goes
    /// to the Keychain (no plaintext copy); everything else to `UserDefaults`.
    static func save(urlString: String, username: String, secret: String, authMode: NavidromeAuthMode) {
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
    static func clear() {
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
    static func credentials() -> NavidromeCredentials? {
        guard let url = serverURL else { return nil }
        let secret = secret
        guard !secret.isEmpty else { return nil }
        let mode = authMode
        if mode == .tokenSalt, username.isEmpty { return nil }
        return NavidromeCredentials(baseURL: url, username: username, secret: secret, authMode: mode)
    }

    /// True when a client can be built (server + credentials present).
    static var isConfigured: Bool {
        credentials() != nil
    }

    /// Shared URLSession with a sane request timeout for JSON endpoints — a wedged LAN server
    /// (a sleeping NAS, a half-up reverse proxy) then fails fast instead of stalling on
    /// URLSession.shared's 60 s default, which the interactive search/connect paths inherit.
    /// (W-25 / NET-01)
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Builds a client from the stored config, or throws `.notConfigured`.
    static func makeClient(session: URLSession = sharedSession) throws -> NavidromeClient {
        guard let credentials = credentials() else { throw NavidromeError.notConfigured }
        return NavidromeClient(credentials: credentials, session: session)
    }

    // MARK: - Connect / verify

    /// Result of a connection test: reachable + authenticated, plus the
    /// OpenSubsonic extensions the server advertises (for the API-key path).
    struct ConnectInfo: Equatable {
        var extensions: [String]
        var supportsAPIKey: Bool {
            extensions.contains("apikeyauth")
        }
    }

    /// Verifies a candidate connection WITHOUT persisting it: pings (which
    /// authenticates) then best-effort probes extensions. Throws `NavidromeError`
    /// on failure so Settings can show the reason.
    static func verify(
        urlString: String,
        username: String,
        secret: String,
        authMode: NavidromeAuthMode,
        session: URLSession = .shared
    ) async throws -> ConnectInfo {
        guard let url = validatedURL(urlString) else { // http/https + host only (W-16)
            throw NavidromeError.invalidURL
        }
        if authMode == .tokenSalt, username.isEmpty {
            throw NavidromeError.notConfigured
        }
        guard !secret.isEmpty else { throw NavidromeError.notConfigured }
        let client = NavidromeClient(
            credentials: NavidromeCredentials(baseURL: url, username: username, secret: secret, authMode: authMode),
            session: session
        )
        try await client.ping()
        // Extensions are informational — a classic server 404s this endpoint;
        // treat any failure as "no extensions" rather than failing the connect.
        let extensions = await (try? client.openSubsonicExtensions()) ?? []
        return ConnectInfo(extensions: extensions)
    }

    // MARK: - Naming helper

    /// A friendly default display name from a URL (host) falling back to username.
    static func defaultName(urlString: String, username: String) -> String {
        let raw = urlString.trimmingCharacters(in: .whitespaces)
        if let host = URL(string: raw)?.host, !host.isEmpty { return host }
        if !username.isEmpty { return username }
        return raw.isEmpty ? "Server" : raw
    }

    // MARK: - Storage internals

    private static func activeIDRaw() -> String? {
        defaults.string(forKey: activeServerKey)
    }

    private static func storedServers() -> [NavidromeServerEntry] {
        guard let data = defaults.data(forKey: serversKey) else { return [] }
        return (try? JSONDecoder().decode([NavidromeServerEntry].self, from: data)) ?? []
    }

    private static func writeServers(_ list: [NavidromeServerEntry]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: serversKey)
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
