import AVFoundation
import BatonDSP
import BatonSubsonicModels
#if os(macOS)
import CoreAudio
#endif

/// The thing that actually renders audio, behind the policy that decides what to render.
///
/// `StreamingPlaybackController` is two players wearing one coat: an `AVQueuePlayer` and —
/// when the experimental engine takes a library stream — the `AVAudioEngine` deck. Today it
/// chooses between them at 22 sites with the same shape:
///
/// ```swift
/// if engineOwnsPlayback, let deck = engineDeck {
///     deck.pause(); …policy…; return
/// }
/// …the AVPlayer version of pause, and the same policy again…
/// ```
///
/// Every one of those is a dispatch decision written by hand, and this codebase's record on
/// rules written by hand at many call sites is unambiguous: nine Shuffle sites, eleven layout
/// keys, twelve now-playing indicators, and — in this very routing decision — three
/// predicates that disagreed with each other, two of which shipped wrong. A seam is how that
/// class of bug stops being possible rather than being fixed again.
///
/// **What belongs here and what does not.** This is transport *mechanics*: make sound, stop
/// making sound, move the playhead, set a level. Everything about *what* to play stays on the
/// controller — the queue, repeat and shuffle, scrobbling, now-playing, persistence, the
/// advance policy at the end of a track. That split is what makes the seam small enough to be
/// worth having: the deck answers "render this", the controller answers "why".
///
/// **Two implementations exist today** and this names the contract they already share:
/// `EngineDeckBridge` on macOS/iOS, and the watchOS stand-in of the same name that cannot be
/// constructed (no `AudioToolbox`, so no decoder, so no engine). An `AVPlayerDeck` is the
/// third, and extracting it is what turns those 22 branches into one call.
@MainActor
public protocol PlaybackDeck: AnyObject {
    /// Position, duration and buffering, pushed at the deck's own cadence. The controller's
    /// clock, scrobble accounting and scrubber all read from this rather than polling.
    var onClock: (@MainActor (TimeInterval, TimeInterval, Bool) -> Void)? { get set }
    /// The track finished on its own. The *controller* decides what happens next — repeat,
    /// next, autoplay radio, stop — because that is policy and has never lived here.
    var onEnded: (@MainActor () -> Void)? { get set }
    /// The deck has given up on this track after its own bounded retries. Exactly once per
    /// load; the controller owns the skip.
    var onFailure: (@MainActor (String) -> Void)? { get set }

    func load(song: NavidromeSong, url: URL, startingAt offset: TimeInterval,
              autoplay: Bool, headers: [String: String], supportsTimeOffset: Bool)
    func pause()
    func resume()
    func seek(to seconds: TimeInterval)
    func stop()

    /// User volume, mute and the composed envelope (sleep fade × duck × transport fade) in
    /// one call, because sending them separately is how two of them end up disagreeing.
    func applyLevel(volumePercent: Int, isMuted: Bool, envelope: Float)
    func applyLoudness(mode: StreamingPlaybackController.LoudnessMode, preampDB: Double)
    func setPlaybackRate(_ rate: Float)
    func setStallTimeout(_ seconds: Double)
    func applyEQ(bands: [EQBand], enabled: Bool)

    func startMetering(into snapshot: LevelSnapshot)
    func stopMetering()

    /// Metering follows **ownership**, not attachment — the distinction that had the render
    /// tap analysing silence forty times a second for the life of the process, because
    /// `stopMetering` had one caller and production never ran it. The controller drives
    /// these from its ownership observer, which is why they are contract rather than an
    /// implementation detail two types happen to share.
    func suspendMetering()
    func resumeMetering()

    #if os(macOS)
    /// Per-app output routing, which only exists on macOS — iOS routes through
    /// `AVAudioSession` and has no per-app device concept at all.
    @discardableResult
    func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool
    var currentOutputDeviceID: AudioDeviceID? { get }
    #endif
}
