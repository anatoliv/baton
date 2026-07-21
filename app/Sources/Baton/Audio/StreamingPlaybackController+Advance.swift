import Foundation

/// Queue-advance decision logic, extracted from the `StreamingPlaybackController` monolith as the
/// first step of the  decomposition. These are pure, side-effect-free functions of
/// (current index, count, repeat mode) — no player, queue, or actor state — so they're trivially
/// unit-testable (see `LoudnessAdvanceCharacterizationTests`, ) and safe to reason about in
/// isolation. They stay static members of the controller (declared here via an extension) so every
/// existing `Self.onTrackEnd(...)` call site is unchanged.
extension StreamingPlaybackController {
    /// What to do when a track ends, given the repeat mode (pure — unit-tested).
    enum Advance: Equatable { case replay, play(Int), stop }

    static func onTrackEnd(current: Int, count: Int, repeatMode: RepeatMode) -> Advance {
        guard count > 0 else { return .stop }
        switch repeatMode {
        case .one: return .replay
        case .all: return current + 1 < count ? .play(current + 1) : .play(0)
        case .off: return current + 1 < count ? .play(current + 1) : .stop
        }
    }

    /// What a manual Next press does — wraps for .all/.one, stops for .off.
    static func onManualNext(current: Int, count: Int, repeatMode: RepeatMode) -> Advance {
        guard count > 0 else { return .stop }
        if current + 1 < count { return .play(current + 1) }
        return repeatMode == .off ? .stop : .play(0)
    }
}
