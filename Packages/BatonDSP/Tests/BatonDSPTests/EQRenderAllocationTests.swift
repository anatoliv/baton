import XCTest
@testable import BatonDSP

/// The EQ coefficient refresh runs on the audio render thread.
///
/// `AudioEQProcessor.process(_:)` is the CoreAudio tap callback, and it calls
/// `EQCoefficients.refreshIfChanged` on every buffer. The call fast-returns when nothing
/// changed, but while an EQ slider is being dragged the generation bumps continuously, so
/// the real work runs on that thread for the whole drag. Any heap allocation there can block
/// on the malloc lock and glitch the audio, which is why `EQTapContext` preallocates its
/// channel pointers and why the destination buffer is an `UnsafeMutablePointer` the caller
/// owns. (S-F23)
final class EQRenderAllocationTests: XCTestCase {
    private let bandCount = 10

    private func specs(gainDB: Double) -> [EQCoefficients.BandSpec] {
        EQLimits.frequencies.map {
            EQCoefficients.BandSpec(frequency: $0, q: EQLimits.defaultQ, gainDB: gainDB)
        }
    }

    /// A slider drag, measured: ten generation bumps, each followed by the render thread's
    /// refresh, with the malloc hook counting every allocation the refresh makes.
    func testRefreshOnTheRenderPathAllocatesNothing() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger is not available here")

        let coefficients = EQCoefficients()
        let dest = UnsafeMutablePointer<Biquad>.allocate(capacity: bandCount)
        dest.initialize(repeating: .identity, count: bandCount)
        defer { dest.deinitialize(count: bandCount); dest.deallocate() }
        let capacity = bandCount

        // Warm up outside the measurement: the first trip through this code resolves lazy
        // globals and the logger's own one-time setup, neither of which is the render path.
        coefficients.setBands(specs(gainDB: 1), reference: [])
        _ = coefficients.refreshIfChanged(
            knownGeneration: .max, sampleRate: 48_000, into: dest, capacity: capacity
        )
        _ = AllocationCounter.measure {
            _ = coefficients.refreshIfChanged(
                knownGeneration: .max, sampleRate: 48_000, into: dest, capacity: capacity
            )
        }

        var total = 0
        for step in 0 ..< 10 {
            // The publish side runs on the main actor and may allocate; only the render-side
            // refresh is measured.
            coefficients.setBands(specs(gainDB: Double(step) - 5), reference: [])
            total += AllocationCounter.measure {
                _ = coefficients.refreshIfChanged(
                    knownGeneration: .max, sampleRate: 48_000, into: dest, capacity: capacity
                )
            }
        }

        XCTAssertEqual(
            total, 0,
            "the render-thread coefficient refresh allocated \(total) times across ten band changes"
        )
    }

    /// The same call with a filter that goes non-finite, so the NaN fallback branch is the one
    /// being measured rather than the happy path.
    func testTheNonFiniteFallbackAlsoAllocatesNothing() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger is not available here")

        let coefficients = EQCoefficients()
        let dest = UnsafeMutablePointer<Biquad>.allocate(capacity: 4)
        dest.initialize(repeating: .identity, count: 4)
        defer { dest.deinitialize(count: 4); dest.deallocate() }

        // A zero and a negative rate, a centre above Nyquist, and a zero Q: the inputs the
        // clamping and the finiteness guard exist for.
        let hostile = [
            EQCoefficients.BandSpec(frequency: 20_000, q: 1, gainDB: 6),
            EQCoefficients.BandSpec(frequency: 1_000, q: 0, gainDB: 6),
            EQCoefficients.BandSpec(frequency: .nan, q: .nan, gainDB: 6),
            EQCoefficients.BandSpec(frequency: 1_000, q: 1, gainDB: .infinity),
        ]
        coefficients.setBands(hostile, reference: [])
        _ = coefficients.refreshIfChanged(knownGeneration: .max, sampleRate: 8_000, into: dest, capacity: 4)
        _ = AllocationCounter.measure {
            _ = coefficients.refreshIfChanged(knownGeneration: .max, sampleRate: 8_000, into: dest, capacity: 4)
        }

        let measured = AllocationCounter.measure {
            _ = coefficients.refreshIfChanged(knownGeneration: .max, sampleRate: 8_000, into: dest, capacity: 4)
        }
        XCTAssertEqual(measured, 0, "the non-finite fallback allocated \(measured) times")

        for i in 0 ..< 4 {
            let c = dest[i]
            XCTAssertTrue(
                c.b0.isFinite && c.b1.isFinite && c.b2.isFinite && c.a1.isFinite && c.a2.isFinite,
                "band \(i) published a non-finite coefficient"
            )
        }
    }

    /// The refresh writes through the caller's buffer rather than handing back new storage,
    /// so the tap keeps the same allocation for the life of the stream.
    func testRefreshWritesInPlaceIntoTheCallersBuffer() {
        let coefficients = EQCoefficients()
        let dest = UnsafeMutablePointer<Biquad>.allocate(capacity: bandCount)
        dest.initialize(repeating: .identity, count: bandCount)
        defer { dest.deinitialize(count: bandCount); dest.deallocate() }

        coefficients.setBands(specs(gainDB: 6), reference: [])
        guard let first = coefficients.refreshIfChanged(
            knownGeneration: .max, sampleRate: 44_100, into: dest, capacity: bandCount
        ) else { return XCTFail("the first refresh reported no change") }
        XCTAssertEqual(first.count, bandCount)
        let boosted = dest[0]

        coefficients.setBands(specs(gainDB: -6), reference: [])
        guard let second = coefficients.refreshIfChanged(
            knownGeneration: first.generation, sampleRate: 44_100, into: dest, capacity: bandCount
        ) else { return XCTFail("the second refresh reported no change") }
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertNotEqual(dest[0].b0, boosted.b0, "the cut did not overwrite the boost in place")
    }
}
