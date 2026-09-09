import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The listen archive against real files rather than values built in the test (S-F14 / TBX-5354).
///
/// The card asked for `ListenArchiveIO` to move onto `VersionedStore` last, because the archive
/// is the thing a person would most notice losing. `ListenArchiveIO` turns out to write no file
/// at all: it is the pure encode/decode pair behind the History screen's export and import, and
/// its format is deliberately the ListenBrainz wire shape so a file Baton writes can be handed
/// to ListenBrainz and back. An envelope around that would break the one property it exists for.
///
/// The archive itself is `MusicPlayHistory`'s `play-history.jsonl`, which is append-only for
/// O(1) writes and already keeps undecodable lines aside (F11) rather than dropping them. So
/// what is owed here is not a migration but the evidence: that both formats are still read from
/// real files, and that a damaged archive loses nothing.
///
/// Both fixtures are files, not literals. `play-history-legacy.jsonl` was written by the
/// shipping writer into a temporary directory and checked in; `listenbrainz-export.json` carries
/// the fields a genuine ListenBrainz export carries (`inserted_at`, `recording_msid`,
/// `mbid_mapping`, `additional_info`), which a hand-built fixture of our own three fields would
/// never have tested tolerance of.
@MainActor
final class ListenArchiveFixtureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
                                "fixture \(name) is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    private func history() -> MusicPlayHistory {
        MusicPlayHistory(defaults: UserDefaults(suiteName: "archive-\(UUID().uuidString)")!,
                         directory: dir)
    }

    /// Plant the checked-in archive as this history's own file, which is what an upgrade meets.
    private func plantLegacyArchive() throws {
        try fixture("play-history-legacy.jsonl")
            .write(to: dir.appendingPathComponent("play-history.jsonl"))
    }

    // MARK: - The archive on disk

    func testAnArchiveWrittenByTheShippingWriterIsReadBackWhole() throws {
        try plantLegacyArchive()

        let loaded = history()
        XCTAssertEqual(loaded.entries.count, 320, "the archive lost entries on load")
        XCTAssertEqual(loaded.entries.first?.song.title, "Windowlicker",
                       "newest first is the order every screen reads")
        XCTAssertEqual(loaded.entries.last?.song.title, "Ricochet")
        XCTAssertEqual(loaded.entries.last?.playedAt, Date(timeIntervalSince1970: 1_690_000_000))
        // A title outside ASCII and an entry with no album both have to survive the round trip.
        XCTAssertTrue(loaded.entries.contains { $0.song.title == "夜のストレンジャー" })
        XCTAssertTrue(loaded.entries.contains { $0.song.album == nil })

        // The write that follows an upgrade keeps every one of them.
        let song = NavidromeSong(id: "new-1", title: "Autobahn", artist: "Kraftwerk", album: "Autobahn",
                                 albumID: nil, duration: 1_345, coverArtID: nil)
        loaded.record(song, playedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let reopened = history()
        XCTAssertEqual(reopened.entries.count, 321)
        XCTAssertEqual(reopened.entries.first?.song.title, "Autobahn")
        XCTAssertEqual(reopened.entries.dropFirst().map(\.id), loaded.entries.dropFirst().map(\.id),
                       "every previously archived listen must be identical after the write")
    }

    /// The failure the archive is protected against: a line torn in half by a crash or a full
    /// disk. The good listens still load, and the damaged bytes are kept rather than erased by
    /// the next rewrite.
    func testATornLineIsKeptAsideAndTheRestOfTheArchiveSurvives() throws {
        var bytes = try fixture("play-history-legacy.jsonl")
        let torn = Data(#"{"song":{"id":"9c0d1e","title":"Torn mid-wri"#.utf8)
        bytes.append(torn)
        bytes.append(0x0A)
        let archive = dir.appendingPathComponent("play-history.jsonl")
        try bytes.write(to: archive)

        let loaded = history()
        XCTAssertEqual(loaded.entries.count, 320, "a torn line must not cost a readable listen")

        // A rewrite is what used to erase the skipped line for good.
        loaded.ingest(ListenArchiveIO.parse(try fixture("listenbrainz-export.json")))
        let kept = try Data(contentsOf: archive.appendingPathExtension("corrupt"))
        XCTAssertTrue(kept.contains(torn), "the torn bytes were not preserved")
    }

    // MARK: - The portable format, from a real export

    func testARealListenBrainzExportImportsAndSurvivesAReopen() throws {
        let listens = ListenArchiveIO.parse(try fixture("listenbrainz-export.json"))
        XCTAssertEqual(listens.count, 4,
                       "the fields a real export carries beyond ours must be ignored, not fatal")
        XCTAssertFalse(listens.contains { $0.artist.trimmingCharacters(in: .whitespaces).isEmpty },
                       "a listen with no artist cannot be archived under a blank name")
        XCTAssertEqual(listens.first?.track, "Ricochet, Pt. 1")
        XCTAssertEqual(listens.first?.album, "Ricochet")
        XCTAssertNil(listens.first { $0.track == "E2-E4" }?.album, "a listen may have no release")

        let archive = history()
        XCTAssertEqual(archive.ingest(listens), 4)
        let reopened = history()
        XCTAssertEqual(reopened.entries.count, 4, "an imported archive did not survive a reopen")
        XCTAssertEqual(reopened.entries.map(\.song.title).sorted(),
                       archive.entries.map(\.song.title).sorted())
        XCTAssertEqual(reopened.entries.last?.playedAt,
                       Date(timeIntervalSince1970: 1_690_000_000))

        // Re-importing the same export must add nothing, or every import doubles the archive.
        XCTAssertEqual(reopened.ingest(listens), 0)
    }

    /// What Baton exports has to be what ListenBrainz reads, so the round trip is asserted
    /// against the archive rather than against a list built for the occasion.
    func testTheArchiveExportsAsSomethingItCanReadBack() throws {
        try plantLegacyArchive()
        let loaded = history()

        let exported = ListenArchiveIO.exportJSON(loaded.portableListens)
        let parsed = ListenArchiveIO.parse(exported)
        XCTAssertEqual(parsed.count, loaded.entries.count)
        XCTAssertEqual(parsed.first?.track, loaded.entries.first?.song.title)
        XCTAssertEqual(parsed.first?.listened_at,
                       Int(try XCTUnwrap(loaded.entries.first?.playedAt).timeIntervalSince1970))

        let csv = ListenArchiveIO.exportCSV(loaded.portableListens)
        XCTAssertEqual(csv.split(whereSeparator: \.isNewline).count, loaded.entries.count + 1,
                       "one header plus one row per listen")
        XCTAssertTrue(csv.contains("\"Oxygène, Pt. 4\""),
                      "a title containing a comma must be quoted or the columns shift")
    }
}
