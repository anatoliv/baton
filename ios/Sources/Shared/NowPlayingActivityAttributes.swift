import ActivityKit
import Foundation

/// The Live Activity contract between the app and the widget extension: what's
/// playing, for the Lock Screen and Dynamic Island.
struct NowPlayingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String?
        var isPlaying: Bool
    }
    /// Fixed for the life of one activity; the queue label ("Playing from …").
    var sourceLabel: String
}
