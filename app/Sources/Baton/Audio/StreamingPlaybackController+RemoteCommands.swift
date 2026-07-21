import Foundation

/// Media-key / Now Playing remote-command handling, extracted from `StreamingPlaybackController`
/// (W-50). When an internet-radio station is on air the library player is suspended, so a play/next
/// key must drive the *radio* (via the `RadioRemote` closures `MusicModel` wires) rather than resume
/// the library player over the live stream. Pure routing over the public transport API — no private
/// state — so it's a clean extraction and directly unit-testable (see the remote-routing tests).
extension StreamingPlaybackController {
    /// Radio-awareness for the media keys / Now Playing remote commands: when an internet-radio
    /// station is on air the library player is suspended, so a play/next key must drive the RADIO
    /// — not resume the library player over the live stream (double audio). Wired by MusicModel,
    /// which knows both transports; nil (and thus a no-op) in tests / when radio isn't used. (W-29 / AUDIO-05)
    struct RadioRemote {
        let play: @MainActor () -> Void
        let pause: @MainActor () -> Void
        let toggle: @MainActor () -> Void
        let next: @MainActor () -> Void
        let previous: @MainActor () -> Void
    }
    // Note: `radioIsOnAir` / `radioRemote` are stored on the main type (extensions can't hold
    // stored properties); the routing logic lives here.

    private var radioOnAir: Bool { radioIsOnAir?() == true }

    // Remote/media-key handlers — factored out so the radio-vs-library routing is unit-testable.
    func handleRemotePlay() { radioOnAir ? radioRemote?.play() : resume() }
    func handleRemotePause() { radioOnAir ? radioRemote?.pause() : pause() }
    func handleRemoteToggle() { radioOnAir ? radioRemote?.toggle() : (isPlaying ? pause() : resume()) }
    func handleRemoteNext() { radioOnAir ? radioRemote?.next() : next() }
    func handleRemotePrevious() { radioOnAir ? radioRemote?.previous() : previous() }
    func handleRemoteSeek(to seconds: TimeInterval) { if !radioOnAir { seek(to: seconds) } } // meaningless on a live stream
}
