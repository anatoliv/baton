import XCTest
@testable import BatonDSP

/// Checked against synthesized signals with known answers, not against recordings.
///
/// The point of testing an analyzer with generated audio is that every expectation is
/// arithmetic: a 120 BPM click train has 120 BPM in it by construction, an 8 kHz tone is
/// brighter than a 100 Hz tone by definition, and silence has no beat. A test that played a
/// real song could only assert what the analyzer already returned.
final class SonicProfileTests: XCTestCase {
    private let sampleRate: Double = 44_100

    private func tone(frequency: Float, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * sin(2 * .pi * frequency * Float(index) / Float(sampleRate))
        }
    }

    /// Short bursts at a fixed interval — the simplest thing with an unambiguous tempo.
    private func clickTrain(bpm: Float, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: count)
        let period = Int(Float(sampleRate) * 60 / bpm)
        let burst = Int(sampleRate * 0.02)          // 20 ms of tone per beat
        var start = 0
        while start < count {
            for offset in 0..<burst where start + offset < count {
                let phase = Float(offset) / Float(sampleRate)
                // Decaying 200 Hz burst: a kick-ish onset rather than a raw impulse.
                samples[start + offset] = 0.8 * sin(2 * .pi * 200 * phase) * exp(-40 * phase)
            }
            start += period
        }
        return samples
    }

    // MARK: - Energy

    func testLouderAudioReportsMoreEnergy() throws {
        let quiet = try XCTUnwrap(SonicAnalyzer.analyze(samples: tone(frequency: 440, seconds: 1, amplitude: 0.05), sampleRate: sampleRate))
        let loud = try XCTUnwrap(SonicAnalyzer.analyze(samples: tone(frequency: 440, seconds: 1, amplitude: 0.9), sampleRate: sampleRate))
        XCTAssertGreaterThan(loud.energy, quiet.energy)
        XCTAssertTrue((0...1).contains(loud.energy))
        XCTAssertTrue((0...1).contains(quiet.energy))
    }

    func testSilenceHasNoEnergyAndNoTempo() throws {
        let silence = [Float](repeating: 0, count: Int(sampleRate * 2))
        let profile = try XCTUnwrap(SonicAnalyzer.analyze(samples: silence, sampleRate: sampleRate))
        XCTAssertEqual(profile.energy, 0)
        XCTAssertEqual(profile.brightness, 0)
        XCTAssertNil(profile.tempo, "silence must not be given a tempo")
    }

    func testEmptyBufferIsNotAnalyzable() {
        XCTAssertNil(SonicAnalyzer.analyze(samples: [], sampleRate: sampleRate))
    }

    // MARK: - Brightness

    func testAHighToneIsBrighterThanALowTone() throws {
        let low = try XCTUnwrap(SonicAnalyzer.analyze(samples: tone(frequency: 100, seconds: 1), sampleRate: sampleRate))
        let high = try XCTUnwrap(SonicAnalyzer.analyze(samples: tone(frequency: 8_000, seconds: 1), sampleRate: sampleRate))
        XCTAssertLessThan(low.brightness, 0.35, "a 100 Hz tone should sit well below the 1 kHz split")
        XCTAssertGreaterThan(high.brightness, 0.8, "an 8 kHz tone is almost entirely above the split")
        XCTAssertGreaterThan(high.brightness, low.brightness)
    }

    func testBrightnessIsIndependentOfLevel() throws {
        // The same tone at two volumes must not change how bright it is — otherwise
        // "brighter" would just mean "louder" and the two numbers would be one number.
        let soft = try XCTUnwrap(SonicAnalyzer.analyze(samples: tone(frequency: 4_000, seconds: 1, amplitude: 0.05), sampleRate: sampleRate))
        let loud = try XCTUnwrap(SonicAnalyzer.analyze(samples: tone(frequency: 4_000, seconds: 1, amplitude: 0.9), sampleRate: sampleRate))
        XCTAssertEqual(soft.brightness, loud.brightness, accuracy: 0.02)
    }

    // MARK: - Tempo

    func testFindsTheTempoOfAClickTrain() throws {
        for bpm: Float in [90, 120, 140] {
            let profile = try XCTUnwrap(SonicAnalyzer.analyze(samples: clickTrain(bpm: bpm, seconds: 12), sampleRate: sampleRate))
            let found = try XCTUnwrap(profile.tempo, "no tempo found for a \(bpm) BPM click train")
            XCTAssertEqual(found, bpm, accuracy: bpm * 0.06, "estimated \(found) for a \(bpm) BPM train")
        }
    }

    func testASteadyToneHasNoTempo() throws {
        // A continuous tone has amplitude but no onsets, so there is no pulse to find. This
        // is the case that separates a real onset detector from one that reports the
        // strongest autocorrelation lag no matter what.
        let profile = try XCTUnwrap(SonicAnalyzer.analyze(samples: tone(frequency: 440, seconds: 10), sampleRate: sampleRate))
        XCTAssertNil(profile.tempo, "a steady tone has no beat, but a tempo was reported")
    }

    func testProfileSurvivesACodableRoundTrip() throws {
        // It is cached per track, so it has to persist — including a nil tempo, which is the
        // value most likely to be quietly turned into 0 by a lossy encoding.
        let original = SonicProfile(energy: 0.42, brightness: 0.61, tempo: nil)
        let decoded = try JSONDecoder().decode(SonicProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.tempo)
    }
}
