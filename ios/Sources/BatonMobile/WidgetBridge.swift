import ActivityKit
import Foundation
import ImageIO
import WidgetKit

/// The app→widget bridge: a tiny now-playing snapshot in the App Group defaults,
/// refreshed on track changes (Cassette's App-Group pattern — the widget process
/// never touches the app's DI graph, only this one JSON blob).
enum WidgetBridge {
    static let appGroupID = "group.io.tonebox.baton"
    static let snapshotKey = "baton.widget.nowPlaying"

    struct Snapshot: Codable {
        var title: String
        var artist: String?
        var songID: String
        var isPlaying: Bool
        /// Always nil now; kept so the shape the widget decodes does not change.
        ///
        /// A widget's network access is throttled and its view builds synchronously, so a
        /// URL here meant the cover simply never drew: the snapshot carried the artwork all
        /// along and the widget rendered a music-note glyph next to it. The bytes go into
        /// the App Group container instead, where the widget can read them straight off
        /// disk. The URL is a signed Subsonic link whose query carries the account's user
        /// name and token, so it no longer crosses the boundary (TBX-1000000480 B-18).
        var artworkURL: URL?
        /// Filename inside the App Group container, written by `storeArtwork`.
        var artworkFile: String?
        var updatedAt: Date
    }

    /// Where the cover for the current track lives, for the widget process to read.
    ///
    /// One filename, overwritten each time: a per-track cache in a shared container is a
    /// slow leak nobody notices until the app is using a few hundred megabytes for covers
    /// of songs played once. The widget only ever needs the current one.
    static let artworkFilename = "nowplaying-cover.jpg"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Downloads the cover, ready to drop in the shared container. Best-effort: a missing
    /// cover must never hold up publishing what is playing, so failures are silent and the
    /// widget falls back to its glyph.
    ///
    /// Returns the bytes rather than writing them, so the write can wait until it is known
    /// that no newer publish has happened since (TBX-1000000480 B-2).
    private static func downloadArtwork(_ url: URL?) async -> Data? {
        guard let url, containerURL != nil else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Widgets are memory-capped hard (about 30MB); a full-size cover decoded in
            // that process is a crash, not a slow render. Server thumbnails are already
            // small, so this is a guard against a pathological one rather than a resize.
            guard data.count < 2_000_000 else { return nil }
            // Drawn at most a few dozen points wide on the Lock Screen; a full-size book cover
            // is scaled down here, once, rather than decoded whole in the widget.
            return thumbnail(data, maxPixels: 300) ?? data
        } catch {
            return nil
        }
    }

    /// The cover download, replaceable so a test can decide when a cover lands.
    @MainActor static var fetchArtwork: @MainActor (URL?) async -> Data? = { await downloadArtwork($0) }

    /// Writes the current track's cover where the widget reads it.
    @MainActor private static func storeArtwork(_ data: Data) -> String? {
        guard let container = containerURL else { return nil }
        do {
            try data.write(to: container.appendingPathComponent(artworkFilename), options: .atomic)
            return artworkFilename
        } catch {
            return nil
        }
    }

    /// A JPEG of at most `maxPixels` on its longer side, or nil when the bytes are not a picture.
    private static func thumbnail(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// Bumped by every publish, so a cover that lands after a newer publish is dropped rather
    /// than writing its older track and play state back over it (TBX-1000000480 B-2).
    @MainActor private static var publishGeneration = 0

    @MainActor
    static func publish(song: NavidromeSong?, isPlaying: Bool, artworkURL: URL?,
                        elapsed: TimeInterval = 0, duration: TimeInterval = 0) {
        publishGeneration += 1
        let generation = publishGeneration
        let defaults = UserDefaults(suiteName: appGroupID)
        guard let song else {
            defaults?.removeObject(forKey: snapshotKey)
            // The cover too: nothing playing, after a purge above all, leaves no picture of
            // the last track in the App Group.
            if let container = containerURL {
                try? FileManager.default.removeItem(at: container.appendingPathComponent(artworkFilename))
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "BatonNowPlaying")
            publishLiveActivity(song: song, isPlaying: isPlaying, artworkFile: nil,
                                sourceLabel: "Baton")
            return
        }
        // Publish immediately without the cover, then again once it has landed. A play/pause
        // tap must move the widget now; waiting on a download to redraw a pause icon is the
        // kind of lag that makes a widget feel broken.
        write(song: song, isPlaying: isPlaying, artworkURL: artworkURL,
              artworkFile: read()?.songID == song.id ? read()?.artworkFile : nil,
              defaults: defaults)
        publishLiveActivity(song: song, isPlaying: isPlaying,
                            artworkFile: read()?.artworkFile, sourceLabel: "Baton",
                            elapsed: elapsed, duration: duration)

        Task {
            guard let data = await fetchArtwork(artworkURL) else { return }
            await MainActor.run {
                guard generation == publishGeneration, let file = storeArtwork(data) else { return }
                write(song: song, isPlaying: isPlaying, artworkURL: artworkURL,
                      artworkFile: file, defaults: defaults)
                publishLiveActivity(song: song, isPlaying: isPlaying,
                                    artworkFile: file, sourceLabel: "Baton",
                                    elapsed: elapsed, duration: duration)
            }
        }
    }

    @MainActor
    private static func write(song: NavidromeSong, isPlaying: Bool, artworkURL: URL?,
                              artworkFile: String?, defaults: UserDefaults?) {
        // Cleaned here rather than in the widget: that target takes no package
        // dependencies (sources only, see ios/project.yml), so `DisplayName` cannot reach
        // it. The JSON contract is the boundary, so the boundary is where the placeholder
        // rule is applied — a nil artist crossing it means "there is no artist", which is
        // exactly what the widget already draws for.
        let snapshot = Snapshot(
            title: DisplayName.title(song.title), artist: DisplayName.artist(song.artist),
            songID: song.id,
            isPlaying: isPlaying, artworkURL: nil,
            artworkFile: artworkFile, updatedAt: Date()
        )
        defaults?.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "BatonNowPlaying")
    }

    // MARK: - Live Activity

    @MainActor private static var activity: Activity<NowPlayingActivityAttributes>?

    // ActivityKit's `end` and `update` are nonisolated, while `activity` above is
    // main-actor isolated. Handing that handle straight to a `Task` sends a main-actor
    // value into the nonisolated domain, which Swift 6.3 rejects and 6.2 allowed.
    //
    // So send the id instead — a String, and Sendable — and look the handle up again on
    // the other side. That is the same mechanism the orphan adoption below already
    // relies on: `Activity.activities` is the source of truth for what is running, and
    // it is readable from any isolation domain.
    private nonisolated static func endActivity(id: String) async {
        guard let activity = Activity<NowPlayingActivityAttributes>.activities
            .first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private nonisolated static func updateActivity(
        id: String, state: NowPlayingActivityAttributes.ContentState
    ) async {
        guard let activity = Activity<NowPlayingActivityAttributes>.activities
            .first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state)))
    }

    /// When the system should stop believing a pushed state. `nil` meant never, which is
    /// how a jetsammed app left a card on the Lock Screen announcing a song that stopped
    /// hours ago (I-F11). The widget reads `context.isStale` and goes quiet.
    private nonisolated static func staleDate(
        for state: NowPlayingActivityAttributes.ContentState
    ) -> Date {
        WidgetFreshness.activityStaleDate(
            from: Date(), elapsed: state.elapsed, duration: state.duration,
            isPlaying: state.isPlaying
        )
    }

    /// Starts/updates/ends the Lock Screen activity to mirror the player. Ending on
    /// nil keeps a stale island from outliving playback.
    @MainActor
    static func publishLiveActivity(song: NavidromeSong?, isPlaying: Bool,
                                    artworkFile: String?, sourceLabel: String,
                                    elapsed: TimeInterval = 0, duration: TimeInterval = 0) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let song else {
            if let running = activity {
                let id = running.id
                Task { await endActivity(id: id) }
                activity = nil
            }
            return
        }
        let state = NowPlayingActivityAttributes.ContentState(
            title: DisplayName.title(song.title), artist: DisplayName.artist(song.artist),
            isPlaying: isPlaying,
            artworkFile: artworkFile, elapsed: elapsed, duration: duration
        )
        // A Live Activity outlives the app that started it — that is the whole point of one
        // — but `activity` is an in-memory handle that does not. After a relaunch the
        // handle is nil while the card is still on the lock screen, so requesting another
        // stacks a second card next to an orphan nothing can update. Reinstall a few times
        // in a day and you have a little pile of them, only the newest responding.
        //
        // So before starting anything, adopt what the system says is already running: keep
        // one, end the rest. `Activity.activities` is the only source of truth here, and
        // it survives the launch that loses our handle.
        if activity == nil {
            let alreadyRunning = Activity<NowPlayingActivityAttributes>.activities
            activity = alreadyRunning.first
            for orphan in alreadyRunning.dropFirst() {
                let id = orphan.id
                Task { await endActivity(id: id) }
            }
        }

        if let running = activity {
            let id = running.id
            Task { await updateActivity(id: id, state: state) }
        } else {
            activity = try? Activity.request(
                attributes: NowPlayingActivityAttributes(sourceLabel: sourceLabel),
                content: ActivityContent(state: state, staleDate: staleDate(for: state))
            )
        }
    }

    static func read() -> Snapshot? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
