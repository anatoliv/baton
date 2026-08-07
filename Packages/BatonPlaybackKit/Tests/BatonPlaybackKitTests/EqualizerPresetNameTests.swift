import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// What the equalizer calls the curve it is currently applying.
///
/// The name used to be *remembered* rather than derived: every hand-edit stamped
/// "Custom" and nothing ever took it back. So dragging all ten sliders to 0 produced an
/// exactly-flat curve still labelled "Custom" — and because "Custom" is not one of
/// `presets`, the phone's picker had no tag matching it and drew an empty row. The bug
/// reported was "the preset label is blank"; the cause was that the label was a memory
/// of what you did instead of a description of what you have.
@MainActor
final class EqualizerPresetNameTests: XCTestCase {
    private func makeEQ() -> MusicEqualizer {
        MusicEqualizer(defaults: UserDefaults(suiteName: "eq.tests.\(UUID().uuidString)")!)
    }

    // MARK: - The reported bug

    /// Flattening by hand is the same curve as Flat, so it must have the same name.
    func testDraggingEveryBandBackToZeroIsCalledFlat() {
        let eq = makeEQ()
        eq.apply(preset: "Rock")
        XCTAssertEqual(eq.preset, "Rock", "precondition")

        for band in eq.bands.indices { eq.setGain(0, band: band) }

        XCTAssertEqual(eq.preset, "Flat",
                       "a curve with every band at 0 dB is Flat, however it got there")
    }

    /// The state that rendered blank. It is legitimate — it just has to be nameable.
    func testAShapeNoPresetHasIsCalledCustom() {
        let eq = makeEQ()

        eq.setGain(6, band: 0)

        XCTAssertEqual(eq.preset, "Custom")
    }

    /// Reset is the button that says Flat on it.
    func testResetIsCalledFlat() {
        let eq = makeEQ()
        eq.setGain(-9, band: 3)

        eq.reset()

        XCTAssertEqual(eq.preset, "Flat")
    }

    /// Whatever the name is, the picker must have a row for it — a name outside the
    /// menu's tags is exactly what drew an empty row.
    func testEveryNameTheEqualizerCanReportIsSelectableSomewhere() {
        let eq = makeEQ()
        let selectable = Set(MusicEqualizer.presets.map(\.name) + ["Custom"])

        for preset in MusicEqualizer.presets {
            eq.apply(preset: preset.name)
            XCTAssertTrue(selectable.contains(eq.preset), "\(eq.preset) has no row")
        }
        eq.setGain(11, band: 5)
        XCTAssertTrue(selectable.contains(eq.preset), "\(eq.preset) has no row")
    }

    // MARK: - Matching

    /// Identity must not enter into it: `EQBand` synthesises Equatable over its `id`, a
    /// fresh UUID per instance, so plain `==` would never match a preset.
    func testACurveMatchesAPresetDespiteHavingDifferentBandIdentities() {
        let rock = MusicEqualizer.presets.first { $0.name == "Rock" }!
        let rebuilt = rock.bands.map {
            EQBand(frequency: $0.frequency, q: $0.q, gainDB: $0.gainDB)  // new ids
        }

        XCTAssertNotEqual(rebuilt, rock.bands, "precondition: identities differ, so == fails")
        XCTAssertEqual(MusicEqualizer.presetName(for: rebuilt), "Rock")
    }

    /// Values survive a slider and a JSON round-trip, so the comparison is by audible
    /// tolerance — but a genuinely different curve must still read as Custom.
    func testAnAudiblyDifferentCurveIsNotMatched() {
        var bands = MusicEqualizer.defaultBands()
        bands[4].gainDB = 3

        XCTAssertEqual(MusicEqualizer.presetName(for: bands), "Custom")
    }

    func testATrivialFloatingPointDifferenceStillMatches() {
        var bands = MusicEqualizer.defaultBands()
        bands[0].gainDB = 0.001

        XCTAssertEqual(MusicEqualizer.presetName(for: bands), "Flat",
                       "0.001 dB is not a sound anyone can hear, or intended")
    }
}
