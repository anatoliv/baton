import Foundation
import Observation
import OSLog

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
final class PodcastSubscriptionStore {
    /// Subscribed shows, most-recently-updated first.
    private(set) var channels: [PodcastChannel] = []
    /// A refresh (all feeds) or a subscribe is in flight — drives the header spinner.
    private(set) var isRefreshing = false
    /// Last user-facing failure (subscribe/refresh); cleared on the next success.
    var lastError: String?

    private var loaded = false

    /// Fetches a feed's bytes. Injectable so tests supply canned RSS without the network.
    private let fetch: (URL) async throws -> Data
    private let storeURL: URL

    init(
        directory: URL? = nil,
        fetch: @escaping (URL) async throws -> Data = { url in
            var request = URLRequest(url: url)
            request.setValue("Baton (macOS; Podcasts)", forHTTPHeaderField: "User-Agent")
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
    /// Versioned, corruption-safe backing for the subscription list (W-12). keepBackup
    /// because a lost subscription list is irreplaceable user data.
    private var store: VersionedStore<[PodcastChannel]> {
        VersionedStore(fileURL: storeURL, keepBackup: true, encoder: .podcast, decoder: .podcast)
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let saved = store.load() {
            channels = saved.sorted(by: Self.byRecency)
        }
        await refresh()
    }

    private func persist() {
        store.save(channels) // logs on failure; a corrupt file is preserved, never wiped
    }

    // MARK: - Mutations

    /// Subscribes to a feed: fetches, parses, and appends (or refreshes in place if already
    /// subscribed). Throws a user-presentable error when the URL isn't a usable podcast feed.
    @discardableResult
    func subscribe(to feedURL: URL) async throws -> PodcastChannel {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let channel = try await fetchChannel(feedURL: feedURL)
            upsert(channel)
            lastError = nil
            persist()
            return channel
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            throw error
        }
    }

    /// Removes a subscription and its cached episodes.
    func unsubscribe(_ channel: PodcastChannel) {
        channels.removeAll { $0.id == channel.id }
        persist()
    }

    /// Re-fetches every subscribed feed concurrently, replacing each channel's episodes with
    /// the freshly-parsed list. Feeds that fail keep their last-known cached episodes — a dead
    /// feed shouldn't erase a show you're subscribed to.
    func refresh() async {
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
    func asSong(channelTitle: String, artwork: URL?) -> NavidromeSong {
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
    static var podcast: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var podcast: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
