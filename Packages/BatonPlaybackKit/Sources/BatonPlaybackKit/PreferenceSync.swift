import BatonSubsonicKit
import BatonSubsonicModels
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
///
/// Two things make "last write" mean something (S-F17):
///
/// - **The timestamps are in the gateway's clock, not each device's.** They used to be compared
///   across devices that had never agreed on the time, so a Mac an hour ahead won every conflict
///   for a key until the phone edited past that future time. The gateway sends its own clock with
///   the document and each device converts at that boundary; `Document.clockSkew` holds the
///   difference. Where a timestamp still arrives from the future — an older build, or a gateway
///   too old to send a time — it no longer beats a local edit. See `isFromTheFuture`.
/// - **Clearing a setting is itself a write.** A removed key has no value to encode, so the push
///   used to skip it and the shared document kept the old value for ever. It now travels as a
///   tombstone, `Entry.deletedAt`.
///
/// And the document as a whole carries a revision the gateway stamps on every write, so a merge
/// made against a document the other device has since replaced is refused rather than applied.
/// The answer to that refusal is to read and merge again, which is what `sync` does.
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
        // The gateway's address, which sat outside this list while its four neighbours were
        // in it. Nothing said why, and the asymmetry was doing real work: pairing carried
        // the gateway URL (everything under `baton.` is in `SettingsTransfer`) and then
        // ongoing sync never updated it, so moving the home server left every device except
        // the one you edited pointing at an address that no longer answers. It is one
        // server shared by all your devices, exactly like the four keys above it.
        //
        // The reason to hesitate — a LAN address one device can reach and another cannot —
        // is not an argument for leaving it stale: a device that cannot reach the gateway
        // fails either way, and with the value carried it starts working again the moment
        // that device is back on the network.
        "baton.agent.gatewayURL",
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
            // What the music friend has been told and been corrected on. A merged key rather
            // than a synced one because two devices each learning something between syncs is
            // the normal case, and whole-document last-write-wins discards one side in
            // silence.
            .union([FriendLedger.storageKey])
            .union([SearchRecents.storageKey, PodcastSubscriptionStore.ledgerKey,
                    ClippingLedger.storageKey])

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
        // Clippings merge per *clipping* and per *field*: a device that renamed one and a
        // device that deleted another must both be right afterwards, and a rename must not win
        // an argument about whether something was deleted. See `ClippingLedger`.
        if key == ClippingLedger.storageKey {
            let decode = { (value: Any?) -> ClippingLedger in
                ClippingLedger.decode(value as? Data) ?? .init()
            }
            let merged = ClippingLedger.merged(decode(local), decode(remote))
            guard !merged.records.isEmpty else { return nil }
            return merged.encoded()
        }
        // The friend's memory and corrections merge per *entry*, keyed on the text both
        // devices already agree on — the numeric memory id is minted per device and means
        // different things on each. Retirement crosses as a tombstone, because a deletion
        // with no record is indistinguishable from never having heard of it. See `FriendLedger`.
        if key == FriendLedger.storageKey {
            let decode = { (value: Any?) -> FriendLedger in
                FriendLedger.decode(value as? Data) ?? .init()
            }
            let merged = FriendLedger.merged(decode(local), decode(remote))
            guard !merged.memories.isEmpty || !merged.corrections.isEmpty else { return nil }
            return merged.encoded()
        }
        if key == SearchRecents.storageKey {
            // The same lenient decode `SearchRecents.reload` uses: one element written by a build
            // that knows a `Kind` this one does not must not empty both devices' lists (S-F27).
            let decode = { (value: Any?) -> [SearchRecents.Entry] in
                SearchRecents.decodeList(value as? Data)
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
        /// Set when this entry records that the setting was *cleared*, not that it holds a value.
        ///
        /// Without it a deletion could not travel at all. Removing a synced key stamps a local
        /// timestamp, but the push loop then had nothing to encode and skipped the key, so the
        /// shared document kept the old value for ever and any device that had not stamped that
        /// key re-adopted it. Resetting the EQ on the phone came back from the Mac (S-F17). The
        /// merged list keys were exempt because they carry their own ledgers; the scalar path had
        /// none.
        ///
        /// Optional, and a tombstone carries an **empty `value`**, which is what makes it safe to
        /// send to a build that has never heard of this field. That build decodes the entry
        /// (Codable ignores keys it does not know), tries to read an empty property list, fails,
        /// and skips the key — so the tombstone is ignored rather than adopted as a value, which
        /// is the safe direction. See `PreferenceSyncDeletionTests`.
        var deletedAt: Date?

        var isTombstone: Bool { deletedAt != nil }

        /// Records that a key was cleared on this device at `date`.
        static func tombstone(at date: Date, device: String) -> Entry {
            Entry(value: Data(), updatedAt: date, device: device, deletedAt: date)
        }
    }

    /// The shared document as this build can read it, which is not the same as all of it.
    ///
    /// The whole document used to be one `try?`: `decode([String: Entry].self) ?? [:]`. A decode
    /// failure therefore looked exactly like a gateway nobody had synced to yet, and the sync that
    /// followed found `remote[key] == nil` for every key, pushed this device's whole state, and the
    /// PUT is a whole-file replace on the gateway. One bad byte on the wire, or one entry written by
    /// a build that knows a field this one does not, and the other device's podcast unsubscribes,
    /// friend-memory ledger and clipping ledger were gone (S-F1).
    ///
    /// So the two cases are now separate, and there are three of them rather than two:
    ///
    /// - **`{}` or an empty body** is genuinely "nothing shared yet". It is the first device's
    ///   honest answer and it still means an empty document.
    /// - **A document that is not a JSON object at all** is unreadable. `fetch` throws, `sync`
    ///   returns false, and nothing is pushed. Doing nothing is always recoverable; pushing over it
    ///   is not.
    /// - **An entry inside a readable document that this build cannot decode** is kept verbatim in
    ///   `unreadable` and written back untouched on the next PUT, and this device refuses to push
    ///   over that key. One entry a newer phone wrote no longer costs the other fifteen, and an
    ///   older build rewriting the document no longer strips what it did not understand.
    struct Document {
        /// The entries this build understands.
        var entries: [String: Entry] = [:]
        /// Keys whose value did not decode as an `Entry`, held as the JSON that arrived so it can
        /// be written back exactly as it was.
        var unreadable: [String: Any] = [:]

        /// Which write of the shared document this is, as the gateway counts them. `nil` from a
        /// gateway too old to say, in which case a push cannot be checked and is sent unversioned.
        var revision: Int?

        /// Gateway time minus this device's time, from the clock the gateway sends with the
        /// document. Zero when it does not send one.
        ///
        /// Every entry timestamp in the document is expressed in the gateway's clock, and this is
        /// how a device converts to and from it. That is the whole answer to two devices whose
        /// clocks disagree: they used to compare `Date()` values stamped independently, so a Mac
        /// an hour ahead won every conflict for a key until the phone edited past that future
        /// time (S-F17). One shared clock, held by the thing both devices already talk to, and the
        /// comparison means something again.
        var clockSkew: TimeInterval = 0

        subscript(key: String) -> Entry? {
            get { entries[key] }
            set { entries[key] = newValue }
        }

        /// Whether this device must leave a key alone. Not "absent": absent means nobody has ever
        /// said anything about it and seeding is right. This means somebody said something this
        /// build cannot read, and overwriting it would be the data loss, not the fix.
        func isUnreadable(_ key: String) -> Bool { unreadable[key] != nil }

        var isEmpty: Bool { entries.isEmpty && unreadable.isEmpty }
        var count: Int { entries.count + unreadable.count }
    }

    /// The document could not be read at all, as distinct from being empty.
    enum DocumentError: Error, LocalizedError {
        case notAnObject

        var errorDescription: String? {
            "The shared settings document could not be read, so nothing was sent to it."
        }
    }

    /// Split a shared document into what this build can read and what it must preserve.
    ///
    /// An empty body is `{}` on purpose: a gateway that has never been written to is the first
    /// device's normal case, and treating it as an error would mean no device could ever seed one.
    static func decodeDocument(_ data: Data) throws -> Document {
        let trimmed = data.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        if trimmed.isEmpty { return Document() }

        guard let top = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let object = top as? [String: Any]
        else { throw DocumentError.notAnObject }

        var document = Document()
        for (key, value) in object {
            // Round-tripped through `JSONSerialization` rather than decoded in place, so one entry
            // failing cannot take the dictionary decode down with it. That single shared failure is
            // the whole bug: `[String: Entry]` is all-or-nothing by construction.
            guard let valueData = try? JSONSerialization.data(withJSONObject: value,
                                                              options: [.fragmentsAllowed]),
                  let entry = try? JSONDecoder().decode(Entry.self, from: valueData)
            else {
                syncLog.notice("""
                    shared settings entry '\(key, privacy: .public)' was written by a build this \
                    one cannot read; keeping it as it is rather than replacing it.
                    """)
                document.unreadable[key] = value
                continue
            }
            document.entries[key] = entry
        }
        return document
    }

    /// The JSON to PUT: this build's entries, plus every entry it could not read, written back
    /// exactly as it arrived.
    static func encodeDocument(_ document: Document) throws -> Data {
        var object: [String: Any] = document.unreadable
        for (key, entry) in document.entries {
            let encoded = try JSONEncoder().encode(entry)
            object[key] = try JSONSerialization.jsonObject(with: encoded)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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

    /// `defaults` defaults to `BatonStorage.defaults`, which is `.standard` in every normal run
    /// and the throwaway suite in a probe launch. It is the same expression
    /// `FriendLedgerStore.defaultDefaults()` resolves to, deliberately: the friend ledger travels
    /// through this class, so if the two ever named different domains the whole feature would go
    /// silently inert with every test still passing.
    public init(defaults: UserDefaults = BatonStorage.defaults, deviceName: String, session: URLSession = .shared) {
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
    /// How many block observers this class currently holds registered.
    ///
    /// Instrumentation, and it exists because the leak it measures has no other symptom. An
    /// observer left registered after its `PreferenceSync` is gone wakes on every `UserDefaults`
    /// change, finds `self` nil through the weak capture, and does nothing — forever, once per
    /// instance ever built. Nothing crashes, nothing is slow enough to notice, and no assertion
    /// anyone could write about the object's own behaviour can see it (S-F17). Counting the
    /// registrations is the only thing that can.
    ///
    /// `@MainActor` like the rest of the class, so this is not a data race.
    static private(set) var liveObservationCount = 0

    public func startObservingChanges() {
        guard observer == nil else { return }
        snapshot = currentValues()
        Self.liveObservationCount += 1
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stampChangedKeys() }
        }
    }

    /// Whether this instance is stamping local changes. A host that syncs without observing
    /// can neither push nor keep its own edits, and nothing about it looks wrong from outside.
    public var isObservingChanges: Bool { observer != nil }

    public func stopObservingChanges() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            Self.liveObservationCount -= 1
        }
        observer = nil
    }

    /// The block observer outlives this object unless it is taken off, and the block captures
    /// `self` weakly precisely so it can keep firing after this object is gone: it wakes, finds
    /// `self` nil, and does nothing, forever, once per `UserDefaults` change for every
    /// `PreferenceSync` ever built (S-F17). Nothing crashes, which is why nobody noticed.
    ///
    /// `deinit` rather than relying on `stopObservingChanges`, because a caller that forgets is
    /// exactly the case this covers, and the object cannot be deinitialised while anything still
    /// wants the observation.
    /// `isolated deinit` so it runs on the main actor and can simply call the same method a
    /// caller would. The alternative, reaching into the token from a nonisolated `deinit`, needs
    /// an unchecked box around a value the rest of the class already holds safely, which is more
    /// unsafety than the problem is worth.
    isolated deinit {
        stopObservingChanges()
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

    /// Whether this device has anything to say about a key, given what the shared store holds.
    ///
    /// Split out because it is the entire push rule and it is **silent in both directions**:
    /// a device that can never push looks exactly like a device nobody changed a setting on,
    /// which is how the Mac shipped for months without stamping anything at all.
    ///
    /// A key with no local timestamp is still pushed when the shared store has never heard of
    /// it. Without that, a device only ever *pulls* until someone edits a setting on it — so a
    /// Mac configured months ago would sit there holding an EQ curve the phone could never
    /// see. It is stamped `.distantPast`, so any real edit on any device wins over it.
    static func shouldPush(localStamp: Date?, remote: Entry?, now: Date = Date()) -> Bool {
        // Never seed over a shared value: this device has no record of choosing it, and the
        // device that pushed it did.
        guard let localStamp else { return remote == nil }
        guard let remote else { return true }
        // A stamp from beyond now is not evidence of anything, so it does not get to block a
        // local edit. See `isFromTheFuture`.
        if isFromTheFuture(remote, now: now) { return true }
        return remote.updatedAt < localStamp
    }

    /// Whether the shared store's copy is newer than this device's own last word on a key.
    static func shouldAdopt(remote: Entry, localStamp: Date?, now: Date = Date()) -> Bool {
        // The same rule from the other side. A future entry still seeds a device that has never
        // had an opinion about the key — refusing that would leave a fresh phone with nothing —
        // but it never overrides an edit this device actually made.
        if isFromTheFuture(remote, now: now) { return localStamp == nil }
        return remote.updatedAt > (localStamp ?? .distantPast)
    }

    /// How far ahead a shared timestamp may be before this device stops believing it.
    ///
    /// A minute, which is far more than the round trip and far less than the clock errors this
    /// guards against: the case is a device set to the wrong time zone or with no working clock,
    /// which is out by hours. Smaller than that and ordinary jitter would start looking like skew.
    static let futureTolerance: TimeInterval = 60

    /// An entry stamped later than the shared clock has reached.
    ///
    /// Normally impossible, because every device expresses its stamps in the gateway's clock (see
    /// `Document.clockSkew`). What produces one is a build old enough to have stamped in its own
    /// clock, or a gateway too old to send its time. Either way the honest reading is that the
    /// timestamp orders nothing, and a device that made a real edit should not lose to it for the
    /// hours it takes local time to catch up — which is exactly what used to happen.
    static func isFromTheFuture(_ entry: Entry, now: Date) -> Bool {
        entry.updatedAt > now.addingTimeInterval(futureTolerance)
    }

    /// Pulls remote settings, applies anything newer, and pushes anything newer here.
    ///
    /// Deliberately best-effort: every failure path leaves local settings untouched. A
    /// gateway that is down, slow or absent must never be able to change how your music
    /// sounds.
    @discardableResult
    public func sync(gatewayURL: URL, token: String) async -> Bool {
        do {
            try await reconcile(gatewayURL: gatewayURL, token: token)
            return true
        } catch SyncError.staleRevision {
            // The other device wrote while this one was merging. The merge was done over a
            // document that is no longer there, so it is redone over the one that is. Forcing the
            // push instead would be exactly the lost update the revision exists to catch: the PUT
            // is a whole-file replace, and the peer's write would go with it.
            syncLog.notice("shared settings moved while syncing; reading them again")
            do {
                try await reconcile(gatewayURL: gatewayURL, token: token)
                return true
            } catch {
                syncLog.error("preference sync skipped: \(error.localizedDescription, privacy: .public)")
                return false
            }
        } catch {
            syncLog.error("preference sync skipped: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One pull, merge and push. Throws rather than reporting, so `sync` can tell a document that
    /// moved under it — worth retrying once — from a gateway that is not there.
    private func reconcile(gatewayURL: URL, token: String) async throws {
        var remote = try await fetch(gatewayURL: gatewayURL, token: token)
        let stamps = localTimestamps

        // Every timestamp in the shared document is in the gateway's clock, and every stamp in
        // `localTimestamps` is in this device's. These two convert between them, and when the
        // gateway is too old to send a time the skew is zero and this is what it always was.
        let skew = remote.clockSkew
        let shared = { (date: Date) in date.addingTimeInterval(skew) }
        let sharedNow = shared(Date())

        // Remote → local, for anything newer than our own last write.
        var changed = false

        for (key, entry) in remote.entries
        where Self.syncedKeys.contains(key) && !Self.mergedKeys.contains(key) {
            guard Self.shouldAdopt(remote: entry, localStamp: stamps[key].map(shared),
                                   now: sharedNow) else { continue }
            // A tombstone says the setting was cleared, which is a thing to do rather than a
            // value to write. Without this the removal never travelled at all.
            if entry.isTombstone {
                if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
                continue
            }
            if let value = try? PropertyListSerialization.propertyList(
                from: entry.value, options: [], format: nil
            ) {
                defaults.set(value, forKey: key)
            }
        }

        // Local → remote, for anything we changed more recently than they hold.
        for key in Self.syncedKeys where !Self.mergedKeys.contains(key) {
            // A key another build wrote in a shape this one cannot read is left alone. It is
            // not absent, so seeding over it would be the loss rather than the fix.
            guard !remote.isUnreadable(key) else { continue }
            guard Self.shouldPush(localStamp: stamps[key].map(shared), remote: remote[key],
                                  now: sharedNow) else { continue }
            guard let value = defaults.object(forKey: key),
                  let encoded = try? PropertyListSerialization.data(
                      fromPropertyList: value, format: .binary, options: 0
                  )
            else {
                // Nothing here to send. Two very different reasons for that, and telling them
                // apart is the whole of the deletion fix: a key this device has stamped and no
                // longer holds was **cleared here**, and that has to travel or the other device
                // hands the old value straight back. A key with no stamp is simply one this
                // device never had an opinion about, and saying nothing is right.
                guard let stamp = stamps[key] else { continue }
                // Already recorded as cleared. Rewriting it would move the timestamp forward on
                // every sync, for a fact that has not changed.
                guard remote[key]?.isTombstone != true else { continue }
                remote[key] = Entry.tombstone(at: shared(stamp), device: deviceName)
                changed = true
                continue
            }
            remote[key] = Entry(value: encoded, updatedAt: shared(stamps[key] ?? .distantPast),
                                device: deviceName)
            changed = true
        }
        // The list keys, unioned in both directions at once. Timestamps don't decide
        // anything here — the merged list is simply the truth, and both sides adopt it.
        for key in Self.mergedKeys {
            // Same rule as above, and it matters more here: these keys hold the podcast,
            // friend-memory and clipping ledgers, and a merge that cannot see the remote side
            // returns the local list alone, which is a whole-ledger replace wearing the word
            // "merge" (S-F1).
            guard !remote.isUnreadable(key) else { continue }
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
                remote[key] = Entry(value: encoded, updatedAt: sharedNow, device: deviceName)
                changed = true
            }
        }

        if changed { try await push(remote, gatewayURL: gatewayURL, token: token) }
    }

    // MARK: - Transport

    /// The header the gateway stamps each write of the shared document with, and reads back on a
    /// push to see whether the pusher had read what it is replacing. See `StateStore`.
    nonisolated static let revisionHeader = "X-Baton-State-Revision"
    /// The gateway's own clock, as seconds since 1970. See `Document.clockSkew`.
    nonisolated static let serverTimeHeader = "X-Baton-Server-Time"

    enum SyncError: Error, LocalizedError {
        /// The gateway refused the push because the document had moved since this device read it.
        case staleRevision

        var errorDescription: String? {
            "The shared settings changed while this device was syncing, so nothing was sent."
        }
    }

    private func fetch(gatewayURL: URL, token: String) async throws -> Document {
        var request = URLRequest(url: GatewayAddress.root(gatewayURL).appendingPathComponent("v1/state"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // Empty is "nothing shared yet"; unreadable throws, and `sync` pushes nothing. See
        // `decodeDocument` for why those had to stop being the same answer.
        var document = try Self.decodeDocument(data)
        document.revision = http.value(forHTTPHeaderField: Self.revisionHeader).flatMap(Int.init)
        // Measured at receipt rather than at request time, so the round trip counts against the
        // gateway's answer being stale rather than against this device's clock being wrong. Both
        // headers are absent from a gateway older than this change, and everything then behaves
        // as it did before.
        if let raw = http.value(forHTTPHeaderField: Self.serverTimeHeader), let seconds = Double(raw) {
            document.clockSkew = seconds - Date().timeIntervalSince1970
        }
        return document
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
            // `{}` is the correct answer from a gateway nobody has synced to yet. A document that
            // cannot be read is not that, and saying "Reachable, nothing shared yet" about one
            // would be the same mistake the sync itself used to make, told to the owner's face
            // (S-F1). Routed through `.failed` rather than a new case so nothing switching on this
            // enum has to change.
            guard let document = try? Self.decodeDocument(data) else {
                return .failed("The gateway answered, but its shared settings could not be read. "
                               + "Nothing was changed.")
            }
            return .ok(entries: document.count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func push(_ state: Document, gatewayURL: URL, token: String) async throws {
        var request = URLRequest(url: GatewayAddress.root(gatewayURL).appendingPathComponent("v1/state"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Which document this replaces. The gateway refuses the write if it has moved on, so a
        // merge made against a document the other device has already replaced cannot silently
        // throw that write away. Absent when the gateway did not say, which is how an older one
        // keeps working.
        if let revision = state.revision {
            request.setValue(String(revision), forHTTPHeaderField: Self.revisionHeader)
        }
        request.httpBody = try Self.encodeDocument(state)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 { throw SyncError.staleRevision }
        guard status == 200 else { throw URLError(.badServerResponse) }
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
