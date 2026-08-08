import Foundation

/// Four band levels, 0…1, ready to draw as bar heights.
public struct BandLevels: Sendable, Equatable {
    public var low: Float
    public var lowMid: Float
    public var highMid: Float
    public var high: Float

    public static let silent = BandLevels(low: 0, lowMid: 0, highMid: 0, high: 0)

    public init(low: Float, lowMid: Float, highMid: Float, high: Float) {
        self.low = low; self.lowMid = lowMid; self.highMid = highMid; self.high = high
    }

    public subscript(index: Int) -> Float {
        switch index {
        case 0: low
        case 1: lowMid
        case 2: highMid
        default: high
        }
    }

    public var peak: Float { max(max(low, lowMid), max(highMid, high)) }
}

/// Splits audio into four bands and reports each one's level — what makes the now-playing
/// bars follow the actual music instead of a canned loop.
///
/// It runs on the audio render thread, inside the same `MTAudioProcessingTap` the equalizer
/// uses, so the rules there are absolute: **no allocation, no locks, no Swift runtime calls
/// that might.** All state is fixed-size and preallocated; `analyze` only does arithmetic.
///
/// Design notes that matter for how it *looks*:
///
/// **Bands, not one amplitude.** Driving four bars from a single loudness value makes them
/// move as one, which reads as a VU meter wearing a costume. Splitting the spectrum is what
/// makes a bassline push the left bar while a hi-hat flicks the right one.
///
/// **Loudness is logarithmic.** RMS mapped linearly to height sits near the floor for most
/// music and then slams to full on a transient. The level is converted to dB and mapped
/// across a window (`floorDB`…`ceilingDB`), which is what makes quiet passages still show
/// visible movement.
///
/// **Ballistics.** Real meters rise fast and fall slow; a meter that tracks instantaneously
/// looks like noise. Attack and release are asymmetric, in per-buffer coefficients.
///
/// One-pole filters rather than an FFT, deliberately: an FFT on the render thread means a
/// window buffer, a plan, and a lot more arithmetic per callback for an indicator 15 points
/// tall. Four cheap filters are indistinguishable at this size.
public final class LevelAnalyzer: @unchecked Sendable {
    /// Crossovers (Hz). Chosen so each bar has something to do in ordinary music: bass and
    /// kick; the body of most instruments; presence and vocal consonants; cymbals and air.
    public static let crossovers: (Double, Double, Double) = (200, 1_000, 4_000)

    /// The dB window the bars span. −60 is "effectively silent" for lossy music; −6 rather
    /// than 0 because mastered tracks rarely sustain full scale, and a meter that never
    /// reaches the top looks broken.
    public static let floorDB: Float = -60
    public static let ceilingDB: Float = -6

    /// Per-buffer smoothing. A tap buffer is typically ~1024 frames (~23 ms at 44.1 kHz), so
    /// these are fractions per that period: rise in about two buffers, fall over about ten.
    /// Rise almost immediately; fall fast enough that a beat *ends*.
    ///
    /// Release was 0.12 — a ~190 ms tail that smeared consecutive kicks into one plateau,
    /// so the bars sat high and shimmered instead of pumping. 0.26 lets a bar fall most of
    /// the way between beats while still being markedly slower than the attack, which is
    /// what stops the meter reading as noise rather than as music.
    private static let attack: Float = 0.65
    private static let release: Float = 0.26

    /// One-pole state for the band splitters, per channel-sum (we analyze the mono sum:
    /// a stereo-dependent indicator would jitter with the mix, not the music).
    private var lowState: Float = 0
    private var lowMidState: Float = 0
    private var highMidState: Float = 0

    /// Smoothed, displayed levels.
    private var displayed = BandLevels.silent

    /// Per-band adaptive window — the floor and ceiling this band has actually visited
    /// recently. See `adapt`.
    private var envFloor: [Float] = [1, 1, 1, 1]
    private var envCeiling: [Float] = [0, 0, 0, 0]

    /// Filter coefficients, recomputed only when the sample rate changes.
    private var sampleRate: Double = 0
    private var k1: Float = 0, k2: Float = 0, k3: Float = 0

    public init() {}

    /// Recompute the one-pole coefficients for this rate. Cheap, and called from `prepare`,
    /// but guarded so a repeated `prepare` at the same rate costs nothing.
    public func prepare(sampleRate: Double) {
        let fs = sampleRate > 0 ? sampleRate : 44_100
        guard fs != self.sampleRate else { return }
        self.sampleRate = fs
        k1 = Self.onePoleCoefficient(cutoff: Self.crossovers.0, sampleRate: fs)
        k2 = Self.onePoleCoefficient(cutoff: Self.crossovers.1, sampleRate: fs)
        k3 = Self.onePoleCoefficient(cutoff: Self.crossovers.2, sampleRate: fs)
        reset()
    }

    public func reset() {
        lowState = 0; lowMidState = 0; highMidState = 0
        displayed = .silent
        envFloor = [1, 1, 1, 1]
        envCeiling = [0, 0, 0, 0]
    }

    /// How fast the adaptive window forgets. ~0.975 per ~21 ms buffer ≈ a 0.85-second
    /// memory — roughly two beats at ordinary tempos. Shorter memory means each beat
    /// re-normalises against its neighbours instead of against the whole phrase, which is
    /// the single biggest lever on how much the bars swing: at a 2-second memory the same
    /// audio moved about half as far.
    private static let windowDecay: Float = 0.975

    /// Below this span the passage genuinely *is* flat, and stretching it would be
    /// inventing movement out of noise — so the absolute reading is used unchanged.
    private static let minimumSpan: Float = 0.04

    /// Rescale a band against the range it has actually occupied recently.
    ///
    /// This is the difference between a meter that is *correct* and one that is *legible*.
    /// Measured in the running app, the four bands sat at 0.73/0.61/0.56/0.53 and varied by
    /// 0.03–0.06 — real audio, faithfully mapped, and visually motionless, because a 54 dB
    /// scale is mostly empty for mastered music: short-term RMS lives in a few dB near the
    /// top. Absolute correctness is the wrong target for a 15-point indicator; what a
    /// listener recognises as "following the music" is *relative* dynamics — this passage
    /// against the last couple of seconds of itself.
    ///
    /// So each band keeps its own recent floor and ceiling, which snap outward instantly to
    /// admit a new extreme and decay back slowly, and the current level is mapped between
    /// them. Loud tracks and quiet tracks both fill the box; what you see is the shape of
    /// the music rather than its mastering level. The `minimumSpan` guard is what keeps
    /// this honest: a sustained pad or near-silence has no dynamics to show, and gets none.
    private func adapt(_ value: Float, band: Int) -> Float {
        envCeiling[band] = max(value, envCeiling[band] * Self.windowDecay + value * (1 - Self.windowDecay))
        envFloor[band] = min(value, envFloor[band] * Self.windowDecay + value * (1 - Self.windowDecay))
        let span = envCeiling[band] - envFloor[band]
        guard span >= Self.minimumSpan else { return value }
        let scaled = (value - envFloor[band]) / span
        return min(max(scaled, 0), 1)
    }

    /// A one-pole low-pass coefficient for a cutoff, clamped to stay stable at any rate.
    static func onePoleCoefficient(cutoff: Double, sampleRate: Double) -> Float {
        let fs = sampleRate > 0 ? sampleRate : 44_100
        let f = min(max(cutoff, 1), fs * 0.45)
        let k = 1 - exp(-2 * Double.pi * f / fs)
        return Float(min(max(k, 0.0001), 1))
    }

    /// Feed one buffer of interleaved-by-channel-pointer audio and get the new display levels.
    ///
    /// `channelPointers` are the per-channel sample pointers; `frames` the count in each.
    /// Non-finite samples are skipped rather than allowed to poison the running state — a
    /// single NaN would otherwise stick the meter forever.
    public func analyze(
        channelPointers: UnsafePointer<UnsafeMutablePointer<Float>?>,
        channelCount: Int,
        frames: Int
    ) -> BandLevels {
        guard frames > 0, channelCount > 0, sampleRate > 0 else { return displayed }

        // Sum-of-squares per band, accumulated across the buffer.
        var sumLow: Float = 0, sumLowMid: Float = 0, sumHighMid: Float = 0, sumHigh: Float = 0
        var counted = 0
        let scale = 1 / Float(channelCount)

        for i in 0 ..< frames {
            // Mono sum first: one splitter chain instead of one per channel.
            var mono: Float = 0
            for c in 0 ..< channelCount {
                guard let p = channelPointers[c] else { continue }
                mono += p[i]
            }
            mono *= scale
            guard mono.isFinite else { continue }

            // Cascaded one-poles give four bands from three filters:
            //   low          = lp(200)
            //   lowMid       = lp(1k)  − lp(200)
            //   highMid      = lp(4k)  − lp(1k)
            //   high         = signal  − lp(4k)
            lowState += k1 * (mono - lowState)
            lowMidState += k2 * (mono - lowMidState)
            highMidState += k3 * (mono - highMidState)

            let low = lowState
            let lowMid = lowMidState - lowState
            let highMid = highMidState - lowMidState
            let high = mono - highMidState

            sumLow += low * low
            sumLowMid += lowMid * lowMid
            sumHighMid += highMid * highMid
            sumHigh += high * high
            counted += 1
        }

        guard counted > 0 else { return displayed }
        let n = Float(counted)
        // Absolute reading first (dB across the display window), then rescaled against
        // what this band has recently done — see `adapt` for why the absolute value alone
        // is correct and unreadable.
        let target = BandLevels(
            low: adapt(Self.normalize(rms: (sumLow / n).squareRoot()), band: 0),
            lowMid: adapt(Self.normalize(rms: (sumLowMid / n).squareRoot()), band: 1),
            highMid: adapt(Self.normalize(rms: (sumHighMid / n).squareRoot()), band: 2),
            high: adapt(Self.normalize(rms: (sumHigh / n).squareRoot()), band: 3)
        )

        displayed = BandLevels(
            low: Self.ballistic(displayed.low, target.low),
            lowMid: Self.ballistic(displayed.lowMid, target.lowMid),
            highMid: Self.ballistic(displayed.highMid, target.highMid),
            high: Self.ballistic(displayed.high, target.high)
        )
        return displayed
    }

    /// RMS → dB → 0…1 across the display window.
    static func normalize(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        guard db.isFinite else { return 0 }
        let t = (db - floorDB) / (ceilingDB - floorDB)
        return min(max(t, 0), 1)
    }

    /// Fast rise, slow fall.
    static func ballistic(_ current: Float, _ target: Float) -> Float {
        let k = target > current ? attack : release
        let next = current + k * (target - current)
        return next.isFinite ? min(max(next, 0), 1) : 0
    }
}
