import Foundation

/// What a track actually *sounds* like, measured from its audio rather than read from a tag.
///
/// Every mix Baton can build today is assembled from metadata — genre, play counts, ratings,
/// when a track was added. That is enough to answer "more like this artist" and useless for
/// "something calmer", because nothing in a Subsonic tag says how fast or how bright a
/// recording is. This is the missing input: three numbers per track, derived from the
/// samples, that a mix can actually sort and filter on.
///
/// Deliberately three, and deliberately cheap. A full MIR feature set (chroma, MFCCs, key,
/// danceability) is a research project and a large dependency; energy, brightness and tempo
/// are the three that map onto how people actually ask for music — *calmer*, *brighter*,
/// *faster* — and all three fall out of arithmetic over the waveform.
public struct SonicProfile: Sendable, Equatable, Codable {
    /// Loudness, 0…1, from RMS mapped across a dB window. Not a volume control: this is how
    /// hot the recording itself is, which tracks how energetic it feels.
    public var energy: Float
    /// Spectral tilt, 0…1. Low means the weight sits in the bass; high means cymbals, air
    /// and presence. The single number closest to what people call "bright" or "warm".
    public var brightness: Float
    /// Estimated beats per minute, or nil when the audio has no periodic pulse to find
    /// (ambient, spoken word, silence). Nil is a real answer and must not be faked as 0 —
    /// a mix that sorts by tempo has to be able to leave those tracks out.
    public var tempo: Float?

    public init(energy: Float, brightness: Float, tempo: Float?) {
        self.energy = energy
        self.brightness = brightness
        self.tempo = tempo
    }
}

/// Derives a `SonicProfile` from raw mono samples.
///
/// Pure arithmetic over an array — no file I/O, no AVFoundation, no Accelerate. That keeps
/// this package dependency-free and, more usefully, makes every test deterministic: a
/// synthesized tone or click train has a known answer, so the analyzer can be checked
/// against arithmetic rather than against a recording someone has to listen to.
///
/// One-pole filters rather than an FFT, for the same reason `LevelAnalyzer` chose them: the
/// question here is "where does the energy sit", not "what is the spectrum", and a two-band
/// split answers it for a fraction of the arithmetic.
public enum SonicAnalyzer {
    /// The dB window energy is mapped across. Matches `LevelAnalyzer` so the two agree about
    /// what "loud" means.
    public static let floorDB: Float = -60
    public static let ceilingDB: Float = -6

    /// The tempo range searched, in BPM. Below 60 and a slow track's half-time is
    /// indistinguishable from its beat; above 180 the search starts locking onto hi-hats
    /// instead of the pulse.
    public static let tempoRange: ClosedRange<Float> = 60...180

    /// Analyze mono samples at `sampleRate`.
    ///
    /// Returns nil only for an empty buffer. Silence is analyzable and has a real answer:
    /// zero energy, zero brightness, no tempo.
    public static func analyze(samples: [Float], sampleRate: Double) -> SonicProfile? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        let rms = Self.rms(samples)
        return SonicProfile(
            energy: Self.normalizedEnergy(rms: rms),
            brightness: Self.brightness(samples: samples, sampleRate: sampleRate),
            tempo: Self.tempo(samples: samples, sampleRate: sampleRate)
        )
    }

    // MARK: - Energy

    static func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func normalizedEnergy(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
    }

    // MARK: - Brightness

    /// Fraction of total energy above the split, via a one-pole low-pass at 1 kHz.
    ///
    /// 1 kHz because it sits between "body" and "presence": below it lives the bass and the
    /// fundamentals of most instruments, above it the consonants, strings and cymbals that
    /// make a recording read as bright.
    static func brightness(samples: [Float], sampleRate: Double) -> Float {
        let cutoff: Float = 1_000
        // Standard one-pole coefficient for a given cutoff and rate.
        let dt = 1 / Float(sampleRate)
        let rc = 1 / (2 * .pi * cutoff)
        let alpha = dt / (rc + dt)

        var lowState: Float = 0
        var lowSum: Float = 0
        var highSum: Float = 0
        for sample in samples {
            lowState += alpha * (sample - lowState)
            let high = sample - lowState
            lowSum += lowState * lowState
            highSum += high * high
        }
        let total = lowSum + highSum
        guard total > 0 else { return 0 }
        return min(max(highSum / total, 0), 1)
    }

    // MARK: - Tempo

    /// Estimates BPM by autocorrelating an onset envelope.
    ///
    /// Three steps, each the cheapest thing that works. Frame the signal and take each
    /// frame's RMS, which is an amplitude envelope. Half-wave rectify its first difference,
    /// so only *rises* count — that turns a continuous envelope into a series of onsets, and
    /// it is the step that makes a click train and a kick drum look alike. Then autocorrelate
    /// the onsets and take the strongest lag in the tempo range: a periodic pulse correlates
    /// with itself one beat later.
    ///
    /// Returns nil when nothing in range stands out from the flat autocorrelation, which is
    /// what "this audio has no beat" looks like numerically.
    static func tempo(samples: [Float], sampleRate: Double) -> Float? {
        // ~11 ms hops: fine enough to place an onset within a few percent of a beat at 180
        // BPM, coarse enough that the envelope is short and the autocorrelation is cheap.
        let hop = max(Int(sampleRate / 90), 1)
        guard samples.count > hop * 8 else { return nil }

        var envelope: [Float] = []
        envelope.reserveCapacity(samples.count / hop)
        var index = 0
        while index + hop <= samples.count {
            var sum: Float = 0
            for offset in index..<(index + hop) { sum += samples[offset] * samples[offset] }
            envelope.append((sum / Float(hop)).squareRoot())
            index += hop
        }

        // Half-wave rectified difference: onsets only.
        var onsets: [Float] = []
        onsets.reserveCapacity(envelope.count)
        for position in 1..<envelope.count {
            onsets.append(max(envelope[position] - envelope[position - 1], 0))
        }
        guard onsets.count > 4 else { return nil }

        // Is there anything here that deserves to be called an onset?
        //
        // A continuous tone is not perfectly flat once framed: a frame rarely holds a whole
        // number of cycles, so its RMS ripples slightly, and after mean-removal that ripple
        // is the *only* signal left — it autocorrelates beautifully and yields a confident
        // tempo for audio that has no beat at all. (A 440 Hz tone reported 150 BPM.)
        //
        // The fix is to compare onset size against the envelope it came from, before
        // normalizing that comparison away. Real onsets are a large fraction of the level
        // they rise from; framing ripple is a rounding error.
        let envelopeMean = envelope.reduce(0, +) / Float(envelope.count)
        let onsetMean = onsets.reduce(0, +) / Float(onsets.count)
        guard envelopeMean > 0, onsetMean / envelopeMean > 0.05 else { return nil }

        // Mean-remove so a loud track doesn't simply correlate with its own loudness.
        let mean = onsets.reduce(0, +) / Float(onsets.count)
        let centered = onsets.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }

        let framesPerSecond = Float(sampleRate) / Float(hop)
        let minLag = max(Int((framesPerSecond * 60 / tempoRange.upperBound).rounded()), 1)
        let maxLag = min(Int((framesPerSecond * 60 / tempoRange.lowerBound).rounded()), centered.count - 1)
        guard minLag < maxLag else { return nil }

        var bestLag = 0
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            for position in 0..<(centered.count - lag) {
                sum += centered[position] * centered[position + lag]
            }
            let score = sum / energy
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        // A flat envelope autocorrelates to noise around zero; require the winning lag to
        // carry real weight before calling it a tempo.
        guard bestLag > 0, bestScore > 0.10 else { return nil }

        // Octave correction. A beat at 140 BPM also lines up with itself every *second*
        // beat, and that half-tempo lag often scores marginally higher because it sums over
        // fewer, better-aligned terms — 140 came back as 70. When half the winning lag is
        // still in range and nearly as strong, the faster reading is the beat and the slower
        // one is its shadow.
        // Searched in a ±1 frame window rather than at exactly `bestLag / 2`, because the
        // true period is rarely a whole number of frames. At 140 BPM it is 38.57 frames, so
        // neither 38 nor 39 aligns well while their sum, 77, very nearly does — which is
        // precisely why the half-tempo scored higher in the first place. Checking only the
        // exact half misses the real beat by a rounding error.
        let halfLag = bestLag / 2
        for candidate in [halfLag - 1, halfLag, halfLag + 1]
        where candidate >= minLag && candidate < centered.count {
            var sum: Float = 0
            for position in 0..<(centered.count - candidate) {
                sum += centered[position] * centered[position + candidate]
            }
            if sum / energy > bestScore * 0.7 {
                bestLag = candidate
                break
            }
        }
        return framesPerSecond * 60 / Float(bestLag)
    }
}
