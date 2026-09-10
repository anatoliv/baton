import CommonCrypto
import CryptoKit
import Foundation
import OSLog
import Security
import BatonSubsonicKit

private let settingsTransferLog = Logger(subsystem: "io.tonebox.baton", category: "settings-transfer")

/// Export/import of Baton's settings so a setup can be moved between Macs.
///
/// Two shapes, chosen at export time:
/// - **Preferences only** — durable prefs from `UserDefaults` (playback, EQ, layouts,
///   speech hosts + voice map, webhooks, the server *list*: names/URLs/usernames). No
///   secrets. Written as plain JSON, safe to store or email.
/// - **With accounts** — the above plus every secret from the Keychain (each server's
///   password/API key, Last.fm secret + session, ListenBrainz token, the external-discovery
///   keys for Last.fm and YouTube). The whole file is
///   then AES-GCM encrypted under a key derived from a user passphrase (PBKDF2-HMAC-SHA256),
///   so the secrets never sit in plaintext. This shape also carries the **portable documents**
///   — the music friend's memory and what it has learned — which live in files rather than in
///   `UserDefaults` and are personal enough to belong on the encrypted side of the line.
///
/// Deliberately NOT exported: transient/session state (the play queue, history, the offline
/// scrobble queue), machine-local device state (pending output device), derived personalization,
/// the regenerated MCP token, and the download-folder *path* (may not exist on the target Mac).
/// The file carries a schema version so a future format change can be detected on import.
public enum SettingsTransfer {
    static let format = "baton-settings"
    static let schemaVersion = 1
    /// PBKDF2 iteration count for the passphrase → key derivation (OWASP-ish for SHA-256).
    static let kdfRounds = 210_000

    // MARK: - Key policy

    /// `UserDefaults` keys under our namespaces that must NOT travel: transient session state,
    /// machine-local device state, derived defaults, and the download folder path. Everything
    /// else under `tonebox.`/`baton.` is a durable preference and is exported.
    static let excludedPreferenceKeys: Set<String> = [
        "tonebox.navidrome.queue",                      // current play queue (session)
        "tonebox.music.playHistory",                    // local play log (data, not a setting)
        "tonebox.music.scrobbleQueue",                  // pending offline scrobbles (transient)
        "tonebox.outputVolume.pendingDeviceID",         // per-machine audio device state
        "tonebox.outputVolume.pendingDeviceUID",
        "tonebox.outputVolume.pendingOriginal",
        "tonebox.navidrome.audioFocus.pendingVolume",   // transient duck/suspend state
        "baton.personalization.applied",                // derived from this Mac's listening
        "baton.personalization.rationale",
        "baton.help.requestedTopic",                    // transient navigation
        "baton.settings.selectedCategory",              // which Settings tab was open
        "baton.speech.history",                         // spoken-summary history (session data, not a setting)
        "tonebox.music.downloadFolder",                 // a path that may not exist on the target
    ]

    /// True for a `UserDefaults` key that is a durable, exportable preference.
    static func isExportablePreference(_ key: String) -> Bool {
        (key.hasPrefix("tonebox.") || key.hasPrefix("baton.")) && !excludedPreferenceKeys.contains(key)
    }

    /// Fixed (non-server) Keychain accounts holding secrets. Per-server passwords are added
    /// dynamically from the saved server list. The MCP token is intentionally excluded — it is
    /// regenerated per machine.
    static let fixedSecretAccounts: [String] = [
        "tonebox.music.lastfm.apiSecret",
        "tonebox.music.lastfm.sessionKey",
        "tonebox.music.listenBrainzToken",
        // The gateway's bearer token. Carried so a device set up by pairing can reach the
        // shared-settings store it was just configured for — without it the transfer hands
        // over a gateway URL the receiving device has no way to authenticate to.
        "baton.agent.gatewayToken",
        // The music friend's model-provider key. It was the one credential a paired phone
        // still had to be given by hand, which made the transfer look broken at exactly the
        // moment it had just carried eight other secrets successfully. Both apps name this
        // account `baton.agent.apiKey` since the key names were unified, so it needs no
        // mapping — that mismatch is the likeliest reason it was left out to begin with.
        "baton.agent.apiKey",
        // The two external-discovery keys, for the same reason as the gateway token: the
        // transfer already carries the *decision* to use Last.fm and YouTube as sources
        // (`PreferenceSync` syncs the per-source switches), and carrying a switched-on
        // source whose credential stays behind hands the receiving device a setting it
        // cannot act on. They are secrets, so they travel here — in the encrypted,
        // passphrase-gated half — rather than in the synced preferences blob.
        ExternalDiscovery.lastFMKeyKey,
        ExternalDiscovery.youTubeKeyKey,
        NavidromeKeychain.account,                      // legacy single-server "tonebox.navidromeSecret"
    ]

    // MARK: - Documents

    /// Files under Application Support that hold the user's own content rather than a
    /// preference, and travel with an export that carries secrets.
    ///
    /// WHY THIS EXISTS. Everything else here moves `UserDefaults` keys and Keychain
    /// items, and the music friend's two most personal stores are neither: what you have told
    /// it to remember, and what it learned from being told it was wrong, are both JSON files.
    /// So a phone set up from a Mac arrived with a friend that had been told nothing and
    /// learned nothing, while its settings came across perfectly — and the same gap meant a
    /// correction made on one device never reached the other.
    ///
    /// **The friend's log is deliberately absent.** It is history, not a setting, and the
    /// precedent in `excludedPreferenceKeys` is explicit about that distinction: the play
    /// history and the scrobble queue are excluded there for exactly this reason. Carrying a
    /// log of what was asked on another device would also be the one thing here that is
    /// surprising to receive.
    ///
    /// Referred to by filename rather than by type on purpose. `SettingsTransfer` lives in
    /// BatonPlaybackKit and these stores live in BatonAgentKit, which do not depend on each
    /// other in either direction — and the alternative, a registry the composition root has to
    /// populate, is a guard nobody invokes waiting to happen.
    static let portableDocuments: [String] = [
        "remote-memory.json",           // what you asked the friend to remember
        "music-friend-learned.json",    // what it learned from being corrected
    ]

    /// `Application Support/Baton`, where both stores put their files.
    ///
    /// A throwaway directory under XCTest, never the real one — same rule as
    /// `MusicEqualizer.defaultStore` and the in-memory Keychain. Without
    /// this every existing `SettingsTransfer` test would read the developer's own friend
    /// memory into a backup and, on import, write one back over it.
    public static func documentsDirectory(environment: BatonEnvironment = .current) -> URL? {
        if environment.isTesting {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("io.tonebox.tests.documents.\(UUID().uuidString)",
                                        isDirectory: true)
        }
        return BatonStorage.supportDirectory()
    }

    /// Each portable document that exists, as raw bytes.
    static func readDocuments(in directory: URL?) -> [String: Data] {
        guard let directory else { return [:] }
        var found: [String: Data] = [:]
        for name in portableDocuments {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) {
                found[name] = data
            }
        }
        return found
    }

    /// Write incoming documents, allowlisted by name for the same reason the secrets are: a
    /// tampered file must not be able to drop arbitrary content into Application Support.
    /// Returns how many landed.
    @discardableResult
    static func writeDocuments(_ documents: [String: Data], to directory: URL?) -> Int {
        guard let directory else { return 0 }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = 0
        for (name, data) in documents where portableDocuments.contains(name) && !data.isEmpty {
            do {
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                written += 1
            } catch {
                // One unwritable file must not abort an import that has already applied
                // preferences and secrets. Say so and carry on.
                settingsTransferLog.error("Couldn't write \(name, privacy: .public) on import: \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    /// True for a Keychain account we are willing to *write* on import — the fixed accounts plus
    /// the per-server namespace. Guards against a tampered file injecting arbitrary Keychain items.
    static func isImportableSecretAccount(_ account: String) -> Bool {
        fixedSecretAccounts.contains(account) || account.hasPrefix("tonebox.navidromeSecret.")
    }

    /// Every Keychain account whose secret should be exported, given the current server list.
    static func secretAccounts(defaults: UserDefaults) -> [String] {
        var accounts = fixedSecretAccounts
        let previousDefaults = NavidromeConfig.defaults
        NavidromeConfig.defaults = defaults
        defer { NavidromeConfig.defaults = previousDefaults }
        for entry in NavidromeConfig.servers() {
            accounts.append(NavidromeConfig.keychainAccount(for: entry.id))
        }
        // Dedupe while preserving order.
        var seen = Set<String>()
        return accounts.filter { seen.insert($0).inserted }
    }

    // MARK: - Errors

    public enum TransferError: LocalizedError {
        case notABatonBackup
        case unsupportedVersion(Int)
        case passphraseRequired
        case wrongPassphrase
        case corrupt

        public var errorDescription: String? {
            switch self {
            case .notABatonBackup: "This file isn't a Baton settings backup."
            case let .unsupportedVersion(v): "This backup was made by a newer version of Baton (format \(v)). Update Baton and try again."
            case .passphraseRequired: "This backup is encrypted. Enter its passphrase to import it."
            case .wrongPassphrase: "Wrong passphrase: the backup couldn't be decrypted."
            case .corrupt: "The backup file is damaged or incomplete."
            }
        }
    }

    // MARK: - Inspect

    /// What an on-disk backup contains, without applying it. Used to decide whether to prompt for
    /// a passphrase before import.
    public struct Inspection {
        public let encrypted: Bool
        public let appVersion: String?
    }

    public static func inspect(_ fileData: Data) throws -> Inspection {
        guard let outer = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
              outer["format"] as? String == format
        else { throw TransferError.notABatonBackup }
        if let v = outer["version"] as? Int, v > schemaVersion { throw TransferError.unsupportedVersion(v) }
        let encrypted = (outer["encrypted"] as? Bool) ?? false
        return Inspection(encrypted: encrypted, appVersion: outer["appVersion"] as? String)
    }

    // MARK: - Export

    /// A summary of what an export produced, for the UI.
    public struct ExportResult {
        public let data: Data
        public let preferenceCount: Int
        public let secretCount: Int
        public let documentCount: Int
        public let encrypted: Bool
    }

    /// Build a settings backup. `includeSecrets` requires a non-empty `passphrase`; the resulting
    /// file is then encrypted. Without secrets the file is plain JSON.
    /// `documentsIn` is the Application Support folder the portable documents are read from;
    /// injectable so tests never touch the developer's real friend memory.
    public static func makeExport(includeSecrets: Bool, passphrase: String?,
                                  defaults: UserDefaults = BatonStorage.defaults,
                                  documentsIn documentsDirectory: URL? = SettingsTransfer.documentsDirectory()) throws -> ExportResult {
        var preferences: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where isExportablePreference(key) {
            preferences[key] = value
        }

        var envelope: [String: Any] = [
            "schemaVersion": schemaVersion,
            "app": "baton",
            "appVersion": Self.appVersion,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "preferences": preferences,
        ]

        var secretCount = 0
        var documentCount = 0
        if includeSecrets {
            guard let passphrase, !passphrase.isEmpty else { throw TransferError.passphraseRequired }
            var secrets: [String: String] = [:]
            for account in secretAccounts(defaults: defaults) {
                if let value = NavidromeKeychain.secret(account: account), !value.isEmpty {
                    secrets[account] = value
                }
            }
            envelope["secrets"] = secrets
            secretCount = secrets.count

            // Documents ride with the secrets, and only with the secrets. They are not
            // credentials, but they are the most personal thing here — what you have told
            // the friend about yourself — and a preferences-only export is plain JSON that
            // this file's own header calls "safe to store or email". Encrypting them is the
            // safe direction, and pairing always sends secrets, so pairing always carries
            // them.
            let documents = readDocuments(in: documentsDirectory)
            envelope["documents"] = documents.mapValues { $0.base64EncodedString() }
            documentCount = documents.count
        }

        let inner = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)

        let outer: [String: Any]
        if includeSecrets, let passphrase {
            let salt = randomBytes(16)
            let key = deriveKey(passphrase: passphrase, salt: salt, rounds: kdfRounds)
            let sealed = try AES.GCM.seal(inner, using: key)
            guard let combined = sealed.combined else { throw TransferError.corrupt }
            outer = [
                "format": format, "version": schemaVersion, "encrypted": true,
                "appVersion": Self.appVersion,
                "kdf": "pbkdf2-hmac-sha256", "rounds": kdfRounds,
                "salt": salt.base64EncodedString(),
                "payload": combined.base64EncodedString(),
            ]
        } else {
            outer = [
                "format": format, "version": schemaVersion, "encrypted": false,
                "appVersion": Self.appVersion,
                "payload": inner.base64EncodedString(),
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: outer, options: [.prettyPrinted, .sortedKeys])
        settingsTransferLog.info("exported settings (\(preferences.count) prefs, \(secretCount) secrets, \(documentCount) documents, encrypted \(includeSecrets, privacy: .public))")
        return ExportResult(data: data, preferenceCount: preferences.count, secretCount: secretCount,
                            documentCount: documentCount, encrypted: includeSecrets)
    }

    // MARK: - Import

    public struct ImportResult {
        public let preferenceCount: Int
        /// Secrets that are **in the Keychain now** — not secrets the file carried.
        public let secretCount: Int
        /// Secrets the file carried that the Keychain refused. Non-zero means the import was
        /// partial, and the caller must say so rather than reporting the ones that worked
        ///.
        public let secretsRefused: Int
        public let documentCount: Int
        public let appVersion: String?

        public init(preferenceCount: Int, secretCount: Int, secretsRefused: Int,
                    documentCount: Int, appVersion: String?) {
            self.preferenceCount = preferenceCount
            self.secretCount = secretCount
            self.secretsRefused = secretsRefused
            self.documentCount = documentCount
            self.appVersion = appVersion
        }
    }

    /// Apply a settings backup. Preferences are written into `defaults`; secrets (if the backup is
    /// encrypted and carries them) are written into the Keychain. Only known preference keys and
    /// secret accounts are written — a tampered file can't set arbitrary values.
    ///
    /// Returns what was applied. Many settings are read once at launch, so the caller should prompt
    /// the user to relaunch Baton for everything to take effect.
    @discardableResult
    public static func applyImport(_ fileData: Data, passphrase: String?,
                                   defaults: UserDefaults = BatonStorage.defaults,
                                   documentsIn documentsDirectory: URL? = SettingsTransfer.documentsDirectory()) throws -> ImportResult {
        guard let outer = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
              outer["format"] as? String == format
        else { throw TransferError.notABatonBackup }
        if let v = outer["version"] as? Int, v > schemaVersion { throw TransferError.unsupportedVersion(v) }

        guard let payloadB64 = outer["payload"] as? String, let payload = Data(base64Encoded: payloadB64) else {
            throw TransferError.corrupt
        }

        let inner: Data
        if (outer["encrypted"] as? Bool) ?? false {
            guard let passphrase, !passphrase.isEmpty else { throw TransferError.passphraseRequired }
            guard let saltB64 = outer["salt"] as? String, let salt = Data(base64Encoded: saltB64) else {
                throw TransferError.corrupt
            }
            let rounds = (outer["rounds"] as? Int) ?? kdfRounds
            let key = deriveKey(passphrase: passphrase, salt: salt, rounds: rounds)
            do {
                inner = try AES.GCM.open(try AES.GCM.SealedBox(combined: payload), using: key)
            } catch {
                throw TransferError.wrongPassphrase
            }
        } else {
            inner = payload
        }

        guard let envelope = try? PropertyListSerialization.propertyList(from: inner, options: [], format: nil) as? [String: Any],
              envelope["app"] as? String == "baton"
        else { throw TransferError.corrupt }
        if let v = envelope["schemaVersion"] as? Int, v > schemaVersion { throw TransferError.unsupportedVersion(v) }

        var appliedPrefs = 0
        if let preferences = envelope["preferences"] as? [String: Any] {
            for (key, value) in preferences where isExportablePreference(key) {
                defaults.set(value, forKey: key)
                appliedPrefs += 1
            }
        }

        var appliedSecrets = 0
        var refusedSecrets = 0
        if let secrets = envelope["secrets"] as? [String: String] {
            for (account, value) in secrets where isImportableSecretAccount(account) && !value.isEmpty {
                // Count what landed, not what was attempted. This used to increment
                // unconditionally, so an import could report "1 secret" over a Keychain that
                // had rejected the write — and the post-import check would then say there
                // was nothing to test, because the friend was not configured without it.
                // Both sentences true, the pair of them false.
                if NavidromeKeychain.setSecret(value, account: account) {
                    appliedSecrets += 1
                } else {
                    refusedSecrets += 1
                    settingsTransferLog.error("Keychain refused \(account, privacy: .public) on import")
                }
            }
        }

        var appliedDocuments = 0
        if let documents = envelope["documents"] as? [String: String] {
            let decoded = documents.compactMapValues { Data(base64Encoded: $0) }
            appliedDocuments = writeDocuments(decoded, to: documentsDirectory)
        }

        settingsTransferLog.info("imported settings (\(appliedPrefs) prefs, \(appliedSecrets) secrets, \(refusedSecrets) refused, \(appliedDocuments) documents)")
        return ImportResult(preferenceCount: appliedPrefs, secretCount: appliedSecrets,
                            secretsRefused: refusedSecrets,
                            documentCount: appliedDocuments, appVersion: envelope["appVersion"] as? String)
    }

    // MARK: - Crypto helpers

    /// Derive a 32-byte AES key from a passphrase via PBKDF2-HMAC-SHA256.
    private static func deriveKey(passphrase: String, salt: Data, rounds: Int) -> SymmetricKey {
        var derived = Data(count: 32)
        let passData = Data(passphrase.utf8)
        derived.withUnsafeMutableBytes { derivedBuf in
            salt.withUnsafeBytes { saltBuf in
                passData.withUnsafeBytes { passBuf in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBuf.baseAddress?.assumingMemoryBound(to: CChar.self), passData.count,
                        saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        derivedBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    /// This build's marketing version, stamped into a backup for provenance.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
