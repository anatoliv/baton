import Foundation
import Observation
import BatonDSP

/// Publishes the audio tap's band levels to the UI, so the now-playing bars follow the
/// music instead of looping a canned animation.
///
/// The render thread writes into a `LevelSnapshot` (one lock-free atomic); this samples it
/// on a timer and republishes as observable state. Sampling rather than pushing is the point:
/// audio callbacks arrive ~43 times a second at 44.1 kHz and each one would invalidate every
/// view reading this. A meter refreshing faster than the eye resolves costs frames for
/// nothing, so it runs at `frameRate` and stops entirely when nothing is playing.
///
/// **It idles all the way off.** No subscribers, or paused, and the timer is invalidated —
/// not merely ignored. An indicator that quietly burns a wakeup every 40 ms whenever the app
/// is open is the kind of thing nobody notices until the battery graph does.
@MainActor
@Observable
public final class AudioLevelMonitor {
    /// The app's meter. There is one audio output, so there is one meter — and threading an
    /// instance through the environment would have meant four `.environment(…)` call sites
    /// per app that must all stay in step. This codebase has lost that bet often enough
    /// (nine Shuffle sites, twelve now-playing indicators) to not take it again. Tests build
    /// their own with `init(defaults:)`.
    public static let shared = AudioLevelMonitor()

    /// The most recent levels, 0…1 per band. `.silent` whenever nothing is being metered —
    /// views treat that as "no signal" and fall back to their own animation.
    public private(set) var levels: BandLevels = .silent

    /// True when the meter is actually producing a signal, so a view can choose between
    /// reactive bars and the canned ones without guessing from the values.
    public private(set) var isLive = false

    /// Where the audio tap publishes. Handed to `AudioEQProcessor`.
    public let snapshot = LevelSnapshot()

    /// 24 Hz: smooth to the eye, and a third of the callback rate. The bars are 15 points
    /// tall — there is nothing to gain from 60.
    public static let frameRate: Double = 24

    /// User setting. Off means the tap is never attached for metering (the EQ may still
    /// attach it for its own reasons) and the bars use their canned animation.
    public static let enabledKey = "tonebox.music.reactiveNowPlayingBars"

    private var timer: Timer?
    private var subscribers = 0
    private let defaults: UserDefaults

    /// Whether the sampling timer is live. Exposed so a test can assert the meter idles all
    /// the way off rather than merely publishing zeros while still waking the CPU.
    public var isRunning: Bool { timer != nil }

    /// Take one sample now, without waiting for the timer. For tests.
    public func sampleNow() { sample() }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.enabledKey) == nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { stop() }
        }
    }

    /// A view began displaying bars. Balanced by `release()`.
    ///
    /// This is also the play-state gate, and deliberately the only one: the bars are drawn
    /// *only* while something is actually playing, so a subscriber existing already means
    /// there is audio to meter. Tracking `isPlaying` separately here would be a second copy
    /// of that fact, free to drift from the first.
    public func retain() {
        subscribers += 1
        startIfNeeded()
    }

    public func release() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { stop() }
    }

    private func startIfNeeded() {
        guard timer == nil, isEnabled, subscribers > 0 else { return }
        let interval = 1.0 / Self.frameRate
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // `.common` so the bars keep moving while a menu or a scroll is tracking — the
        // default mode stalls timers exactly when the user is looking at a list.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        snapshot.clear()
        if levels != .silent { levels = .silent }
        if isLive { isLive = false }
    }

    /// Where the playhead is, for the envelope fallback: song id, position, and whether
    /// audio is actually advancing. Wired by the app's model.
    public var playheadProvider: (@MainActor () -> (id: String?, time: Double, playing: Bool))?

    private func sample() {
        var next = snapshot.load()
        // The tap only runs for file-based items — an HTTP-streamed item never invokes it
        // (platform behaviour, verified empirically). When the tap is silent but an offline
        // envelope of this track exists, read the levels at the playhead instead: the same
        // analyzer over the same bytes, just computed ahead of time.
        // `TrackLevelTimeline` is itself `#if !os(watchOS)` — offline analysis needs
        // AVFoundation's reader, which the watch does not get — but this call was not
        // guarded to match, so the watch app stopped compiling the day the fallback landed
        // and nobody noticed for as long as nothing built it. That is the same hole the
        // engine merge fell through on iOS: a gate that builds one of three apps says
        // nothing about the other two.
        #if !os(watchOS)
        if next.peak == 0, let playhead = playheadProvider?(), playhead.playing,
           let id = playhead.id,
           let fromEnvelope = TrackLevelTimeline.levels(id: id, at: playhead.time) {
            next = fromEnvelope
        }
        #endif
        // Only republish on a visible change: `@Observable` invalidates every reader on
        // assignment, and a still meter shouldn't redraw the list 24 times a second.
        if Self.differs(next, levels) { levels = next }
        let live = next.peak > 0
        if live != isLive { isLive = live }
    }

    /// One byte of headroom — below this the change can't move a 15-point bar by a pixel.
    static func differs(_ a: BandLevels, _ b: BandLevels) -> Bool {
        let threshold: Float = 1.0 / 255
        for i in 0 ..< 4 where abs(a[i] - b[i]) > threshold { return true }
        return false
    }
}
