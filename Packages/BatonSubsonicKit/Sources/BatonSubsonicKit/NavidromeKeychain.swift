import Foundation
#if canImport(Security)
import Security
#endif

private let navidromeSecretsLog = Logger(subsystem: "io.tonebox.baton", category: "navidrome-secrets")

/// Keychain storage for the Navidrome connection secret (password or API
/// key), fully self-contained so the music player can be extracted into a
/// standalone app without depending on Tonebox's `AIConfig` / AI secret
/// plumbing.
///
/// The item coordinates below are replicated EXACTLY from the path the
/// secret used to travel (`AIConfig.setSecretString` → `KeychainSecretStore`
/// → `KeychainStore`), so existing users keep their stored secret with zero
/// migration and no re-entry:
///
/// - class:        `kSecClassGenericPassword`
/// - service:      `io.tonebox.secrets`
/// - account:      `tonebox.navidromeSecret`
/// - accessible:   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// - no access group
///
/// It also preserves the historical migrate-on-read from a plaintext
/// `UserDefaults` copy (and the "remove the plaintext copy on write")
/// behavior, matching `AIConfig.secretString` / `setSecretString` exactly.
public enum NavidromeKeychain {
    /// Keychain service shared by all Tonebox secrets. Matches
    /// `KeychainSecretStore.service`.
    public static let service = "io.tonebox.secrets"

    /// Account/key for the Navidrome secret. Matches
    /// `NavidromeConfig.secretKey` (the former UserDefaults key).
    public static let account = "tonebox.navidromeSecret"

    /// Test-only in-memory backing. When set, all reads/writes/deletes go here
    /// instead of the real Keychain, so multi-server tests are hermetic and never
    /// clobber the user's stored secret. Nil in production (Security framework).
    public nonisolated(unsafe) static var inMemoryStore: [String: Data]?

    /// The stored secret for the default (legacy) account, or nil when none is
    /// set. See `secret(account:)`.
    public static func secret() -> String? {
        secret(account: account)
    }

    /// The stored secret for `account`, or nil when none is set. Migrates a
    /// legacy plaintext `UserDefaults` value into the Keychain on first read
    /// (then drops the plaintext copy), mirroring the old `AIConfig.secretString`
    /// behavior. Multi-server keys each server's secret under its own account.
    public static func secret(account: String) -> String? {
        if let data = read(account: account), let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let ud = UserDefaults.standard
        if let legacy = ud.string(forKey: account), !legacy.isEmpty {
            write(Data(legacy.utf8), account: account) // migrate-on-read
            ud.removeObject(forKey: account)            // drop the plaintext copy
            return legacy
        }
        return nil
    }

    /// Writes the secret for the default (legacy) account. See `setSecret(_:account:)`.
    public static func setSecret(_ value: String) {
        setSecret(value, account: account)
    }

    /// Writes the secret to the Keychain under `account` and removes any
    /// plaintext `UserDefaults` copy. An empty/whitespace-only value deletes the
    /// item so an empty secret never lingers.
    public static func setSecret(_ value: String, account: String) {
        if value.isEmpty {
            deleteSecret(account: account)
        } else {
            write(Data(value.utf8), account: account)
        }
        UserDefaults.standard.removeObject(forKey: account)
    }

    /// Removes the stored secret for the default (legacy) account.
    public static func deleteSecret() {
        deleteSecret(account: account)
    }

    /// Removes the stored secret under `account`.
    public static func deleteSecret(account: String) {
        ensureTestIsolation()
        if inMemoryStore != nil {
            inMemoryStore?[account] = nil
            return
        }
        #if !canImport(Security)
        LinuxSecretFile.delete(account: account)
        return
        #else
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            navidromeSecretsLog.error("Keychain delete failed: \(status, privacy: .public)")
        }
        #endif
    }

    // MARK: - Raw Security-framework access

    /// Under XCTest, route all access through the in-memory store by default so tests never
    /// touch (or prompt for) the real login Keychain. Tests that need a specific fixture set
    /// `inMemoryStore` explicitly; this only kicks in when they haven't.
    private static func ensureTestIsolation() {
        if inMemoryStore == nil, BatonEnvironment.current.isTesting { inMemoryStore = [:] }
    }

    private static func read(account: String) -> Data? {
        ensureTestIsolation()
        if let store = inMemoryStore { return store[account] }
        #if !canImport(Security)
        return LinuxSecretFile.read(account: account)
        #else
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            navidromeSecretsLog.error("Keychain read failed: \(status, privacy: .public)")
            return nil
        }
        #endif
    }

    private static func write(_ data: Data, account: String) {
        ensureTestIsolation()
        if inMemoryStore != nil {
            inMemoryStore?[account] = data
            return
        }
        #if !canImport(Security)
        LinuxSecretFile.write(data, account: account)
        #else
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            for (k, v) in attributes { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                navidromeSecretsLog.error("Keychain add failed: \(addStatus, privacy: .public)")
            }
        default:
            navidromeSecretsLog.error("Keychain update failed: \(updateStatus, privacy: .public)")
        }
        #endif
    }
}

#if !canImport(Security)
/// Linux has no Keychain. Secrets live in a 0600 JSON file under the user's
/// config directory — the same trust model as an SSH private key, which is the
/// right bar for a service account on a home server.
enum LinuxSecretFile {
    private static var url: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("baton/secrets.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return json
    }

    static func read(account: String) -> Data? {
        load()[account].map { Data($0.utf8) }
    }

    static func write(_ data: Data, account: String) {
        var store = load()
        store[account] = String(data: data, encoding: .utf8) ?? ""
        persist(store)
    }

    static func delete(account: String) {
        var store = load()
        store[account] = nil
        persist(store)
    }

    private static func persist(_ store: [String: String]) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
