import CommonCrypto
import CryptoKit
import Foundation
import OSLog
import Security

private let settingsTransferLog = Logger(subsystem: "io.tonebox.baton", category: "settings-transfer")

/// Export/import of Baton's settings so a setup can be moved between Macs.
///
/// Two shapes, chosen at export time:
/// - **Preferences only** — durable prefs from `UserDefaults` (playback, EQ, layouts,
///   speech hosts + voice map, webhooks, the server *list*: names/URLs/usernames). No
///   secrets. Written as plain JSON, safe to store or email.
/// - **With accounts** — the above plus every secret from the Keychain (each server's
///   password/API key, Last.fm secret + session, ListenBrainz token). The whole file is
///   then AES-GCM encrypted under a key derived from a user passphrase (PBKDF2-HMAC-SHA256),
///   so the secrets never sit in plaintext.
///
/// Deliberately NOT exported: transient/session state (the play queue, history, the offline
/// scrobble queue), machine-local device state (pending output device), derived personalization,
/// the regenerated MCP token, and the download-folder *path* (may not exist on the target Mac).
/// The file carries a schema version so a future format change can be detected on import.
enum SettingsTransfer {
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
        NavidromeKeychain.account,                      // legacy single-server "tonebox.navidromeSecret"
    ]

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

    enum TransferError: LocalizedError {
        case notABatonBackup
        case unsupportedVersion(Int)
        case passphraseRequired
        case wrongPassphrase
        case corrupt

        var errorDescription: String? {
            switch self {
            case .notABatonBackup: "This file isn't a Baton settings backup."
            case let .unsupportedVersion(v): "This backup was made by a newer version of Baton (format \(v)). Update Baton and try again."
            case .passphraseRequired: "This backup is encrypted. Enter its passphrase to import it."
            case .wrongPassphrase: "Wrong passphrase — the backup couldn't be decrypted."
            case .corrupt: "The backup file is damaged or incomplete."
            }
        }
    }

    // MARK: - Inspect

    /// What an on-disk backup contains, without applying it. Used to decide whether to prompt for
    /// a passphrase before import.
    struct Inspection {
        let encrypted: Bool
        let appVersion: String?
    }

    static func inspect(_ fileData: Data) throws -> Inspection {
        guard let outer = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
              outer["format"] as? String == format
        else { throw TransferError.notABatonBackup }
        if let v = outer["version"] as? Int, v > schemaVersion { throw TransferError.unsupportedVersion(v) }
        let encrypted = (outer["encrypted"] as? Bool) ?? false
        return Inspection(encrypted: encrypted, appVersion: outer["appVersion"] as? String)
    }

    // MARK: - Export

    /// A summary of what an export produced, for the UI.
    struct ExportResult {
        let data: Data
        let preferenceCount: Int
        let secretCount: Int
        let encrypted: Bool
    }

    /// Build a settings backup. `includeSecrets` requires a non-empty `passphrase`; the resulting
    /// file is then encrypted. Without secrets the file is plain JSON.
    static func makeExport(includeSecrets: Bool, passphrase: String?, defaults: UserDefaults = .standard) throws -> ExportResult {
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
        settingsTransferLog.info("exported settings (\(preferences.count) prefs, \(secretCount) secrets, encrypted \(includeSecrets, privacy: .public))")
        return ExportResult(data: data, preferenceCount: preferences.count, secretCount: secretCount, encrypted: includeSecrets)
    }

    // MARK: - Import

    struct ImportResult {
        let preferenceCount: Int
        let secretCount: Int
        let appVersion: String?
    }

    /// Apply a settings backup. Preferences are written into `defaults`; secrets (if the backup is
    /// encrypted and carries them) are written into the Keychain. Only known preference keys and
    /// secret accounts are written — a tampered file can't set arbitrary values.
    ///
    /// Returns what was applied. Many settings are read once at launch, so the caller should prompt
    /// the user to relaunch Baton for everything to take effect.
    @discardableResult
    static func applyImport(_ fileData: Data, passphrase: String?, defaults: UserDefaults = .standard) throws -> ImportResult {
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
        if let secrets = envelope["secrets"] as? [String: String] {
            for (account, value) in secrets where isImportableSecretAccount(account) && !value.isEmpty {
                NavidromeKeychain.setSecret(value, account: account)
                appliedSecrets += 1
            }
        }

        settingsTransferLog.info("imported settings (\(appliedPrefs) prefs, \(appliedSecrets) secrets)")
        return ImportResult(preferenceCount: appliedPrefs, secretCount: appliedSecrets, appVersion: envelope["appVersion"] as? String)
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
