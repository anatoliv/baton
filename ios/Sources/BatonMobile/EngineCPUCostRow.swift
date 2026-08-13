import BatonPlaybackKit
import SwiftUI

/// The iPhone's answer to `powermetrics`, which iOS does not have.
///
/// Stage 6 measured the Mac: the engine costs +1.6 energy impact across the app and the
/// audio daemon, against a whole-machine power difference too small to resolve. The phone is
/// where that matters most and where it cannot be measured the same way — there is no
/// per-app energy API, and a simulator figure is a fact about the Mac.
///
/// So this measures the mechanism instead: CPU time charged to this app, per second of audio
/// actually heard. The engine decodes in-process where the system player hands the work to
/// the OS, so if the cost is real it shows up here. It is not energy — it ignores the radio,
/// the display and hardware decode — but it supports the comparison the decision needs:
/// *how much more work does one path do than the other, on this device*.
///
/// Deliberately manual. An automatic sampler would average across pauses, track changes and
/// stalls, and the Mac runs already showed what happens when a measurement includes work
/// that isn't the subject. Start it, play, stop, read; do it again the other way.
struct EngineCPUCostRow: View {
    let model: MobileModel

    @State private var window: PlaybackCPUProbe.Window?
    @State private var result: PlaybackCPUProbe.Sample?
    @State private var startedWithEngine = false
    /// Audio heard since the window opened, accumulated rather than read as a difference.
    ///
    /// The playhead restarts at every track change, so `currentTime - startTime` would go
    /// negative and be clamped to zero — a window spanning two tracks would report a fraction
    /// of the audio it covered and therefore a wildly inflated cost. Summing the forward
    /// movements is the only reading that survives the queue advancing, which over a
    /// ten-minute measurement it certainly will.
    @State private var audioHeard: TimeInterval = 0
    @State private var lastPlayhead: TimeInterval = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if window == nil {
                Button("Start Measuring") { start() }
            } else {
                HStack {
                    Text("Measuring…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { stop() }
                }
                Text("Keep playing. Stop after the same stretch you used for the other setting.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if window != nil {
                Text(String(format: "%.0f s of audio so far", audioHeard))
                    .font(.footnote.monospaced()).foregroundStyle(.secondary)
            }

            if let result {
                Text(result.summary).font(.footnote.monospaced())
                Text(startedWithEngine ? "Engine on for that run." : "System player for that run.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onReceive(tick) { _ in accumulate() }
    }

    /// One second's worth of playhead movement, or nothing if it went backwards (a seek, or
    /// the next track starting). Both are movements this must not count as audio heard.
    private func accumulate() {
        guard window != nil else { return }
        let now = model.music.currentTime
        let advanced = now - lastPlayhead
        if advanced > 0, advanced < 5 { audioHeard += advanced }
        lastPlayhead = now
    }

    private func start() {
        startedWithEngine = model.music.engineOwnsPlayback
        result = nil
        audioHeard = 0
        lastPlayhead = model.music.currentTime
        window = PlaybackCPUProbe.Window(audioSecondsSoFar: 0)
    }

    private func stop() {
        accumulate()
        result = window?.sample(audioSecondsSoFar: audioHeard)
        window = nil
    }
}
