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
/// behavior, matching `AIConfig.secretString` / `setSecretString` exactly — with one
/// deliberate departure: the plaintext copy is dropped only once the Keychain write has
/// actually succeeded. The original dropped it unconditionally, which destroyed the secret
/// outright whenever the Keychain was locked.
public enum NavidromeKeychain {
    /// Keychain service shared by all Tonebox secrets. Matches
    /// `KeychainSecretStore.service`.
    ///
    /// A probe launch gets its own service, so the throwaway device starts with no credentials
    /// and — the half that matters — cannot overwrite the owner's stored Navidrome password when
    /// somebody types one into its Settings. The Keychain is the one piece of state that a
    /// redirected preferences domain does not carry with it, so it is named here rather than left
    /// as a footnote.
    public static let service: String = {
        guard let suite = BatonStorage.current.suiteName else { return "io.tonebox.secrets" }
        return "io.tonebox.secrets.probe.\(suite)"
    }()

    /// Account/key for the Navidrome secret. Matches
    /// `NavidromeConfig.secretKey` (the former UserDefaults key).
    public static let account = "tonebox.navidromeSecret"

    /// Test-only in-memory backing. When set, all reads/writes/deletes go here
    /// instead of the real Keychain, so multi-server tests are hermetic and never
    /// clobber the user's stored secret. Nil in production (Security framework).
    public nonisolated(unsafe) static var inMemoryStore: [String: Data]?

    /// Accounts the in-memory store refuses to write, so the failure path is testable.
    /// Consulted only while `inMemoryStore` is active — never in production.
    public nonisolated(unsafe) static var refusedAccounts: Set<String> = []

    /// Why a secret is not in hand. A caller holding only `String?` cannot tell `missing`
    /// from `unreadable`, and the two want opposite things from the user: one asks them to
    /// type a password, the other tells them typing it again will not help because the
    /// Keychain is locked. Collapsing them is what made a locked Keychain present as an app
    /// that "did not start properly", with the reason sitting in `os_log` where nobody looks
    ///.
    ///
    /// `status` is `Int32` rather than `OSStatus` so this type still compiles on Linux, where
    /// there is no Security framework and `unreadable` never occurs.
    public enum SecretAvailability: Equatable, Sendable {
        case present
        case missing
        case unreadable(status: Int32)

        /// Whether the Keychain answered at all. `false` only for `unreadable`.
        public var isReadable: Bool {
            if case .unreadable = self { return false }
            return true
        }
    }

    /// Launch argument that makes every read report `unreadable` with the given status, so the
    /// banner this drives can be photographed without locking the owner's real login Keychain
    /// — which would take `codesign`, and every other app on the machine, down with it.
    ///
    /// `-baton.keychainUnreadable -25293` reproduces the Keychain-is-locked state exactly.
    /// Namespaced and absent from every menu, in the idiom of `BatonStorage`'s probe flags, and
    /// read-only in effect: it makes reads fail, writes nothing, and is gone on the next launch.
    public static let simulatedReadFailureArgument = "-baton.keychainUnreadable"

    /// Parsed once from the launch arguments. Nil in every ordinary run.
    private static let launchSimulatedReadFailure: Int32? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: simulatedReadFailureArgument), i + 1 < args.count,
              let status = Int32(args[i + 1]) else { return nil }
        navidromeSecretsLog.error(
            "Simulating Keychain read failure \(status, privacy: .public) for every account (launch argument)")
        return status
    }()

    /// A read failure simulated by a test, overriding the launch argument. Nil in production.
    public nonisolated(unsafe) static var simulatedReadFailure: Int32?

    private static var effectiveSimulatedReadFailure: Int32? {
        simulatedReadFailure ?? launchSimulatedReadFailure
    }

    /// Whether `account`'s secret is present, absent, or unreadable. The question
    /// `secret(account:)` cannot answer, and the one a settings surface has to ask before it
    /// renders an empty password field as if nothing were ever saved.
    public static func availability(account: String) -> SecretAvailability {
        switch rawRead(account: account) {
        case .value: return .present
        case .unreadable(let status): return .unreadable(status: status)
        case .missing:
            // A legacy plaintext value still counts as present: `secret(account:)` would
            // migrate and return it, so reporting `missing` here would contradict it.
            if let legacy = BatonStorage.defaults.string(forKey: account), !legacy.isEmpty {
                return .present
            }
            return .missing
        }
    }

    /// The status behind a Keychain that will not answer *at all* right now, or nil when it
    /// answers. Independent of any one account.
    ///
    /// A locked Keychain is not a property of one secret — it takes out every account at once,
    /// including ones this device has never stored. So the probe deliberately asks about an
    /// account that does not exist: `errSecItemNotFound` proves the store answered, and only a
    /// genuine `unreadable` comes back otherwise. Asking about a real account instead would
    /// conflate "you have not set this one up" with "nothing can be read".
    public static func storeReadFailure() -> Int32? {
        if case .unreadable(let status) = rawRead(account: readabilityProbeAccount) { return status }
        return nil
    }

    /// Whether the Keychain answers at all. See `storeReadFailure()` for the reason when it does not.
    public static func storeIsReadable() -> Bool { storeReadFailure() == nil }

    /// Deliberately never written. See `storeIsReadable()`.
    private static let readabilityProbeAccount = "tonebox.keychainReadabilityProbe"

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
        let raw = rawRead(account: account)
        if case .value(let data) = raw, let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let ud = BatonStorage.defaults
        guard let legacy = ud.string(forKey: account), !legacy.isEmpty else { return nil }

        // Migrate-on-read, but only when the Keychain is actually answering. Attempting it
        // against a locked Keychain used to destroy the secret: `write` failed, its result was
        // discarded, and the plaintext copy was removed anyway — so the one surviving copy went
        // with it. The value is still returned either way, so a locked Keychain costs the user
        // nothing but a retry.
        if case .unreadable = raw { return legacy }
        if write(Data(legacy.utf8), account: account) {
            ud.removeObject(forKey: account) // drop the plaintext copy, now that there is another
        }
        return legacy
    }

    /// Writes the secret for the default (legacy) account. See `setSecret(_:account:)`.
    public static func setSecret(_ value: String) {
        setSecret(value, account: account)
    }

    /// Writes the secret to the Keychain under `account` and removes any
    /// plaintext `UserDefaults` copy. An empty/whitespace-only value deletes the
    /// item so an empty secret never lingers.
    /// Returns whether the secret is now stored as asked.
    ///
    /// It used to return `Void` and swallow the `SecItem` status, logging it and moving on.
    /// That let `SettingsTransfer.applyImport` count *attempts* as applied secrets, so an
    /// import could report "1 secret" over a Keychain that had rejected the write — and the
    /// same sheet would then say there was nothing to test, because the friend was not
    /// configured without it. Two true statements that together describe something false
    ///.
    ///
    /// `@discardableResult` because most callers are writing a value the user just typed on
    /// a screen that will show them the outcome anyway; the ones that report a count are the
    /// ones that must not ignore it.
    @discardableResult
    public static func setSecret(_ value: String, account: String) -> Bool {
        let stored: Bool
        if value.isEmpty {
            deleteSecret(account: account)
            stored = true          // asked for absence, and absence is what there now is
        } else {
            stored = write(Data(value.utf8), account: account)
        }
        // Only drop the legacy plaintext copy once the Keychain actually holds the value.
        // This is the same bug TBX-5268 fixed on the read path: on a device still holding a
        // legacy value, a write refused under errSecInteractionNotAllowed used to remove the
        // only surviving copy of the credential. The type's own header promises otherwise.
        if stored { BatonStorage.defaults.removeObject(forKey: account) }
        return stored
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

    /// The three outcomes the Keychain actually has. `read(account:)` throws the reason away
    /// for the many callers that only want a value; `availability(account:)` keeps it.
    private enum RawRead {
        case value(Data)
        case missing
        case unreadable(Int32)
    }

    private static func rawRead(account: String) -> RawRead {
        ensureTestIsolation()
        if let simulated = effectiveSimulatedReadFailure { return .unreadable(simulated) }
        if let store = inMemoryStore {
            return store[account].map { RawRead.value($0) } ?? .missing
        }
        #if !canImport(Security)
        // No Security framework, so no lock and no auth: a 0600 file either has the value or
        // does not. `unreadable` is unreachable here by construction.
        return LinuxSecretFile.read(account: account).map { RawRead.value($0) } ?? .missing
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
            guard let data = item as? Data else {
                // Success with nothing to hand back is not "no password saved" — it is the
                // Keychain contradicting itself, so it is reported as unreadable rather than
                // silently becoming an empty field.
                navidromeSecretsLog.error("Keychain returned success with no data")
                return .unreadable(errSecSuccess)
            }
            return .value(data)
        case errSecItemNotFound:
            return .missing
        default:
            navidromeSecretsLog.error("Keychain read failed: \(status, privacy: .public)")
            return .unreadable(status)
        }
        #endif
    }

    private static func read(account: String) -> Data? {
        if case .value(let data) = rawRead(account: account) { return data }
        return nil
    }

    /// Whether the data is now in the Keychain. The status was previously logged and
    /// dropped; a caller that reports a count needs to know.
    @discardableResult
    private static func write(_ data: Data, account: String) -> Bool {
        ensureTestIsolation()
        if inMemoryStore != nil {
            // A refusal is otherwise unreachable in a test: the in-memory store always
            // succeeds, so the branch reporting a failed Keychain write had no coverage —
            // and a mutation restoring the old count-attempts bug survived unnoticed. This
            // is the seam that lets a test see what a real device produces with, say,
            // `errSecInteractionNotAllowed`.
            //
            // Confined to the in-memory path, so production behaviour is untouched.
            if refusedAccounts.contains(account) { return false }
            inMemoryStore?[account] = data
            return true
        }
        #if !canImport(Security)
        LinuxSecretFile.write(data, account: account)
        return true
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
            return true
        case errSecItemNotFound:
            var addQuery = baseQuery
            for (k, v) in attributes { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                navidromeSecretsLog.error("Keychain add failed: \(addStatus, privacy: .public)")
                return false
            }
            return true
        default:
            navidromeSecretsLog.error("Keychain update failed: \(updateStatus, privacy: .public)")
            return false
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
