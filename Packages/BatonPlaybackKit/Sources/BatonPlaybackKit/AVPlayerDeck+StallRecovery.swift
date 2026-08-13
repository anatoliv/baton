import AVFoundation
import Foundation
import OSLog

private let stallLog = Logger(subsystem: "io.tonebox.baton", category: "StallRecovery")

/// Stalled-stream auto-recovery for the `AVPlayerDeck`. A cellular hiccup can park
/// `AVPlayer` at rate-0 with
/// a full buffer — playback silently stuck while the UI says "playing" (observed in
/// the field as tens of seconds of silence with over a minute buffered). The design is
/// adapted (with thanks) from Vibrdrome's MIT-licensed recovery state machine; the
/// decision core here is a pure struct so the grace/attempt/anti-thrash rules are
/// unit-tested without a player.
///
/// Re-issue play ONLY when: the app still intends to play (a user pause clears that),
/// the player is genuinely parked, and the buffer has recovered. Bounded attempts, a
/// cool-down between them, and a kill switch.
public struct StallRecoveryPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        /// Nothing to do (healthy, disarmed, or still inside a grace/cool-down window).
        case none
        /// Re-issue playback now.
        case retryPlay
        /// Attempts exhausted — stop trying until the next track.
        case giveUp
    }

    /// Seconds a not-playing state must persist (with intent to play) before the
    /// first retry — short waits routinely resolve on their own.
    public var graceSeconds: TimeInterval = 7
    /// Minimum seconds between retries, so a dying network isn't hammered.
    public var cooldownSeconds: TimeInterval = 10
    public var maxAttempts: Int = 3

    public private(set) var armedAt: TimeInterval?
    public private(set) var lastAttemptAt: TimeInterval?
    public private(set) var attempts = 0

    public init() {}

    /// Called when playback genuinely runs — clears all recovery state.
    public mutating func notePlaying() {
        let recoveredAfter = attempts
        if recoveredAfter > 0 { stallLog.info("recovered after \(recoveredAfter) attempt(s)") }
        armedAt = nil
        lastAttemptAt = nil
        attempts = 0
    }

    /// Called on track change — a fresh item starts with a clean slate.
    public mutating func reset() {
        armedAt = nil
        lastAttemptAt = nil
        attempts = 0
    }

    /// The periodic tick. `intendsToPlay` is the app-level state (false after a user
    /// pause); `isParked` means the player is not progressing; `bufferRecovered`
    /// means data is available to play.
    public mutating func evaluate(
        now: TimeInterval,
        intendsToPlay: Bool,
        isParked: Bool,
        bufferRecovered: Bool
    ) -> Action {
        guard intendsToPlay, isParked else {
            armedAt = nil
            return .none
        }
        guard attempts < maxAttempts else { return .giveUp }
        guard let armed = armedAt else {
            armedAt = now
            return .none
        }
        guard now - armed >= graceSeconds, bufferRecovered else { return .none }
        if let last = lastAttemptAt, now - last < cooldownSeconds { return .none }
        attempts += 1
        lastAttemptAt = now
        return .retryPlay
    }
}

extension StreamingPlaybackController {
    /// Kill switch for the auto-recovery (UserDefaults, default on). It stays on the
    /// controller because it is a user setting, not a property of the renderer.
    public static let stallRecoveryEnabledKey = "baton.music.stallRecovery.enabled"
}

extension AVPlayerDeck {
    /// The periodic-clock hook: detect a parked player with a recovered buffer and
    /// nudge it back into motion within the policy's bounds.
    func stallRecoveryTick() {
        let key = StreamingPlaybackController.stallRecoveryEnabledKey
        guard UserDefaults.standard.object(forKey: key) as? Bool ?? true else { return }
        let status = player.timeControlStatus
        if status == .playing {
            stallPolicy.notePlaying()
            return
        }
        let parked = status == .paused || status == .waitingToPlayAtSpecifiedRate
        let buffered = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
        let action = stallPolicy.evaluate(
            now: Date().timeIntervalSinceReferenceDate,
            intendsToPlay: hostIntendsToPlay?() == true,
            isParked: parked,
            bufferRecovered: buffered
        )
        switch action {
        case .retryPlay:
            stallLog.warning("player parked with recovered buffer — re-issuing play (attempt \(self.stallPolicy.attempts))")
            player.rate = player.defaultRate == 0 ? 1 : player.defaultRate
        case .giveUp, .none:
            break
        }
    }
}
