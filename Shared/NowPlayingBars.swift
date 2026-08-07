import SwiftUI

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
struct NowPlayingBars: View {
    /// True only while audio is actually advancing.
    var isPlaying: Bool
    /// Beside text the bars take the accent; over artwork they sit on a dark scrim and
    /// need to be white. Same indicator either way — the app was previously drawing a
    /// speaker glyph in one place and bars in another for the identical state.
    var tint: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false

    /// Deliberately uneven: four bars on the same clock read as a machine, not as music.
    /// The durations are mutually prime-ish so the pattern takes a long time to repeat.
    private static let bars: [(low: CGFloat, high: CGFloat, period: Double)] = [
        (4, 13, 0.52),
        (8, 15, 0.41),
        (5, 11, 0.63),
        (9, 14, 0.47),
    ]
    private static let width: CGFloat = 2.5
    private static let spacing: CGFloat = 2

    private var animating: Bool { isPlaying && !reduceMotion }

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.spacing) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { index, bar in
                Capsule()
                    .fill(tint)
                    .frame(width: Self.width, height: lifted ? bar.high : bar.low)
                    .animation(motion(for: bar.period), value: lifted)
            }
        }
        // A fixed box, so a row's layout doesn't shift as the bars move.
        .frame(width: Self.width * 4 + Self.spacing * 3, height: 15, alignment: .bottom)
        .onAppear { lifted = animating }
        .onChange(of: animating) { _, on in lifted = on }
        .accessibilityHidden(true)   // the row already says what's playing
    }

    private func motion(for period: Double) -> Animation? {
        animating
            ? .easeInOut(duration: period).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.2)   // settle, rather than snap, when it stops
    }
}
