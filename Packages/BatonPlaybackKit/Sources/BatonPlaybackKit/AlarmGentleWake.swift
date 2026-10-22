import Foundation

/// Gentle wake: an alarm that starts quiet and rises
/// to full level. Owner, 2026-10-21: "for alarm add an option to raise the volume easy in first
/// 30 seconds".
///
/// One curve, used twice:
/// - **Baton's player** (the iPhone after Play or opening Baton, and the Mac's in-app alarm)
///   rises over `playerRampSeconds`, from `floorDB` to the person's own volume, never above it.
/// - **The sound the system rings** (AlarmKit on iOS 26 and later, a notification before that,
///   the Mac's notification) is a file, so the rise is baked into it, over `clipRampSeconds`
///   and then held at full level to the end of the file. AlarmKit plays a named sound again and
///   again until the alarm is answered, so a rise across the whole file would start quiet on
///   every pass and spend most of each pass quiet; the shorter rise leaves every pass at full
///   level for its last nine seconds. The spec's Sound section records the reasoning.
///
/// The rise is linear in decibels, which the ear hears as an even climb; a rise linear in
/// amplitude sounds as if it jumps at once and then stalls.
public enum GentleWake {
    /// Where the rise starts: -30 dB, about 3% amplitude. Quiet, not silent.
    public static let floorDB: Double = -30
    /// How long Baton's player takes to reach the person's volume.
    public static let playerRampSeconds: TimeInterval = 30
    /// How long the sound file takes to reach full level (see above).
    public static let clipRampSeconds: TimeInterval = 20
    /// How long the player's rise waits for the track to start (a stream buffering) before it
    /// gives up and leaves the volume alone.
    public static let waitForPlaybackSeconds: TimeInterval = 60

    /// The amplitude multiplier, 0...1, `elapsed` seconds into a rise of `ramp` seconds: the
    /// floor at the start, 1 from `ramp` on.
    public static func gain(elapsed: TimeInterval, ramp: TimeInterval) -> Double {
        guard ramp > 0, elapsed < ramp else { return 1 }
        let progress = max(0, elapsed) / ramp
        return pow(10, floorDB * (1 - progress) / 20)
    }

    /// The floor as an amplitude multiplier.
    public static var floorGain: Double { pow(10, floorDB / 20) }
}

/// The player's 30-second rise for a gentle alarm, driven by an injected clock so it is tested
/// without waiting.
///
/// It holds the player at the floor until the track is actually playing (a stream may take a few
/// seconds to buffer, and a rise spent in silence wakes nobody gently), then rises to 1 over
/// `duration` and finishes. `apply` receives the multiplier, which the player multiplies into the
/// person's own volume, so the result is never above it. A track that has not started after
/// `GentleWake.waitForPlaybackSeconds` finishes the rise at once.
@MainActor
public final class AlarmVolumeRamp {
    public enum Phase: Equatable, Sendable {
        case waiting(since: Date)
        case rising(from: Date)
        case finished
    }

    public private(set) var phase: Phase
    public let duration: TimeInterval
    private let now: () -> Date
    private let isPlaying: () -> Bool
    private let apply: (Float) -> Void

    /// Starts at the floor (applied at once) and waits for playback.
    public init(duration: TimeInterval = GentleWake.playerRampSeconds, now: @escaping () -> Date,
                isPlaying: @escaping () -> Bool, apply: @escaping (Float) -> Void) {
        self.duration = duration
        self.now = now
        self.isPlaying = isPlaying
        self.apply = apply
        phase = .waiting(since: now())
        apply(Float(GentleWake.floorGain))
    }

    public var isFinished: Bool { phase == .finished }

    /// Moves the rise to the clock's time and applies the multiplier. False once finished.
    @discardableResult
    public func step() -> Bool {
        let time = now()
        switch phase {
        case let .waiting(since):
            if isPlaying() {
                phase = .rising(from: time)
                apply(Float(GentleWake.gain(elapsed: 0, ramp: duration)))
            } else if time.timeIntervalSince(since) >= GentleWake.waitForPlaybackSeconds {
                finish()
            } else {
                apply(Float(GentleWake.floorGain))
            }
        case let .rising(from):
            let elapsed = time.timeIntervalSince(from)
            if elapsed >= duration { finish() } else { apply(Float(GentleWake.gain(elapsed: elapsed, ramp: duration))) }
        case .finished:
            return false
        }
        return phase != .finished
    }

    /// Ends the rise at full level (the person's volume).
    public func finish() {
        phase = .finished
        apply(1)
    }
}
