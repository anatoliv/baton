import SwiftUI

/// The parametric-EQ panel: an enable toggle, a live response curve, a preset picker,
/// per-band frequency/Q/gain editors, and a flat/reset button. Reads and drives the
/// equalizer through `model.musicEqualizer`. Presentable as a sheet or a floating panel;
/// matches the app's dark, glassy now-playing surfaces.
struct MusicEqualizerView: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The band currently expanded for editing (nil = none).
    @State private var selectedBand: Int?

    private var eq: MusicEqualizer { model.musicEqualizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    responseCurve
                    presetRow
                    bandList
                }
                .padding(20)
                .opacity(eq.isEnabled ? 1 : 0.4)
                .allowsHitTesting(eq.isEnabled)
                .animation(.easeInOut(duration: 0.2), value: eq.isEnabled)
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 520, idealHeight: 620)
        .background(backgroundFill)
        .foregroundStyle(.white)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .foregroundStyle(eq.isEnabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Equalizer").font(.headline)
                Text(eq.preset == "Custom" ? "Custom" : eq.preset)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.accentColor)
                .help(eq.isEnabled ? "Disable equalizer" : "Enable equalizer")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { eq.isEnabled }, set: { eq.isEnabled = $0 })
    }

    // MARK: - Response curve

    private var responseCurve: some View {
        EQResponseCurve(bands: eq.bands, selected: selectedBand)
            .frame(height: 120)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - Presets

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PRESET").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    eq.reset()
                    selectedBand = nil
                } label: {
                    Label("Flat", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .help("Reset all bands to flat")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MusicEqualizer.presets, id: \.name) { preset in
                        presetChip(preset.name)
                    }
                }
            }
        }
    }

    private func presetChip(_ name: String) -> some View {
        let selected = eq.preset == name
        return Button {
            eq.apply(preset: name)
            selectedBand = nil
        } label: {
            Text(name)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.08))
                )
                .foregroundStyle(selected ? .white : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bands

    private var bandList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BANDS").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.45))
            VStack(spacing: 6) {
                ForEach(Array(eq.bands.enumerated()), id: \.element.id) { index, band in
                    EQBandRow(
                        band: band,
                        expanded: selectedBand == index,
                        onTap: { withAnimation(.easeInOut(duration: 0.18)) { selectedBand = selectedBand == index ? nil : index } },
                        onFrequency: { eq.setFrequency($0, band: index) },
                        onQ: { eq.setQ($0, band: index) },
                        onGain: { eq.setGain($0, band: index) }
                    )
                }
            }
        }
    }

    private var backgroundFill: some View {
        ZStack {
            Color.black.opacity(0.6)
            Rectangle().fill(.ultraThinMaterial).opacity(0.7)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Band row

/// A single band's row: a compact summary line, expanding to frequency / Q / gain sliders.
private struct EQBandRow: View {
    let band: EQBand
    let expanded: Bool
    let onTap: () -> Void
    let onFrequency: (Double) -> Void
    let onQ: (Double) -> Void
    let onGain: (Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack {
                    Text(frequencyLabel(band.frequency))
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .frame(width: 62, alignment: .leading)
                    // Inline gain bar for a quick read without expanding.
                    gainBar
                    Text(gainLabel(band.gainDB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 52, alignment: .trailing)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 10) {
                    EQParameterSlider(label: "Freq", value: band.frequency, range: log10(MusicEqualizer.minFrequency) ... log10(MusicEqualizer.maxFrequency), display: frequencyLabel(band.frequency), transform: { pow(10, $0) }, inverse: { log10($0) }, onChange: onFrequency)
                    EQParameterSlider(label: "Q", value: band.q, range: MusicEqualizer.minQ ... MusicEqualizer.maxQ, display: String(format: "%.2f", band.q), onChange: onQ)
                    EQParameterSlider(label: "Gain", value: band.gainDB, range: MusicEqualizer.minGain ... MusicEqualizer.maxGain, display: gainLabel(band.gainDB), onChange: onGain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(expanded ? 0.08 : 0.04))
        )
    }

    private var gainBar: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            let frac = band.gainDB / MusicEqualizer.maxGain // −1…1
            let w = abs(frac) * mid
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 3)
                Capsule()
                    .fill(band.gainDB >= 0 ? Color.accentColor : Color.orange)
                    .frame(width: max(0, w), height: 3)
                    .offset(x: frac >= 0 ? mid : mid - w)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
    }

    private func frequencyLabel(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1fk", hz / 1000).replacingOccurrences(of: ".0k", with: "k") : "\(Int(hz.rounded()))Hz"
    }

    private func gainLabel(_ dB: Double) -> String {
        String(format: "%+.1f dB", dB)
    }
}

/// A labelled thin slider for one band parameter. Supports an optional log transform
/// (used for frequency) so the knob position maps evenly across decades.
private struct EQParameterSlider: View {
    let label: String
    let value: Double
    /// The slider's operating range (in transformed space when a transform is supplied).
    let range: ClosedRange<Double>
    let display: String
    /// Maps slider position → real value (identity by default).
    var transform: (Double) -> Double = { $0 }
    /// Maps real value → slider position (identity by default).
    var inverse: (Double) -> Double = { $0 }
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 34, alignment: .leading)
            Slider(
                value: Binding(
                    get: { min(max(inverse(value), range.lowerBound), range.upperBound) },
                    set: { onChange(transform($0)) }
                ),
                in: range
            )
            .controlSize(.small)
            .tint(.accentColor)
            Text(display)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 58, alignment: .trailing)
        }
    }
}

// MARK: - Response curve

/// Draws the combined magnitude response of all bands as a smooth curve over a log-frequency
/// axis, plus a handle dot per band centre (highlighted when its row is selected).
private struct EQResponseCurve: View {
    let bands: [EQBand]
    let selected: Int?

    private let sampleRate = 44_100.0
    private let minF = 20.0
    private let maxF = 20_000.0
    private let maxDB = 12.0

    var body: some View {
        Canvas { ctx, size in
            drawGrid(&ctx, size: size)
            drawCurve(&ctx, size: size)
            drawHandles(&ctx, size: size)
        }
        .padding(.vertical, 8)
    }

    /// Combined response in dB at a given frequency (sum of per-band peaking magnitudes).
    private func responseDB(at f: Double) -> Double {
        var linear = 1.0
        for band in bands {
            let biquad = Biquad.peaking(frequency: band.frequency, sampleRate: sampleRate, q: band.q, gainDB: band.gainDB)
            linear *= biquad.magnitude(atFrequency: f, sampleRate: sampleRate)
        }
        return 20 * log10(max(linear, 1e-6))
    }

    private func x(for f: Double, width: CGFloat) -> CGFloat {
        let t = (log10(f) - log10(minF)) / (log10(maxF) - log10(minF))
        return CGFloat(t) * width
    }

    private func y(forDB db: Double, height: CGFloat) -> CGFloat {
        let t = (db + maxDB) / (2 * maxDB) // 0 (top, +12) … 1 (bottom, −12)
        return height * (1 - CGFloat(min(max(t, 0), 1)))
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        var mid = Path()
        mid.move(to: CGPoint(x: 0, y: y(forDB: 0, height: size.height)))
        mid.addLine(to: CGPoint(x: size.width, y: y(forDB: 0, height: size.height)))
        ctx.stroke(mid, with: .color(.white.opacity(0.12)), lineWidth: 1)
    }

    private func drawCurve(_ ctx: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let steps = 160
        for i in 0 ... steps {
            let t = Double(i) / Double(steps)
            let f = pow(10, log10(minF) + t * (log10(maxF) - log10(minF)))
            let px = CGFloat(t) * size.width
            let py = y(forDB: responseDB(at: f), height: size.height)
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) } else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)

        // Soft fill under the curve toward the 0 dB line.
        var fill = path
        fill.addLine(to: CGPoint(x: size.width, y: y(forDB: 0, height: size.height)))
        fill.addLine(to: CGPoint(x: 0, y: y(forDB: 0, height: size.height)))
        fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [.accentColor.opacity(0.28), .accentColor.opacity(0.02)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
        ))
    }

    private func drawHandles(_ ctx: inout GraphicsContext, size: CGSize) {
        for (i, band) in bands.enumerated() {
            let px = x(for: band.frequency, width: size.width)
            let py = y(forDB: band.gainDB, height: size.height)
            let isSel = selected == i
            let r: CGFloat = isSel ? 6 : 4
            let rect = CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(isSel ? .white : .accentColor))
            if isSel {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(.white.opacity(0.5)), lineWidth: 1)
            }
        }
    }
}
