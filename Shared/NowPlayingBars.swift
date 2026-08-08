import SwiftUI
import BatonPlaybackKit

/// The bouncing bars that mark the track you're actually listening to.
///
/// Shared by both apps. It began as an iOS-only view, which is how the Mac ended up
/// showing a *waveform* on its cards and a *speaker* in its rows for the same state —
/// and how the phone's queue kept a speaker while its search results had bars. One
/// indicator, one file.
///
/// Replaces a static `waveform` symbol. That symbol told you *which* row was current but
/// looked identical whether the music was running or stopped — and the one thing you glance
/// at a list to check is whether it's playing.
///
/// Three things this has to get right, all of which a symbol got for free:
///
/// **It must stop.** A `repeatForever` animation runs until its view goes away. Only the
/// currently-playing row draws this, so there is exactly one instance no matter how large
/// the library, and it is removed the moment playback stops or another track starts.
///
/// **It must respect Reduce Motion.** `.symbolEffect` honours that setting on its own;
/// hand-rolled animation does not, so it's checked here. With motion reduced the bars are
/// drawn at their resting heights — still a clear marker, just not a moving one.
///
/// **Paused is not playing.** Held still when paused, so the row still says "this is where
/// you are" without claiming to be running.
///
/// **It follows the actual audio when it can.** `AudioLevelMonitor` supplies four band levels read off the playback tap, so the bars move with the bassline
/// and the hi-hats rather than on a fixed loop. That signal isn't always there — internet
/// radio doesn't route through the tap, the user can switch it off, and there's a moment at
/// the start of a track before the first buffer lands — so the canned animation stays as the
/// fallback rather than being replaced. The two look alike on purpose; the difference is
/// that one of them is telling the truth.
struct NowPlayingBars: View {
    /// True only while audio is actually advancing.
    var isPlaying: Bool
    /// Beside text the bars take the accent; over artwork they sit on a dark scrim and
    /// need to be white. Same indicator either way — the app was previously drawing a
    /// speaker glyph in one place and bars in another for the identical state.
    var tint: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false

    /// The app-wide meter (see `AudioLevelMonitor.shared` for why it isn't threaded through
    /// the environment).
    private var monitor: AudioLevelMonitor { .shared }

    /// Deliberately uneven: four bars on the same clock read as a machine, not as music.
    /// The durations are mutually prime-ish so the pattern takes a long time to repeat.
    /// `low`/`high` are the canned animation's rest and peak; `high` doubles as the
    /// reactive ceiling. The ceilings were 13/15/11/14 — bar 3 could never exceed 11 of
    /// the 15 available points, so its band was visibly quieter than it was. Raised toward
    /// the box while staying uneven, because a level top edge reads as a machine.
    private static let bars: [(low: CGFloat, high: CGFloat, period: Double)] = [
        (4, 14.5, 0.52),
        (8, 15, 0.41),
        (5, 13.5, 0.63),
        (9, 14, 0.47),
    ]
    private static let width: CGFloat = 2.5
    private static let spacing: CGFloat = 2

    private var animating: Bool { isPlaying && !reduceMotion }

    /// Real levels are used only while actually playing and with motion allowed — Reduce
    /// Motion must stop the bars whether the movement is canned or genuine.
    private var reactive: Bool { animating && monitor.isLive }

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.spacing) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { index, bar in
                Capsule()
                    .fill(tint)
                    .frame(width: Self.width, height: height(index: index, bar: bar))
                    // The reactive path animates on the *level*, so each new sample eases
                    // into place instead of stepping; the canned path animates on `lifted`.
                    .animation(reactive ? .linear(duration: 1 / AudioLevelMonitor.frameRate) : motion(for: bar.period),
                               value: reactive ? levelHeight(index: index, bar: bar) : (lifted ? bar.high : bar.low))
            }
        }
        // A fixed box, so a row's layout doesn't shift as the bars move.
        .frame(width: Self.width * 4 + Self.spacing * 3, height: 15, alignment: .bottom)
        .onAppear {
            lifted = animating
            if animating { monitor.retain() }
        }
        .onDisappear { if animating { monitor.release() } }
        .onChange(of: animating) { was, on in
            lifted = on
            // Balanced retain/release: the monitor's timer only runs while bars are on
            // screen *and* something is playing.
            if on { monitor.retain() } else if was { monitor.release() }
        }
        .accessibilityHidden(true)   // the row already says what's playing
    }

    private func height(index: Int, bar: (low: CGFloat, high: CGFloat, period: Double)) -> CGFloat {
        reactive ? levelHeight(index: index, bar: bar) : (lifted ? bar.high : bar.low)
    }

    /// How far a reactive bar may fall. The canned pattern's rest heights (4…9 pt) are
    /// tuned to look plausible while *idling*; borrowing them as the reactive floor cost
    /// the bars most of their travel — the busiest bar moved 5 pt inside a 15 pt box, so
    /// real music read as a tremble rather than as motion. A bar that can't get small
    /// can't show a drop-out either.
    private static let reactiveFloor: CGFloat = 1

    /// Shape the response.
    ///
    /// This was 0.65 — lifting mid levels toward the top — back when the analyzer handed
    /// over a nearly-constant number and the curve was trying to rescue it. The analyzer's
    /// adaptive window now delivers the full 0…1 itself, and against that a lifting curve
    /// works *against* motion: it crushes the bottom of the travel where the swing is most
    /// visible. Above 1.0 it does the opposite — peaks stay tall, mid levels sit lower, and
    /// the gap between a beat and the space after it widens.
    private static let contrast: CGFloat = 1.35

    /// Map a band level onto this bar's travel. The *ceiling* stays per-bar so the reactive
    /// silhouette keeps the uneven top edge the canned one has — four bars sharing one
    /// height reads as a machine — while the floor is shared and low, which is where the
    /// movement comes from.
    private func levelHeight(index: Int, bar: (low: CGFloat, high: CGFloat, period: Double)) -> CGFloat {
        let level = min(max(CGFloat(monitor.levels[index]), 0), 1)
        let expanded = pow(level, Self.contrast)
        return Self.reactiveFloor + (bar.high - Self.reactiveFloor) * expanded
    }

    private func motion(for period: Double) -> Animation? {
        animating
            ? .easeInOut(duration: period).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.2)   // settle, rather than snap, when it stops
    }
}

