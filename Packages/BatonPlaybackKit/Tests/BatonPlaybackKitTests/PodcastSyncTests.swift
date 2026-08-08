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
            FilterHistory.storageKey("podcasts"),
            FilterHistory.storageKey("clientPodcastEpisodes"),
        ]
        for key in PreferenceSync.syncedKeys where key.lowercased().contains("podcast") {
            XCTAssertTrue(allowed.contains(key),
                          "\(key) shouldn't be syncing — only the feed list and filter history should")
        }
    }

    /// `SettingsTransfer` exports by prefix, so the key has to sit under one it recognises
    /// or pairing a new phone would silently arrive without your shows.
    func testTheKeyIsCarriedByPairingAndExportToo() {
        XCTAssertTrue(SettingsTransfer.isExportablePreference(PodcastSubscriptionStore.syncedFeedsKey),
                      "a paired phone must receive subscriptions as well")
    }

    // MARK: - Adoption

    func testAnArrivingFeedIsAdoptedWhenNotAlreadySubscribed() async {
        let defaults = makeDefaults()
        defaults.set(["https://example.com/feed.xml"], forKey: PodcastSubscriptionStore.syncedFeedsKey)
        // Fails to fetch, which is fine: what's under test is that it *tries* — that the
        // arriving URL is recognised as new rather than ignored.
        let store = PodcastSubscriptionStore(fetch: { _ in throw URLError(.notConnectedToInternet) })

        let adopted = await store.adoptSyncedFeeds(defaults: defaults)

        XCTAssertEqual(adopted, 0, "a feed that won't load can't be adopted")
        XCTAssertNotNil(store.lastError, "and the attempt must be visible, not silent")
    }

    func testNothingToAdoptIsCheapAndSilent() async {
        let store = PodcastSubscriptionStore(fetch: { _ in throw URLError(.badURL) })

        let adopted = await store.adoptSyncedFeeds(defaults: makeDefaults())

        XCTAssertEqual(adopted, 0)
        XCTAssertNil(store.lastError, "an empty list is not a failure")
    }

    /// Additive by design: a stale list from one device must not delete shows on another.
    func testAdoptionNeverRemovesSubscriptions() async {
        let defaults = makeDefaults()
        defaults.set([] as [String], forKey: PodcastSubscriptionStore.syncedFeedsKey)
        let store = PodcastSubscriptionStore(fetch: { _ in throw URLError(.badURL) })

        _ = await store.adoptSyncedFeeds(defaults: defaults)

        XCTAssertTrue(store.channels.isEmpty, "nothing to add, and nothing removed either")
    }
}
