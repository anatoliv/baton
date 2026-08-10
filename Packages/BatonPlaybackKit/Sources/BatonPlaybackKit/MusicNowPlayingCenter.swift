#if canImport(AppKit)
import AppKit
/// The platform's bitmap image type — NSImage on macOS, UIImage on iOS. Only used to
/// decode artwork bytes and hand them to MPMediaItemArtwork.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif
import Foundation
import MediaPlayer
import BatonSubsonicKit
import BatonSubsonicModels

/// Bridges the music player to macOS **Now Playing**: the Control Center / menu-bar
/// Now Playing widget, the hardware media keys (F7/F8/F9), and Bluetooth/AirPod
/// remotes. Publishes track metadata + artwork via `MPNowPlayingInfoCenter` and
/// routes remote commands (play/pause/next/previous/seek) back to the player through
/// injected closures. A thin sibling to `StreamingPlaybackController`, gated off
/// under XCTest so it never touches the test host's real Now Playing state.
@MainActor
public final class MusicNowPlayingCenter {
    /// Transport hooks the remote commands invoke. Wired once by the owner (player).
    public struct Handlers {
        public var play: () -> Void
        public var pause: () -> Void
        public var toggle: () -> Void
        public var next: () -> Void
        public var previous: () -> Void
        public var seek: (TimeInterval) -> Void
        /// Jump by ±15s. Podcast-only in practice, which is why it is separate from `seek`:
        /// the OS draws different buttons for skip commands than for scrubbing.
        public var skip: ((TimeInterval) -> Void)?
        /// Like / unlike what is playing, from the lock screen or CarPlay.
        public var toggleLike: (() -> Void)?
        /// "Never play this in radio" — the dislike half, which the app already models.
        public var ban: (() -> Void)?

        public init(play: @escaping () -> Void, pause: @escaping () -> Void,
                    toggle: @escaping () -> Void, next: @escaping () -> Void,
                    previous: @escaping () -> Void, seek: @escaping (TimeInterval) -> Void,
                    skip: ((TimeInterval) -> Void)? = nil,
                    toggleLike: (() -> Void)? = nil, ban: (() -> Void)? = nil) {
            self.play = play
            self.pause = pause
            self.toggle = toggle
            self.next = next
            self.previous = previous
            self.seek = seek
            self.skip = skip
            self.toggleLike = toggleLike
            self.ban = ban
        }
    }

    private var configured = false
    /// The artwork URL currently loaded (so we only refetch when the cover changes).
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var lastArtwork: MPMediaItemArtwork?

    /// Registers remote-command targets. Idempotent — safe to call more than once.
    public func configure(_ handlers: Handlers) {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in handlers.play(); return .success }
        center.pauseCommand.addTarget { _ in handlers.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in handlers.toggle(); return .success }
        center.nextTrackCommand.addTarget { _ in handlers.next(); return .success }
        center.previousTrackCommand.addTarget { _ in handlers.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handlers.seek(event.positionTime)
            return .success
        }
        for command in [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand,
        ] { command.isEnabled = true }
        // Skip ±15s — the control people actually reach for on a podcast, and the one the
        // lock screen had no way to offer because these were disabled globally. Enabled per
        // item in `update(...)`: on a song they are wrong (that is what next/previous are
        // for), on a 90-minute episode they are the whole point.
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.addTarget { _ in
            guard let skip = handlers.skip else { return .commandFailed }
            skip(Self.skipInterval)
            return .success
        }
        center.skipBackwardCommand.addTarget { _ in
            guard let skip = handlers.skip else { return .commandFailed }
            skip(-Self.skipInterval)
            return .success
        }

        // Like and dislike. The app has modelled both for versions — `toggleLike` and the
        // radio bans — and neither reached the lock screen or CarPlay, so the one gesture
        // worth making without looking at a screen could only be made by looking at one.
        center.likeCommand.localizedTitle = "Like"
        center.dislikeCommand.localizedTitle = "Never Play in Radio"
        center.likeCommand.addTarget { _ in
            guard let like = handlers.toggleLike else { return .commandFailed }
            like()
            return .success
        }
        center.dislikeCommand.addTarget { _ in
            guard let ban = handlers.ban else { return .commandFailed }
            ban()
            return .success
        }
        center.likeCommand.isEnabled = handlers.toggleLike != nil
        center.dislikeCommand.isEnabled = handlers.ban != nil

        // Commands we don't model — disable so the OS hides them from the widget.
        for command in [
            center.seekForwardCommand, center.seekBackwardCommand,
            center.changeRepeatModeCommand, center.changeShuffleModeCommand,
        ] { command.isEnabled = false }
    }

    /// Fifteen seconds each way — the interval every podcast client has trained people on.
    public static let skipInterval: TimeInterval = 15

    /// Pushes the current track + transport state to the OS Now Playing surfaces.
    /// The OS interpolates elapsed time from `playbackRate`, so this only needs to be
    /// called on state changes (play/pause/track/seek), not every tick.
    public func update(
        song: NavidromeSong?,
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        artworkURL: URL?,
        /// The engine's actual rate. Podcasts play at 0.5–2×, and the OS *interpolates*
        /// elapsed time from this between pushes — so publishing 1.0 for a 1.5× episode
        /// left the lock-screen clock drifting further behind the audio the longer you
        /// listened, then jumping back on the next real update.
        rate: Float = 1,
        /// Whether ±15s should be offered. True for podcasts, where it is the most-used
        /// control; false for songs, where next/previous already mean "move on".
        offersSkip: Bool = false,
        /// Reflected on the lock screen's heart, so it shows the current state rather than
        /// a button that always looks the same.
        isLiked: Bool = false
    ) {
        let center = MPNowPlayingInfoCenter.default()
        guard let song else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped  // playbackState exists only on macOS; iOS derives it from playbackRate
            #endif
            self.artworkURL = nil
            lastArtwork = nil
            artworkTask?.cancel()
            return
        }
        var info = Self.nowPlayingInfo(song: song, isPlaying: isPlaying,
                                       currentTime: currentTime, duration: duration, rate: rate)
        if let lastArtwork { info[MPMediaItemPropertyArtwork] = lastArtwork }
        center.nowPlayingInfo = info
        let center2 = MPRemoteCommandCenter.shared()
        center2.skipForwardCommand.isEnabled = offersSkip
        center2.skipBackwardCommand.isEnabled = offersSkip
        center2.likeCommand.isActive = isLiked
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
        loadArtworkIfNeeded(url: artworkURL)
    }

    /// Pure mapping of a track + transport state to the Now Playing info dictionary (artwork is
    /// merged in asynchronously by `loadArtworkIfNeeded`, so it isn't included here). Factored out
    /// of `update` so the key mapping — title/artist/album, duration only when known, a clamped
    /// elapsed time, and the play/pause rate the OS interpolates from — is testable without
    /// touching the OS `MPNowPlayingInfoCenter` (which is gated off under XCTest).
    public nonisolated static func nowPlayingInfo(
        song: NavidromeSong,
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        rate: Float = 1
    ) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist ?? ""
        if let album = song.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        // The engine's rate, not a constant. Zero while paused is what tells the OS to
        // stop advancing its own clock.
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        return info
    }

    /// Fetches the cover asynchronously and merges it into the live info dict when
    /// ready — merging (not replacing) so a slow artwork load can't clobber a newer
    /// elapsed-time/state update.
    private func loadArtworkIfNeeded(url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        artworkTask?.cancel()
        guard let url else { lastArtwork = nil; return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: data), !Task.isCancelled
            else { return }
            // Build the artwork off the main actor: MediaPlayer invokes the request
            // handler on its own background queue, so the closure must NOT inherit
            // `@MainActor` isolation (doing so trips a Swift executor assertion → crash).
            let artwork = Self.makeArtwork(from: image)
            guard let self, !Task.isCancelled, self.artworkURL == url else { return }
            self.lastArtwork = artwork
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Wraps an image as `MPMediaItemArtwork`. `nonisolated` so the request handler
    /// closure runs on MediaPlayer's queue without a main-actor executor check.
    private nonisolated static func makeArtwork(from image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
