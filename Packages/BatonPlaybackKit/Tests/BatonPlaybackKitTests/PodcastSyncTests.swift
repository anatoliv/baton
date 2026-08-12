import XCTest
@testable import BatonPlaybackKit

/// Podcast subscriptions crossing between a Mac and a phone.
///
/// They couldn't, and the reason was structural rather than a bug in the sync: subscriptions
/// live as JSON in Application Support, while both transports — `PreferenceSync` over the
/// gateway and `SettingsTransfer` for pairing/export — carry `UserDefaults` and the Keychain
/// and nothing else. Subscribing on one device was simply invisible to the other. The feed
/// URLs are mirrored into a synced default now; the episode cache deliberately is not.
@MainActor
final class PodcastSyncTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "baton.podcastsync.\(UUID().uuidString)")!
    }

    func testTheFeedListIsCarriedByOngoingSync() {
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(PodcastSubscriptionStore.syncedFeedsKey),
                      "subscriptions must travel with the other preferences")
    }

    /// Episodes are refetched by whoever needs them. Syncing the cache would move staleness
    /// between devices and bloat every payload for no gain.
    ///
    /// The podcast screens' *filter history* is allowed through: it's the same per-screen
    /// recent-filters list every other screen syncs (and Settings clears), not episode
    /// state. The scan is case-insensitive so `clientPodcastEpisodes` is an explicit
    /// decision here rather than a key the old lowercase substring silently never saw.
    func testOnlyTheSubscriptionsTravelNotTheEpisodeCache() {
        let allowed: Set<String> = [
            PodcastSubscriptionStore.syncedFeedsKey,
            PodcastSubscriptionStore.ledgerKey,
            FilterHistory.storageKey("podcasts"),
            FilterHistory.storageKey("clientPodcastEpisodes"),
        ]
        for key in PreferenceSync.syncedKeys where key.lowercased().contains("podcast") {
            XCTAssertTrue(allowed.contains(key),
                          "\(key) shouldn't be syncing — only the feed list and filter history should")
        }
    }

    /// Radio stations are deliberately absent from client sync, and that is not an
    /// oversight: `InternetRadioStore` reads and writes them through the *server*
    /// (`getInternetRadioStations` and friends, which Navidrome implements), so two devices
    /// pointed at the same server already see the same stations. Carrying them in
    /// `PreferenceSync` as well would give one list two owners and a way to disagree.
    func testRadioStationsAreServerOwnedAndNotClientSynced() {
        for key in PreferenceSync.syncedKeys where key.lowercased().contains("station") {
            XCTFail("\(key) syncs stations client-side; the server already owns them")
        }
    }

    /// `SettingsTransfer` exports by prefix, so the key has to sit under one it recognises
    /// or pairing a new phone would silently arrive without your shows.
    func testTheKeyIsCarriedByPairingAndExportToo() {
        XCTAssertTrue(SettingsTransfer.isExportablePreference(PodcastSubscriptionStore.syncedFeedsKey),
                      "a paired phone must receive subscriptions as well")
        XCTAssertTrue(SettingsTransfer.isExportablePreference(PodcastSubscriptionStore.ledgerKey),
                      "and the ledger that carries unsubscribes")
    }

    // MARK: - Adoption

    func testAnArrivingFeedIsAdoptedWhenNotAlreadySubscribed() async {
        let defaults = makeDefaults()
        defaults.set(["https://example.com/feed.xml"], forKey: PodcastSubscriptionStore.syncedFeedsKey)
        // Fails to fetch, which is fine: what's under test is that it *tries* — that the
        // arriving URL is recognised as new rather than ignored.
        let store = PodcastSubscriptionStore(fetch: { _ in throw URLError(.notConnectedToInternet) })

        let adopted = await store.adoptSyncedFeeds(defaults: defaults)

        XCTAssertEqual(adopted.added, 0, "a feed that won't load can't be adopted")
        XCTAssertNotNil(store.lastError, "and the attempt must be visible, not silent")
    }

    func testNothingToAdoptIsCheapAndSilent() async {
        let store = PodcastSubscriptionStore(fetch: { _ in throw URLError(.badURL) })

        let adopted = await store.adoptSyncedFeeds(defaults: makeDefaults())

        XCTAssertEqual(adopted.added, 0)
        XCTAssertEqual(adopted.removed, 0)
        XCTAssertNil(store.lastError, "an empty list is not a failure")
    }

    /// Silence is still not a deletion. An empty or stale list carries no tombstone, so it
    /// says nothing about the shows this device holds — which is the property the old
    /// additive union was protecting, and the one that must survive the change.
    func testAnEmptyListStillRemovesNothing() async {
        let defaults = makeDefaults()
        defaults.set([] as [String], forKey: PodcastSubscriptionStore.syncedFeedsKey)
        let store = PodcastSubscriptionStore(fetch: { _ in throw URLError(.badURL) })

        _ = await store.adoptSyncedFeeds(defaults: defaults)

        XCTAssertTrue(store.channels.isEmpty, "nothing to add, and nothing removed either")
    }
}

/// The ledger that lets an unsubscribe travel.
///
/// The old synced shape was a list of feed URLs merged by union, which converges for
/// subscribing and is structurally unable to express unsubscribing: drop a show on the Mac
/// and the phone hands it straight back. These are the properties the replacement has to
/// hold — including the one the union got right, which is that a device that has merely
/// been asleep must not be able to delete anything.
final class PodcastSubscriptionLedgerTests: XCTestCase {
    private let feed = "https://example.com/feed.xml"
    private let other = "https://example.org/other.xml"

    private func at(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(minutes) * 60)
    }

    // MARK: The bug this exists to fix

    /// Unsubscribe on the Mac at 10:04, phone last confirmed the subscription at 09:12.
    /// The show goes.
    func testAnUnsubscribeBeatsAnOlderSubscription() {
        var mac = PodcastSubscriptionLedger()
        mac.note(feed: feed, removed: true, at: at(64))
        var phone = PodcastSubscriptionLedger()
        phone.note(feed: feed, removed: false, at: at(12))

        let merged = PodcastSubscriptionLedger.merged(mac, phone, now: at(70))

        XCTAssertTrue(merged.record(for: feed)?.removed == true)
        XCTAssertTrue(merged.liveFeeds.isEmpty, "the show should be gone on both devices")
    }

    /// And changing your mind again works, or the tombstone would be a life sentence.
    func testASubsequentResubscribeBeatsTheTombstone() {
        var mac = PodcastSubscriptionLedger()
        mac.note(feed: feed, removed: true, at: at(64))
        var phone = PodcastSubscriptionLedger()
        phone.note(feed: feed, removed: false, at: at(90))

        let merged = PodcastSubscriptionLedger.merged(mac, phone)

        XCTAssertEqual(merged.liveFeeds, [PodcastSubscriptionLedger.normalize(feed)])
    }

    /// The property the union already had, which must not be lost: a device that simply
    /// hasn't synced in a while says nothing about shows it has never heard of.
    func testADeviceThatKnowsNothingDeletesNothing() {
        var mac = PodcastSubscriptionLedger()
        mac.note(feed: feed, removed: false, at: at(10))
        let sleepyPhone = PodcastSubscriptionLedger()

        let merged = PodcastSubscriptionLedger.merged(mac, sleepyPhone)

        XCTAssertEqual(merged.liveFeeds, [PodcastSubscriptionLedger.normalize(feed)])
    }

    /// Two devices subscribing to different shows must end up with both, not one list
    /// overwriting the other — the failure a whole-document last-write-wins would cause.
    func testConcurrentSubscriptionsConvergeRatherThanClobber() {
        var mac = PodcastSubscriptionLedger()
        mac.note(feed: feed, removed: false, at: at(10))
        var phone = PodcastSubscriptionLedger()
        phone.note(feed: other, removed: false, at: at(11))

        let merged = PodcastSubscriptionLedger.merged(mac, phone)

        XCTAssertEqual(Set(merged.liveFeeds), Set([feed, other].map(PodcastSubscriptionLedger.normalize)))
    }

    /// Subscribing to the same show on both devices is one subscription, not two.
    func testTheSameShowOnBothDevicesIsOneEntry() {
        var mac = PodcastSubscriptionLedger()
        mac.note(feed: feed, removed: false, at: at(10))
        var phone = PodcastSubscriptionLedger()
        phone.note(feed: feed + "/", removed: false, at: at(11))

        let merged = PodcastSubscriptionLedger.merged(mac, phone)

        XCTAssertEqual(merged.records.count, 1, "a trailing slash is not a different show")
    }

    /// A tie is either a clock collision or the same edit twice. Keep the removal, because
    /// the other choice silently resurrects something the user deleted.
    func testATieKeepsTheRemoval() {
        var a = PodcastSubscriptionLedger()
        a.note(feed: feed, removed: false, at: at(10))
        var b = PodcastSubscriptionLedger()
        b.note(feed: feed, removed: true, at: at(10))

        XCTAssertTrue(PodcastSubscriptionLedger.merged(a, b, now: at(20)).liveFeeds.isEmpty)
        XCTAssertTrue(PodcastSubscriptionLedger.merged(b, a, now: at(20)).liveFeeds.isEmpty,
                      "and the answer cannot depend on argument order")
    }

    // MARK: Housekeeping

    /// Tombstones can't accumulate forever, but they also can't be dropped early: the
    /// moment one disappears, a device still holding the show re-adds it.
    func testTombstonesExpireEventuallyButNotSoon() {
        var ledger = PodcastSubscriptionLedger()
        ledger.note(feed: feed, removed: true, at: at(0))

        let aWeekLater = at(0).addingTimeInterval(7 * 24 * 3600)
        XCTAssertEqual(PodcastSubscriptionLedger.merged(ledger, .init(), now: aWeekLater).records.count, 1,
                       "a week-old tombstone is still doing its job")

        let ages = at(0).addingTimeInterval(PodcastSubscriptionLedger.tombstoneRetention + 1)
        XCTAssertTrue(PodcastSubscriptionLedger.merged(ledger, .init(), now: ages).records.isEmpty)
    }

    /// Live entries are not housekeeping — a show you subscribed to years ago and never
    /// touched must not evaporate.
    func testAnOldSubscriptionNeverExpires() {
        var ledger = PodcastSubscriptionLedger()
        ledger.note(feed: feed, removed: false, at: at(0))
        let ages = at(0).addingTimeInterval(PodcastSubscriptionLedger.tombstoneRetention * 3)

        XCTAssertEqual(PodcastSubscriptionLedger.merged(ledger, .init(), now: ages).liveFeeds.count, 1)
    }

    // MARK: Reconciling with what the device actually holds

    /// A show removed locally becomes a tombstone rather than simply vanishing from the
    /// ledger — vanishing is what made it un-syncable in the first place.
    func testReconcileTurnsALocalRemovalIntoATombstone() {
        var ledger = PodcastSubscriptionLedger()
        ledger.note(feed: feed, removed: false, at: at(10))

        ledger.reconcile(withSubscribed: [], at: at(20))

        XCTAssertTrue(ledger.record(for: feed)?.removed == true)
    }

    /// The race that would quietly undo every remote unsubscribe.
    ///
    /// Between the other device removing a show and this one applying it, the show is still
    /// on disk here. If reconcile treated "present" as "subscribed" it would stamp a fresh
    /// subscription over the incoming tombstone — on every persist — and the unsubscribe
    /// would be won by whichever device saved a file last rather than by whoever acted last.
    func testReconcileDoesNotResurrectAFeedTombstonedElsewhere() {
        var ledger = PodcastSubscriptionLedger()
        ledger.note(feed: feed, removed: true, at: at(10))

        // The show has not been deleted locally yet — adoption hasn't run.
        ledger.reconcile(withSubscribed: [feed], at: at(20))

        XCTAssertTrue(ledger.record(for: feed)?.removed == true,
                      "a pending removal must survive a local save")
        XCTAssertEqual(ledger.record(for: feed)?.at, at(10), "and must not be re-stamped")
    }

    /// But asking for it back on purpose still works — `subscribe(to:)` says so explicitly.
    func testADeliberateResubscribeBeatsTheTombstone() {
        var ledger = PodcastSubscriptionLedger()
        ledger.note(feed: feed, removed: true, at: at(10))
        ledger.note(feed: feed, removed: false, at: at(30))
        XCTAssertEqual(ledger.liveFeeds, [PodcastSubscriptionLedger.normalize(feed)])
    }

    func testReconcileAdoptsShowsSubscribedLocally() {
        var ledger = PodcastSubscriptionLedger()
        ledger.reconcile(withSubscribed: [feed], at: at(20))
        XCTAssertEqual(ledger.liveFeeds, [PodcastSubscriptionLedger.normalize(feed)])
    }

    /// Reconciling twice must not keep moving the timestamp, or every sync would look like
    /// a fresh edit and the two devices would ping-pong forever.
    func testReconcileIsIdempotent() {
        var ledger = PodcastSubscriptionLedger()
        ledger.reconcile(withSubscribed: [feed], at: at(20))
        let first = ledger
        ledger.reconcile(withSubscribed: [feed], at: at(40))
        XCTAssertEqual(ledger, first)
    }

    // MARK: Meeting an older build

    /// A device still writing the old plain list must never resurrect deleted shows. Legacy
    /// entries are dated to the distant past so any real tombstone outranks them.
    func testTheLegacyListCannotUndoAnUnsubscribe() {
        var modern = PodcastSubscriptionLedger()
        modern.note(feed: feed, removed: true, at: at(10))
        let legacy = PodcastSubscriptionLedger.fromLegacyFeeds([feed])

        XCTAssertTrue(PodcastSubscriptionLedger.merged(modern, legacy, now: at(20)).liveFeeds.isEmpty)
    }

    /// But a show that is genuinely new on the old device still arrives.
    func testTheLegacyListStillDeliversNewShows() {
        let legacy = PodcastSubscriptionLedger.fromLegacyFeeds([other])
        let merged = PodcastSubscriptionLedger.merged(.init(), legacy)
        XCTAssertEqual(merged.liveFeeds, [PodcastSubscriptionLedger.normalize(other)])
    }

    func testAMalformedLedgerIsNothingRatherThanACrash() {
        XCTAssertNil(PodcastSubscriptionLedger.decode(Data("not json".utf8)))
        XCTAssertNil(PodcastSubscriptionLedger.decode(nil))
    }
}
