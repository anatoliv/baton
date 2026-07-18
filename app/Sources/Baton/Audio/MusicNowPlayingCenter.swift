import AppKit
import Foundation
import MediaPlayer

/// Bridges the music player to macOS **Now Playing**: the Control Center / menu-bar
/// Now Playing widget, the hardware media keys (F7/F8/F9), and Bluetooth/AirPod
/// remotes. Publishes track metadata + artwork via `MPNowPlayingInfoCenter` and
/// routes remote commands (play/pause/next/previous/seek) back to the player through
/// injected closures. A thin sibling to `StreamingPlaybackController`, gated off
/// under XCTest so it never touches the test host's real Now Playing state.
@MainActor
final class MusicNowPlayingCenter {
    /// Transport hooks the remote commands invoke. Wired once by the owner (player).
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (TimeInterval) -> Void
    }

    private var configured = false
    /// The artwork URL currently loaded (so we only refetch when the cover changes).
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var lastArtwork: MPMediaItemArtwork?

    /// Registers remote-command targets. Idempotent — safe to call more than once.
    func configure(_ handlers: Handlers) {
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
        // Commands we don't model — disable so the OS hides them from the widget.
        for command in [
            center.seekForwardCommand, center.seekBackwardCommand,
            center.skipForwardCommand, center.skipBackwardCommand,
            center.changeRepeatModeCommand, center.changeShuffleModeCommand,
        ] { command.isEnabled = false }
    }

    /// Pushes the current track + transport state to the OS Now Playing surfaces.
    /// The OS interpolates elapsed time from `playbackRate`, so this only needs to be
    /// called on state changes (play/pause/track/seek), not every tick.
    func update(
        song: NavidromeSong?,
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        artworkURL: URL?
    ) {
        let center = MPNowPlayingInfoCenter.default()
        guard let song else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            self.artworkURL = nil
            lastArtwork = nil
            artworkTask?.cancel()
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist ?? ""
        if let album = song.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let lastArtwork { info[MPMediaItemPropertyArtwork] = lastArtwork }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        loadArtworkIfNeeded(url: artworkURL)
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
                  let image = NSImage(data: data), !Task.isCancelled
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
    private nonisolated static func makeArtwork(from image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
