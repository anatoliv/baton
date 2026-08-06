import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// Media-key / Now Playing remote-command handling, extracted from `StreamingPlaybackController`
///. When an internet-radio station is on air the library player is suspended, so a play/next
/// key must drive the *radio* (via the `RadioRemote` closures `MusicModel` wires) rather than resume
/// the library player over the live stream. Pure routing over the public transport API — no private
/// state — so it's a clean extraction and directly unit-testable (see the remote-routing tests).
extension StreamingPlaybackController {
    /// Radio-awareness for the media keys / Now Playing remote commands: when an internet-radio
    /// station is on air the library player is suspended, so a play/next key must drive the RADIO
    /// — not resume the library player over the live stream (double audio). Wired by MusicModel,
    /// which knows both transports; nil (and thus a no-op) in tests / when radio isn't used.
    public struct RadioRemote {
        public let play: @MainActor () -> Void
        public let pause: @MainActor () -> Void
        public let toggle: @MainActor () -> Void
        public let next: @MainActor () -> Void
        public let previous: @MainActor () -> Void

        public init(
            play: @escaping @MainActor () -> Void,
            pause: @escaping @MainActor () -> Void,
            toggle: @escaping @MainActor () -> Void,
            next: @escaping @MainActor () -> Void,
            previous: @escaping @MainActor () -> Void
        ) {
            self.play = play
            self.pause = pause
            self.toggle = toggle
            self.next = next
            self.previous = previous
        }
    }
    // Note: `radioIsOnAir` / `radioRemote` are stored on the main type (extensions can't hold
    // stored properties); the routing logic lives here.

    private var radioOnAir: Bool { radioIsOnAir?() == true }

    // Remote/media-key handlers — factored out so the radio-vs-library routing is unit-testable.
    public func handleRemotePlay() { radioOnAir ? radioRemote?.play() : resume() }
    public func handleRemotePause() { radioOnAir ? radioRemote?.pause() : pause() }
    public func handleRemoteToggle() { radioOnAir ? radioRemote?.toggle() : (isPlaying ? pause() : resume()) }
    public func handleRemoteNext() { radioOnAir ? radioRemote?.next() : next() }
    public func handleRemotePrevious() { radioOnAir ? radioRemote?.previous() : previous() }
    public func handleRemoteSeek(to seconds: TimeInterval) { if !radioOnAir { seek(to: seconds) } } // meaningless on a live stream
}
