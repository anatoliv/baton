import ActivityKit
import Foundation
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
        /// Direct artwork URL — kept for reference, but the widget does not fetch it.
        ///
        /// A widget's network access is throttled and its view builds synchronously, so a
        /// URL here meant the cover simply never drew: the snapshot carried the artwork all
        /// along and the widget rendered a music-note glyph next to it. The bytes go into
        /// the App Group container instead, where the widget can read them straight off
        /// disk. No credentials cross the boundary either way — the URL is pre-signed.
        var artworkURL: URL?
        /// Filename inside the App Group container, written by `cacheArtwork`.
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

    /// Downloads the cover and drops it in the shared container. Best-effort: a missing
    /// cover must never hold up publishing what is playing, so failures are silent and the
    /// widget falls back to its glyph.
    private static func cacheArtwork(_ url: URL?) async -> String? {
        guard let url, let container = containerURL else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Widgets are memory-capped hard (about 30MB); a full-size cover decoded in
            // that process is a crash, not a slow render. Server thumbnails are already
            // small, so this is a guard against a pathological one rather than a resize.
            guard data.count < 2_000_000 else { return nil }
            let destination = container.appendingPathComponent(artworkFilename)
            try data.write(to: destination, options: .atomic)
            return artworkFilename
        } catch {
            return nil
        }
    }

    @MainActor
    static func publish(song: NavidromeSong?, isPlaying: Bool, artworkURL: URL?,
                        elapsed: TimeInterval = 0, duration: TimeInterval = 0) {
        let defaults = UserDefaults(suiteName: appGroupID)
        guard let song else {
            defaults?.removeObject(forKey: snapshotKey)
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
            guard let file = await cacheArtwork(artworkURL) else { return }
            await MainActor.run {
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
        let snapshot = Snapshot(
            title: song.title, artist: song.artist, songID: song.id,
            isPlaying: isPlaying, artworkURL: artworkURL,
            artworkFile: artworkFile, updatedAt: Date()
        )
        defaults?.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "BatonNowPlaying")
    }

    // MARK: - Live Activity

    @MainActor private static var activity: Activity<NowPlayingActivityAttributes>?

    /// Starts/updates/ends the Lock Screen activity to mirror the player. Ending on
    /// nil keeps a stale island from outliving playback.
    @MainActor
    static func publishLiveActivity(song: NavidromeSong?, isPlaying: Bool,
                                    artworkFile: String?, sourceLabel: String,
                                    elapsed: TimeInterval = 0, duration: TimeInterval = 0) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let song else {
            if let running = activity {
                Task { await running.end(nil, dismissalPolicy: .immediate) }
                activity = nil
            }
            return
        }
        let state = NowPlayingActivityAttributes.ContentState(
            title: song.title, artist: song.artist, isPlaying: isPlaying,
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
                Task { await orphan.end(nil, dismissalPolicy: .immediate) }
            }
        }

        if let running = activity {
            Task { await running.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            activity = try? Activity.request(
                attributes: NowPlayingActivityAttributes(sourceLabel: sourceLabel),
                content: ActivityContent(state: state, staleDate: nil)
            )
        }
    }

    static func read() -> Snapshot? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
