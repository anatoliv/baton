import ActivityKit
import Foundation

/// The Live Activity contract between the app and the widget extension: what's
/// playing, for the Lock Screen and Dynamic Island.
struct NowPlayingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String?
        var isPlaying: Bool
        /// Cover filename in the App Group container. The widget process reads it off
        /// disk; it cannot fetch a URL in time to draw.
        var artworkFile: String?
        /// Where playback is, so the card can show a progress bar that keeps moving
        /// without the app waking to push every second.
        var elapsed: TimeInterval = 0
        var duration: TimeInterval = 0
    }
    /// Fixed for the life of one activity; the queue label ("Playing from …").
    var sourceLabel: String
}
