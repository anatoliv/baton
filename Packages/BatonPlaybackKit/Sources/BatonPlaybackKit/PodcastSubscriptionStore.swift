import Foundation
import Observation
import OSLog
import BatonSubsonicKit
import BatonSubsonicModels

private let podcastStoreLog = Logger(subsystem: "io.tonebox.baton", category: "PodcastSubscriptions")

/// Owns the user's *client-side* podcast subscriptions — the ones Baton fetches directly from
/// RSS feeds, independent of the music server. Subscriptions and their last-fetched episodes
/// are persisted as JSON in Application Support, so the Podcasts tab paints instantly (and
/// works offline) while a background refresh pulls new episodes.
///
/// This is what makes podcasts work on Navidrome, which never implements the Subsonic podcast
/// API — see [[baton-podcasts]]. It's a single global store (podcasts are the user's own
/// subscriptions, not tied to any one server) and lives on `MusicModel`.
@MainActor
@Observable
public final class PodcastSubscriptionStore {
    /// Subscribed shows, most-recently-updated first.
    public private(set) var channels: [PodcastChannel] = []
    /// A refresh (all feeds) or a subscribe is in flight — drives the header spinner.
    public private(set) var isRefreshing = false
    /// Last user-facing failure (subscribe/refresh); cleared on the next success.
    public var lastError: String?

    private var loaded = false

    /// Fetches a feed's bytes. Injectable so tests supply canned RSS without the network.
    private let fetch: (URL) async throws -> Data
    private let storeURL: URL

    public init(
        directory: URL? = nil,
        fetch: @escaping (URL) async throws -> Data = { url in
            var request = URLRequest(url: url)
            #if os(iOS)
            request.setValue("Baton (iOS; Podcasts)", forHTTPHeaderField: "User-Agent")
            #else
            request.setValue("Baton (macOS; Podcasts)", forHTTPHeaderField: "User-Agent")
            #endif
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                throw PodcastFeedError.invalidFeed("HTTP \(http.statusCode)")
            }
            return data
        }
    ) {
        self.fetch = fetch
        let dir = directory ?? Self.defaultDirectory()
        storeURL = dir.appendingPathComponent("podcasts.json")
    }

    // MARK: - Load / persist

    /// Reads persisted subscriptions once, then kicks off a background refresh so episode lists
    /// are current. Safe to call from `.task` on every appearance.
    /// Versioned, corruption-safe backing for the subscription list. keepBackup
    /// because a lost subscription list is irreplaceable user data.
    private var store: VersionedStore<[PodcastChannel]> {
        VersionedStore(fileURL: storeURL, keepBackup: true, encoder: .podcast, decoder: .podcast)
    }

    public func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let saved = store.load() {
            channels = saved.sorted(by: Self.byRecency)
        }
        await refresh()
    }

    private func persist() {
        store.save(channels) // logs on failure; a corrupt file is preserved, never wiped
        mirrorFeedsForSync()
    }

    /// Record a deliberate subscribe or unsubscribe against a feed.
    private func noteLedger(_ feed: String, removed: Bool, defaults: UserDefaults = .standard) {
        var ledger = PodcastSubscriptionLedger.decode(defaults.data(forKey: Self.ledgerKey))
            ?? PodcastSubscriptionLedger.fromLegacyFeeds(defaults.stringArray(forKey: Self.syncedFeedsKey) ?? [])
        ledger.note(feed: feed, removed: removed)
        if let encoded = ledger.encoded() { defaults.set(encoded, forKey: Self.ledgerKey) }
    }

    /// Which shows you subscribe to, in a place cross-device sync can actually see.
    ///
    /// Subscriptions live as JSON in Application Support, and both transports —
    /// `PreferenceSync` and `SettingsTransfer` — carry `UserDefaults` and the Keychain.
    /// So podcasts could not travel between a Mac and a phone at all: you subscribed on
    /// one and the other never heard about it. Mirroring into a synced default fixes that
    /// without shipping the episode cache, which is derived data every device should fetch
    /// for itself rather than inherit stale.
    private func mirrorFeedsForSync() {
        let defaults = UserDefaults.standard
        let feeds = channels.map(\.feedURL.absoluteString)

        // The ledger is the real record: it can say "unsubscribed", which a list cannot.
        var ledger = PodcastSubscriptionLedger.decode(defaults.data(forKey: Self.ledgerKey))
            ?? PodcastSubscriptionLedger.fromLegacyFeeds(defaults.stringArray(forKey: Self.syncedFeedsKey) ?? [])
        ledger.reconcile(withSubscribed: feeds)
        if let encoded = ledger.encoded(), defaults.data(forKey: Self.ledgerKey) != encoded {
            defaults.set(encoded, forKey: Self.ledgerKey)
        }

        // The plain list is still written, for a device on an older build that only knows
        // how to read that. It syncs additively there, exactly as it always did.
        if defaults.stringArray(forKey: Self.syncedFeedsKey) != feeds {
            defaults.set(feeds, forKey: Self.syncedFeedsKey)
        }
    }

    /// The synced list of feed URLs. Under `tonebox.` so `SettingsTransfer` exports it by
    /// the same prefix rule as everything else.
    ///
    /// Superseded by `ledgerKey`, and still written so a device running an older build
    /// keeps working. It cannot express an unsubscribe, which is why it was replaced.
    public static let syncedFeedsKey = "tonebox.podcasts.feeds"

    /// Subscribes *and* unsubscribes, as a `PodcastSubscriptionLedger`.
    public static let ledgerKey = "tonebox.podcasts.subscriptions"

    /// Brings this device into line with what the other one did.
    ///
    /// Both directions now, which is the change: it adopts shows added elsewhere, **and**
    /// drops shows unsubscribed elsewhere. The second half is only safe because a tombstone
    /// carries a time — a device that simply hasn't synced in a while no longer looks the
    /// same as one that deliberately removed something.
    ///
    /// Returns what it did, so a caller can say so rather than having the list change under
    /// the user with no explanation.
    @discardableResult
    public func adoptSyncedFeeds(defaults: UserDefaults = .standard) async -> (added: Int, removed: Int) {
        let ledger = PodcastSubscriptionLedger.merged(
            PodcastSubscriptionLedger.decode(defaults.data(forKey: Self.ledgerKey)) ?? .init(),
            PodcastSubscriptionLedger.fromLegacyFeeds(defaults.stringArray(forKey: Self.syncedFeedsKey) ?? [])
        )

        // Removals first: dropping a show costs nothing and cannot fail, while a subscribe
        // hits the network. Doing them in this order means a slow feed can't leave the
        // unsubscribe half-applied.
        var removed = 0
        for channel in channels
        where ledger.record(for: channel.feedURL.absoluteString)?.removed == true {
            channels.removeAll { $0.id == channel.id }
            removed += 1
        }

        let known = Set(channels.map { PodcastSubscriptionLedger.normalize($0.feedURL.absoluteString) })
        let incoming = ledger.liveFeeds
            .filter { !known.contains($0) }
            .compactMap(URL.init(string:))

        var added = 0
        for feed in incoming {
            do {
                _ = try await subscribe(to: feed)
                added += 1
            } catch {
                // One dead feed must not stop the rest arriving.
                podcastStoreLog.error("couldn't adopt synced feed \(feed.absoluteString, privacy: .public)")
            }
        }
        if removed > 0 && added == 0 { persist() }
        return (added, removed)
    }

    // MARK: - Mutations

    /// Subscribes to a feed: fetches, parses, and appends (or refreshes in place if already
    /// subscribed). Throws a user-presentable error when the URL isn't a usable podcast feed.
    @discardableResult
    public func subscribe(to feedURL: URL) async throws -> PodcastChannel {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let channel = try await fetchChannel(feedURL: feedURL)
            upsert(channel)
            lastError = nil
            // Said explicitly, not inferred from the file system. Subscribing is the one
            // move that has to be able to beat an existing tombstone, and `reconcile`
            // deliberately won't do that on its own — see `PodcastSubscriptionLedger`.
            noteLedger(feedURL.absoluteString, removed: false)
            persist()
            return channel
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            throw error
        }
    }

    /// Removes a subscription and its cached episodes.
    public func unsubscribe(_ channel: PodcastChannel) {
        channels.removeAll { $0.id == channel.id }
        persist()
    }

    /// Re-fetches every subscribed feed concurrently, replacing each channel's episodes with
    /// the freshly-parsed list. Feeds that fail keep their last-known cached episodes — a dead
    /// feed shouldn't erase a show you're subscribed to.
    public func refresh() async {
        guard !channels.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let feeds = channels.map(\.feedURL)
        let refreshed = await withTaskGroup(of: PodcastChannel?.self) { group in
            for feed in feeds {
                group.addTask { [weak self] in try? await self?.fetchChannel(feedURL: feed) }
            }
            var out: [PodcastChannel] = []
            for await channel in group { if let channel { out.append(channel) } }
            return out
        }
        for channel in refreshed { upsert(channel) }
        channels.sort(by: Self.byRecency)
        persist()
    }

    // MARK: - Fetch + merge

    private func fetchChannel(feedURL: URL) async throws -> PodcastChannel {
        let data = try await fetch(feedURL)
        let parsed = try PodcastFeedParser.parse(data)
        return PodcastChannel(
            feedURL: feedURL,
            title: parsed.title,
            description: parsed.description,
            imageURL: parsed.imageURL,
            episodes: parsed.episodes,
            lastRefreshed: Date()
        )
    }

    /// Inserts a channel, or replaces an existing subscription with the same feed URL in place
    /// (preserving list order for a refresh; the caller re-sorts when it wants recency order).
    private func upsert(_ channel: PodcastChannel) {
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index] = channel
        } else {
            channels.insert(channel, at: 0)
        }
    }

    private static func byRecency(_ lhs: PodcastChannel, _ rhs: PodcastChannel) -> Bool {
        (lhs.episodes.first?.publishDate ?? lhs.lastRefreshed ?? .distantPast)
            > (rhs.episodes.first?.publishDate ?? rhs.lastRefreshed ?? .distantPast)
    }

    // MARK: - Storage location

    /// `~/Library/Application Support/Baton/`, matching the download cache + control socket.
    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Baton", isDirectory: true)
    }
}

// MARK: - Episode → Song (playback)

extension PodcastEpisode {
    /// Maps a client-side episode to the `NavidromeSong` the player streams. The song `id` is
    /// the **enclosure URL** — `StreamingPlaybackController` plays absolute http(s) ids
    /// directly (see `resolveStreamURL`), so no server round-trip is involved. `artwork` (the
    /// episode's image, falling back to the channel's) rides along as a direct `artworkURL` so
    /// every now-playing surface shows the show's cover.
    public func asSong(channelTitle: String, artwork: URL?) -> NavidromeSong {
        NavidromeSong(
            id: enclosureURL.absoluteString,
            title: title,
            artist: channelTitle,
            album: channelTitle,
            albumID: nil,
            duration: duration,
            coverArtID: nil,
            artworkURL: artwork
        )
    }
}

private extension JSONEncoder {
    public static var podcast: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    public static var podcast: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
