import Foundation

/// What the person has allowed each cloud model source to be sent (M4.6,
/// `specs/document-clippings.md`, *Consent*): per source (provider and host) and per kind of
/// content (`ModelContent`), with revoke.
///
/// Kept in this device's preferences. The keys are not in the preference sync contract
/// (`PreferenceSync.syncedKeys` is an allowlist), so allowing Anthropic on this Mac does not
/// reach another device by sync. A settings backup does carry them: `SettingsTransfer` exports
/// every `baton.` preference it does not exclude, so restoring that backup on another Mac
/// restores these grants too.
///
/// Two lists, both of `ModelConsent` keys:
/// - **granted**: "Always", or a switch turned on in Settings. `ModelRouter` reads it through
///   `consent` for its grant check.
/// - **declined**: "Not now", or a switch turned off. It only stops the import sheet asking
///   again; Settings can still turn it on.
///
/// "Allow once" is deliberately never written here: it is `ModelConsent.granting(_:_:)` for
/// one call.
public struct ModelConsentLedger {
    public static let grantedKey = "baton.documents.modelConsent.granted"
    public static let declinedKey = "baton.documents.modelConsent.declined"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func read(_ key: String) -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    private func write(_ values: Set<String>, _ key: String) {
        if values.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(values.sorted(), forKey: key) }
    }

    /// Everything granted, for `ModelRouter`.
    public var consent: ModelConsent { ModelConsent(granted: read(Self.grantedKey)) }

    public func allows(_ source: ModelSource, _ content: ModelContent) -> Bool {
        consent.allows(source, content)
    }

    /// Whether the person has answered for this source and content, either way. The import
    /// sheet asks only when they have not.
    public func hasAnswered(_ source: ModelSource, _ content: ModelContent) -> Bool {
        let key = ModelConsent.key(source, content)
        return read(Self.grantedKey).contains(key) || read(Self.declinedKey).contains(key)
    }

    /// "Always", or the switch turned on. A local source needs nothing, so nothing is written.
    public func grant(_ source: ModelSource, _ content: ModelContent) {
        guard !source.isLocal else { return }
        let key = ModelConsent.key(source, content)
        write(read(Self.grantedKey).union([key]), Self.grantedKey)
        write(read(Self.declinedKey).subtracting([key]), Self.declinedKey)
    }

    /// The switch turned off: nothing more of this kind goes to that source, and the import
    /// sheet does not ask again.
    public func revoke(_ source: ModelSource, _ content: ModelContent) {
        guard !source.isLocal else { return }
        let key = ModelConsent.key(source, content)
        write(read(Self.grantedKey).subtracting([key]), Self.grantedKey)
        write(read(Self.declinedKey).union([key]), Self.declinedKey)
    }

    /// "Not now": nothing is allowed, and the sheet stops asking.
    public func decline(_ source: ModelSource, _ content: ModelContent) {
        guard !source.isLocal else { return }
        let key = ModelConsent.key(source, content)
        guard !read(Self.grantedKey).contains(key) else { return }
        write(read(Self.declinedKey).union([key]), Self.declinedKey)
    }

    /// Forget every answer, so nothing is allowed and the sheet asks again.
    public func reset() {
        defaults.removeObject(forKey: Self.grantedKey)
        defaults.removeObject(forKey: Self.declinedKey)
    }
}

extension ModelRouter {
    /// A router whose grant check is what the person allowed on this device.
    public init(sources: [ModelSource], ledger: ModelConsentLedger) {
        self.init(sources: sources, consent: ledger.consent)
    }
}
