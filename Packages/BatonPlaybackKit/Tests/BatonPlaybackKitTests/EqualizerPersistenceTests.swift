import XCTest
@testable import BatonPlaybackKit

/// The equalizer curve moving onto `VersionedStore` (S-F14 / TBX-5354).
///
/// The curve is not derived from anything: bands are dragged one at a time and a lost one
/// cannot be recomputed. It lived as a bare `[EQBand]` blob under one `UserDefaults` key,
/// read with a `try?`, so a damaged blob read as "no bands" and the next slider move wrote
/// the default curve over it. These pin both halves of the fix.
@MainActor
final class EqualizerPersistenceTests: XCTestCase {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "io.tonebox.tests.eqstore.\(UUID().uuidString)")!
    }

    /// Exactly what the pre-`VersionedStore` `persistAndPublish()` wrote: a bare array under
    /// the same key, no envelope.
    ///
    ///     if let data = try? JSONEncoder().encode(bands) { d.set(data, forKey: Self.bandsKey) }
    private func writeLegacyBlob(_ bands: [EQBand], to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(bands), forKey: MusicEqualizer.bandsKey)
    }

    func testReadsABlobWrittenByTheOldCodeUnchanged() throws {
        let defaults = suite()
        // A curve nothing could re-derive: moved centre frequencies, hand-set Q, mixed gains.
        let legacy = [
            EQBand(frequency: 45, q: 0.8, gainDB: 5.5),
            EQBand(frequency: 320, q: 2.4, gainDB: -3.25),
            EQBand(frequency: 9_400, q: 1.1, gainDB: 2),
        ]
        try writeLegacyBlob(legacy, to: defaults)

        // Compared field by field: `EQBand.id` is a fresh UUID per decode and is not persisted,
        // so the whole struct is deliberately not what identity means here.
        let eq = MusicEqualizer(defaults: defaults)
        XCTAssertEqual(eq.bands.map(\.frequency), legacy.map(\.frequency),
                       "an upgrade must read the curve the old build wrote")
        XCTAssertEqual(eq.bands.map(\.q), legacy.map(\.q))
        XCTAssertEqual(eq.bands.map(\.gainDB), legacy.map(\.gainDB))

        // The first edit re-stamps it as an envelope and keeps everything it did not touch.
        eq.setGain(1.5, band: 1)
        let reopened = MusicEqualizer(defaults: defaults)
        XCTAssertEqual(reopened.bands.map(\.frequency), legacy.map(\.frequency))
        XCTAssertEqual(reopened.bands.map(\.q), legacy.map(\.q))
        XCTAssertEqual(reopened.bands[1].gainDB, 1.5)
        XCTAssertEqual(reopened.bands[0].gainDB, 5.5)
    }

    func testADamagedBlobIsQuarantinedRatherThanOverwritten() throws {
        let defaults = suite()
        let damaged = Data(#"[{"frequency":45,"q":0.8,"gain"#.utf8)
        defaults.set(damaged, forKey: MusicEqualizer.bandsKey)

        let eq = MusicEqualizer(defaults: defaults)
        XCTAssertEqual(eq.bands.count, MusicEqualizer.frequencies.count,
                       "unreadable bytes fall back to the default layout")
        eq.setGain(3, band: 0) // the write that used to destroy them

        let quarantined = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(MusicEqualizer.bandsKey).corrupt-") }
        XCTAssertEqual(quarantined.count, 1, "the damaged blob was not kept: \(quarantined)")
        XCTAssertEqual(defaults.data(forKey: try XCTUnwrap(quarantined.first)), damaged,
                       "the quarantined copy must be the original bytes, byte for byte")
    }

    /// The legacy gains key is still written, and that is load bearing: a device on an older
    /// build receives the synced envelope, cannot decode it, and reads the graphic gains
    /// instead of falling back to a flat curve.
    func testTheLegacyGainsKeyStaysInSyncForOlderBuilds() {
        let defaults = suite()
        let eq = MusicEqualizer(defaults: defaults)
        eq.setGain(-4.5, band: 2)
        let gains = defaults.array(forKey: MusicEqualizer.gainsKey) as? [Double]
        XCTAssertEqual(gains?.count, eq.bands.count)
        XCTAssertEqual(gains?[2], -4.5)
    }
}
