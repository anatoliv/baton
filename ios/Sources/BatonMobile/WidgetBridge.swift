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
        /// Direct artwork URL — the widget fetches it itself (signed query URL,
        /// so no credentials cross the process boundary).
        var artworkURL: URL?
        var updatedAt: Date
    }

    @MainActor
    static func publish(song: NavidromeSong?, isPlaying: Bool, artworkURL: URL?) {
        let defaults = UserDefaults(suiteName: appGroupID)
        if let song {
            let snapshot = Snapshot(
                title: song.title, artist: song.artist, songID: song.id,
                isPlaying: isPlaying, artworkURL: artworkURL, updatedAt: Date()
            )
            defaults?.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
        } else {
            defaults?.removeObject(forKey: snapshotKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "BatonNowPlaying")
        publishLiveActivity(song: song, isPlaying: isPlaying, sourceLabel: "Baton")
    }

    // MARK: - Live Activity

    @MainActor private static var activity: Activity<NowPlayingActivityAttributes>?

    /// Starts/updates/ends the Lock Screen activity to mirror the player. Ending on
    /// nil keeps a stale island from outliving playback.
    @MainActor
    static func publishLiveActivity(song: NavidromeSong?, isPlaying: Bool, sourceLabel: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let song else {
            if let running = activity {
                Task { await running.end(nil, dismissalPolicy: .immediate) }
                activity = nil
            }
            return
        }
        let state = NowPlayingActivityAttributes.ContentState(
            title: song.title, artist: song.artist, isPlaying: isPlaying
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
