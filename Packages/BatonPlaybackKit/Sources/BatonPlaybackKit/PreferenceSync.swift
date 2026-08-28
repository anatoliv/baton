import Foundation
import OSLog

private let syncLog = Logger(subsystem: "io.tonebox.baton", category: "PreferenceSync")

/// Keeps the settings that belong to *you* in step across your devices.
///
/// The stated goal was "log in on the Mac and the iPhone as the same user and see my
/// history and preferences from both". Most of that already worked: likes, ratings,
/// playlists and play counts live on Navidrome, keyed to the user, and both apps write
/// them. What didn't were the settings Baton keeps locally — the EQ curve, radio bans,
/// crossfade, the agent's provider config — because Navidrome has no client-preference
/// API to keep them in and never will.
///
/// So they go through the gateway, which is the one place both devices already
/// authenticate. When no gateway is configured this does nothing at all, and everything
/// behaves exactly as it did before: sync is an upgrade, not a dependency.
///
/// Conflict handling is **last-write-wins per key**, not per document. Two devices
/// changing different settings must not clobber each other, which a whole-blob overwrite
/// would do; each key carries when it changed and which device changed it, so the loser of
/// a genuine race is a single setting rather than everything you touched today.
@MainActor
public final class PreferenceSync {
    /// The keys worth carrying between devices.
    ///
    /// Chosen by one test: would you be annoyed to set this twice? Download folder, offline
    /// mode and demo mode fail it — they describe *this* device. Secrets are absent for a
    /// different reason: they're Keychain-resident and pairing already moves them, so
    /// putting them in a synced JSON blob would be a downgrade in handling.
    ///
    /// The discovery *sources* pass that test — deciding twice that you don't want YouTube
    /// results is exactly the annoyance this list exists to prevent. Two neighbouring keys
    /// deliberately stay out: the API keys, which are secrets and now Keychain-resident, and
    /// the master "look outside my library" switch, because that one is consent and consent
    /// is per device. A phone that syncs a Mac's decision to start talking to strangers
    /// would be making that choice on the owner's behalf.
    public static let syncedKeys: Set<String> = Set<String>([
        "tonebox.music.eq.enabled",
        "tonebox.music.eq.preset",
        "tonebox.music.eq.gains",
        "tonebox.music.eq.bands",
        "tonebox.navidrome.crossfade",
        "tonebox.navidrome.autoplay",
        "tonebox.navidrome.repeat",
        "tonebox.music.loudnessMode",
        "tonebox.music.loudnessPreampDB",
        "tonebox.music.radioBans",
        "tonebox.music.gapless",
        "baton.agent.route",
        "baton.agent.provider",
        "baton.agent.model",
        "baton.agent.baseURL",
        "baton.agent.speakReplies",
        // The Mac's half of the friend's setup. It wrote `baton.remote.nl.*` and read
        // nothing else, so for as long as sync has existed the four keys above were carried
        // between devices that could not both participate: the phone wrote them, the Mac
        // ignored them, and each end reported a successful sync. The Mac now writes the
        // shared spelling (see `RemoteControlSettings.Keys`), and these three are the
        // settings it has that the phone does not.
        "baton.remote.nl.enabled",
        "baton.remote.nl.agentEnabled",
        "baton.remote.nl.remembersOwner",
        // Settings that are plainly about you rather than about a device, and were simply
        // never added. Deciding twice that you want lyrics looked up is the annoyance this
        // list exists to prevent.
        "baton.lyrics.lrclib",
        "tonebox.music.scrobbleExternalSource",
        "tonebox.navidrome.gaplessWifiOnly",
        "baton.stream.quality.wifi",
        "baton.stream.quality.cellular",
        // Which podcasts you subscribe to. The episode cache stays local — it is derived
        // data each device refetches, and syncing it would ship staleness around.
        //
        // Two keys, on purpose. The plain list is what older builds read, and it is
        // additive: it cannot express an unsubscribe. The ledger beside it can, and lives
        // in `mergedKeys` because a whole-blob last-write-wins would throw away whatever
        // the quieter device subscribed to.
        "tonebox.podcasts.feeds",
        // How long the filter-history lists are allowed to get. An ordinary scalar; the
        // lists themselves are in `mergedKeys` below because they need a different rule.
        FilterHistory.sizeKey,
    ])
    .union(ExternalDiscovery.Source.allCases.map(ExternalDiscovery.enabledKey(for:)))
    .union(mergedKeys)

    /// Keys holding an accumulating **list**, where last-write-wins is the wrong rule.
    ///
    /// For a scalar — "crossfade = 6s" — the newest write is simply the answer. For a list
    /// it isn't: the newest write replaces the whole array, so everything searched on the
    /// quieter device disappears the moment the other one syncs. These are unioned instead,
    /// the same reasoning that made podcast feeds additive-only.
    public static let mergedKeys: Set<String> =
        Set(FilterHistory.allKeys.map(FilterHistory.storageKey))
            .union([SearchRecents.storageKey, PodcastSubscriptionStore.ledgerKey])

    /// Combine this device's list with the shared one. `nil` when there is nothing to say.
    static func mergedValue(key: String, local: Any?, remote: Any?) -> Any? {
        // Podcast subscriptions merge per *feed*, not per document: each side's newest
        // statement about a given show wins, so an unsubscribe here survives contact with
        // a device that still had the show, and a later resubscribe survives the tombstone.
        if key == PodcastSubscriptionStore.ledgerKey {
            let decode = { (value: Any?) -> PodcastSubscriptionLedger in
                PodcastSubscriptionLedger.decode(value as? Data) ?? .init()
            }
            let merged = PodcastSubscriptionLedger.merged(decode(local), decode(remote))
            guard !merged.records.isEmpty else { return nil }
            return merged.encoded()
        }
        if key == SearchRecents.storageKey {
            let decode = { (value: Any?) -> [SearchRecents.Entry] in
                guard let data = value as? Data else { return [] }
                return (try? JSONDecoder().decode([SearchRecents.Entry].self, from: data)) ?? []
            }
            let merged = SearchRecents.merge(decode(local), decode(remote))
            guard !merged.isEmpty else { return nil }
            return try? JSONEncoder().encode(merged)
        }
        let here = local as? [String] ?? []
        let there = remote as? [String] ?? []
        guard !here.isEmpty || !there.isEmpty else { return nil }
        return FilterHistory.merge(here, there, cap: FilterHistory.maxSize)
    }

    /// One setting, with enough provenance to resolve a race.
    struct Entry: Codable {
        var value: Data          // the property-list encoding of the value
        var updatedAt: Date
        var device: String
    }

    private let defaults: UserDefaults
    private let deviceName: String
    private let session: URLSession
    private var observer: NSObjectProtocol?
    /// Last-seen values for the synced keys, so a change notification can be turned into
    /// "which keys moved".
    private var snapshot: [String: Any] = [:]

    /// When each key was last written *here*, so a local edit made offline still wins over
    /// an older remote value once connectivity returns.
    private var localTimestamps: [String: Date] {
        get { (defaults.dictionary(forKey: Self.timestampsKey) as? [String: Date]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.timestampsKey) }
    }

    static let timestampsKey = "baton.sync.localTimestamps"

    public init(defaults: UserDefaults = .standard, deviceName: String, session: URLSession = .shared) {
        self.defaults = defaults
        self.deviceName = deviceName
        self.session = session
    }

    /// Records that a synced key changed on this device. Cheap enough to call from a
    /// `didSet`; the network only happens in `sync()`.
    public func noteLocalChange(_ key: String, at date: Date = Date()) {
        guard Self.syncedKeys.contains(key) else { return }
        var stamps = localTimestamps
        stamps[key] = date
        localTimestamps = stamps
    }

    /// Watches `UserDefaults` and stamps any synced key that changes.
    ///
    /// Replaces hand-placed `noteLocalChange` calls, which had drifted to covering 3 of the
    /// 16 synced keys — every setting anyone forgot to instrument silently stopped syncing,
    /// and nothing about the code said so. Observation can't be forgotten: adding a key to
    /// `syncedKeys` is now sufficient.
    public func startObservingChanges() {
        guard observer == nil else { return }
        snapshot = currentValues()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stampChangedKeys() }
        }
    }

    public func stopObservingChanges() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// The notification says *something* changed, never what — so diff against the last
    /// snapshot and stamp only what actually moved.
    private func stampChangedKeys() {
        let now = currentValues()
        var stamps = localTimestamps
        var changed = false
        for key in Self.syncedKeys where !equalValues(snapshot[key], now[key]) {
            stamps[key] = Date()
            changed = true
        }
        snapshot = now
        if changed { localTimestamps = stamps }
    }

    private func currentValues() -> [String: Any] {
        var values: [String: Any] = [:]
        for key in Self.syncedKeys {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        return values
    }

    /// `Any` has no `==`; compare the encodings, which is what actually travels anyway.
    private func equalValues(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        default:
            let encode = { (value: Any) -> Data? in
                try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            }
            return encode(a!) == encode(b!)
        }
    }

    /// Pulls remote settings, applies anything newer, and pushes anything newer here.
    ///
    /// Deliberately best-effort: every failure path leaves local settings untouched. A
    /// gateway that is down, slow or absent must never be able to change how your music
    /// sounds.
    @discardableResult
    public func sync(gatewayURL: URL, token: String) async -> Bool {
        do {
            var remote = try await fetch(gatewayURL: gatewayURL, token: token)
            let stamps = localTimestamps

            // Remote → local, for anything newer than our own last write.
            var changed = false

            for (key, entry) in remote
            where Self.syncedKeys.contains(key) && !Self.mergedKeys.contains(key) {
                let localAt = stamps[key] ?? .distantPast
                guard entry.updatedAt > localAt else { continue }
                if let value = try? PropertyListSerialization.propertyList(
                    from: entry.value, options: [], format: nil
                ) {
                    defaults.set(value, forKey: key)
                }
            }

            // Local → remote, for anything we changed more recently than they hold.
            //
            // A key with no local timestamp is still pushed when the shared store has never
            // heard of it. Without that, a device only ever *pulls* until someone edits a
            // setting on it — so a Mac configured months ago would sit there holding an EQ
            // curve the phone could never see. Seeded with `.distantPast`, so any real edit
            // on any device wins over it.
            for key in Self.syncedKeys where !Self.mergedKeys.contains(key) {
                let localAt = stamps[key] ?? .distantPast
                if stamps[key] == nil, remote[key] != nil { continue }   // never seed over a shared value
                if let existing = remote[key], existing.updatedAt >= localAt { continue }
                guard let value = defaults.object(forKey: key),
                      let encoded = try? PropertyListSerialization.data(
                          fromPropertyList: value, format: .binary, options: 0
                      )
                else { continue }
                remote[key] = Entry(value: encoded, updatedAt: localAt, device: deviceName)
                changed = true
            }
            // The list keys, unioned in both directions at once. Timestamps don't decide
            // anything here — the merged list is simply the truth, and both sides adopt it.
            for key in Self.mergedKeys {
                let localValue = defaults.object(forKey: key)
                let remoteValue = remote[key].flatMap {
                    try? PropertyListSerialization.propertyList(from: $0.value, options: [], format: nil)
                }
                guard let merged = Self.mergedValue(key: key, local: localValue, remote: remoteValue)
                else { continue }
                if !equalValues(merged, localValue) { defaults.set(merged, forKey: key) }
                // Only push when the shared copy would actually change. Without this an
                // idempotent merge still rewrites the document on every sync, and two
                // devices ping-pong pushes forever over a list neither of them edited.
                if !equalValues(merged, remoteValue),
                   let encoded = try? PropertyListSerialization.data(
                       fromPropertyList: merged, format: .binary, options: 0
                   ) {
                    remote[key] = Entry(value: encoded, updatedAt: Date(), device: deviceName)
                    changed = true
                }
            }

            if changed { try await push(remote, gatewayURL: gatewayURL, token: token) }
            return true
        } catch {
            syncLog.error("preference sync skipped: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Transport

    private func fetch(gatewayURL: URL, token: String) async throws -> [String: Entry] {
        var request = URLRequest(url: GatewayAddress.root(gatewayURL).appendingPathComponent("v1/state"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // An empty or unfamiliar document is treated as "nothing shared yet" rather than an
        // error: the first device to sync finds `{}`.
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    // MARK: - Is the gateway there?

    public enum GatewayCheck: Equatable, Sendable {
        case ok(entries: Int)
        /// It answered and refused the token.
        case rejected
        case failed(String)
    }

    /// Whether the gateway is reachable and accepts this token, asked without syncing
    /// anything. A `GET` on the same route `fetch` uses, so a pass means the next real sync
    /// will work rather than only that something answered on that port.
    ///
    /// Settings could only find this out by pressing **Sync now**, which is a write — so the
    /// one way to check the address was to use it, and "Couldn't reach the gateway" arrived
    /// after a round trip that may have pushed half a state.
    public func check(gatewayURL: URL, token: String) async -> GatewayCheck {
        var request = URLRequest(url: GatewayAddress.root(gatewayURL).appendingPathComponent("v1/state"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .rejected }
            guard status == 200 else { return .failed("The gateway answered with HTTP \(status).") }
            // `{}` is the correct answer from a gateway nobody has synced to yet.
            let entries = (try? JSONDecoder().decode([String: Entry].self, from: data))?.count ?? 0
            return .ok(entries: entries)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func push(_ state: [String: Entry], gatewayURL: URL, token: String) async throws {
        var request = URLRequest(url: GatewayAddress.root(gatewayURL).appendingPathComponent("v1/state"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(state)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}


extension PreferenceSync {
    /// A sync that won't hammer the gateway when called from every foreground.
    ///
    /// Foreground is the natural moment to reconcile — it's when someone has just picked
    /// the device up and is about to notice a stale setting — but on iOS it also fires for
    /// a glance at Control Center, so the call needs a floor.
    public func syncIfDue(
        gatewayURL: URL,
        token: String,
        minimumInterval: TimeInterval = 60
    ) async {
        let now = Date()
        if let last = lastSyncAttempt, now.timeIntervalSince(last) < minimumInterval { return }
        lastSyncAttempt = now
        await sync(gatewayURL: gatewayURL, token: token)
    }

    private var lastSyncAttempt: Date? {
        get { defaults.object(forKey: "baton.sync.lastAttempt") as? Date }
        set { defaults.set(newValue, forKey: "baton.sync.lastAttempt") }
    }
}
