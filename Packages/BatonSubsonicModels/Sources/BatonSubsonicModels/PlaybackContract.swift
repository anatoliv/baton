import Foundation

/// What a *commanding* layer needs to know about the player, without needing the player.
///
/// `BatonAgentKit` used to depend on `BatonPlaybackKit` for exactly one reason: to read three
/// properties off `StreamingPlaybackController` while phrasing the model's "here is what is
/// playing" context. That single reference dragged the whole audio engine (AVFoundation,
/// CoreAudio, AudioToolbox, AppKit, UIKit, MediaPlayer) into every consumer of the agent layer.
///
/// **That is what stopped the gateway building on Linux.** `Transport.swift` has carried a
/// `#if canImport(Network)` / `#else` split for a POSIX accept loop all along, so a Linux build
/// was clearly intended, but the package graph made it impossible and nothing ever noticed:
/// `scripts/test.sh` builds the gateway on macOS, where the Apple branch compiles fine.
///
/// A protocol in this leaf package inverts it. The agent layer states what it needs, the
/// playback layer conforms, and neither has to know about the other's platform.
@MainActor
public protocol RemotePlayerContext: AnyObject {
    var nowPlaying: NavidromeSong? { get }
    var queue: [NavidromeSong] { get }
    var currentIndex: Int { get }
}

/// How long after a track starts a skip still counts as "I didn't want that one".
///
/// Lives here rather than beside the playback event log because two packages need it and only
/// one of them can host audio code. One definition, as the codebase's own rule requires: this
/// number appearing twice is exactly the drift that rule exists to prevent.
public enum QuickSkip {
    public static let window: TimeInterval = 10
}
