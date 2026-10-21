import BatonSubsonicKit
import XCTest
@testable import BatonMobile

/// The app→widget contract. The widget extension is a separate process that
/// decodes this JSON with its own copy of the shape, so a field rename here is a
/// silently blank widget — the round trip is the only thing holding the two
/// halves together.
final class WidgetBridgeTests: XCTestCase {
    func testSnapshotSurvivesTheAppGroupRoundTrip() throws {
        let snapshot = WidgetBridge.Snapshot(
            title: "Dido (Original Mix)",
            artist: "90s Kid",
            songID: "xRPbje8L2uoNt7tuR5putZ",
            isPlaying: true,
            artworkURL: URL(string: "https://music.example.com/rest/getCoverArt.view?id=abc"),
            updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetBridge.Snapshot.self, from: data)

        XCTAssertEqual(decoded.title, snapshot.title)
        XCTAssertEqual(decoded.artist, snapshot.artist)
        XCTAssertEqual(decoded.songID, snapshot.songID)
        XCTAssertEqual(decoded.isPlaying, snapshot.isPlaying)
        XCTAssertEqual(decoded.artworkURL, snapshot.artworkURL)
    }

    /// The widget's own decoder is keyed by these exact names — assert them
    /// literally, because renaming a property is the failure this catches.
    func testWireKeysAreTheOnesTheWidgetDecodes() throws {
        let snapshot = WidgetBridge.Snapshot(
            title: "t", artist: nil, songID: "s", isPlaying: false,
            artworkURL: nil, updatedAt: Date()
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(snapshot)
        ) as? [String: Any]
        let keys = Set(json?.keys.map { $0 } ?? [])
        XCTAssertTrue(keys.isSuperset(of: ["title", "songID", "isPlaying", "updatedAt"]),
                      "widget-facing keys changed: \(keys.sorted())")
    }

    /// A track with no artist is ordinary (podcasts, unnamed rips) — it must not
    /// break encoding.
    func testMissingOptionalsEncode() throws {
        let snapshot = WidgetBridge.Snapshot(
            title: "Untitled", artist: nil, songID: "id", isPlaying: false,
            artworkURL: nil, updatedAt: Date()
        )
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testAppGroupIdentifierMatchesTheEntitlement() {
        // Both targets' entitlements declare this group; a mismatch means the
        // widget reads an empty container and shows a placeholder forever.
        XCTAssertEqual(WidgetBridge.appGroupID, "group.io.tonebox.baton")
    }

    // MARK: - What publishing writes

    /// The widget draws the cover from `artworkFile` and never reads the URL, and the URL is
    /// a signed Subsonic link whose query carries the account's user name and token. It had
    /// no reason to sit in the App Group (TBX-1000000480 B-18).
    @MainActor
    func testTheSignedArtworkURLStaysOutOfTheAppGroup() throws {
        defer { WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil) }
        let signed = URL(string: "https://music.invalid/rest/getCoverArt.view?id=al-1&u=owner&t=abc123&s=salt")!

        WidgetBridge.publish(song: song("a"), isPlaying: true, artworkURL: signed)

        let data = try XCTUnwrap(UserDefaults(suiteName: WidgetBridge.appGroupID)?
            .data(forKey: WidgetBridge.snapshotKey), "precondition: a snapshot was written")
        XCTAssertNil(WidgetBridge.read()?.artworkURL, "the signed cover URL reached the App Group")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("getCoverArt"))
    }

    /// Each publish fetches its cover in the background and wrote it back with the song it
    /// started with, so a cover that landed late put an older track, or the old play state,
    /// back on the widget (TBX-1000000480 B-2).
    @MainActor
    func testALateCoverDoesNotPutAnOlderTrackBack() async throws {
        let original = WidgetBridge.fetchArtwork
        defer {
            WidgetBridge.fetchArtwork = original
            WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil)
        }
        WidgetBridge.fetchArtwork = { await Self.slowCoverForA($0) }

        WidgetBridge.publish(song: song("a"), isPlaying: true, artworkURL: URL(string: "https://music.invalid/a"))
        WidgetBridge.publish(song: song("b"), isPlaying: false, artworkURL: URL(string: "https://music.invalid/b"))
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(WidgetBridge.read()?.songID, "b", "a late cover put the previous track back")
        XCTAssertEqual(WidgetBridge.read()?.isPlaying, false, "a late cover put the old play state back")
        XCTAssertEqual(try Self.coverOnDisk(), Self.coverBytes("b"),
                       "a late cover replaced the current track's picture in the App Group")
    }

    /// The purge publishes nil; a cover still on its way must not write the old account's
    /// track back afterwards.
    @MainActor
    func testACoverLandingAfterNothingIsPlayingWritesNothing() async throws {
        let original = WidgetBridge.fetchArtwork
        defer {
            WidgetBridge.fetchArtwork = original
            WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil)
        }
        WidgetBridge.fetchArtwork = { await Self.slowCoverForA($0) }

        WidgetBridge.publish(song: song("a"), isPlaying: true, artworkURL: URL(string: "https://music.invalid/a"))
        WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil)
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertNil(WidgetBridge.read(), "a late cover brought back a track after the session ended")
        XCTAssertNil(try Self.coverOnDisk(), "the old session's cover is still in the App Group")
    }

    /// Nothing playing means no cover left behind, not merely no snapshot pointing at it.
    @MainActor
    func testPublishingNothingRemovesTheCover() async throws {
        let original = WidgetBridge.fetchArtwork
        defer {
            WidgetBridge.fetchArtwork = original
            WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil)
        }
        WidgetBridge.fetchArtwork = { await Self.slowCoverForA($0) }
        WidgetBridge.publish(song: song("b"), isPlaying: true, artworkURL: URL(string: "https://music.invalid/b"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try Self.coverOnDisk(), Self.coverBytes("b"), "precondition: the cover landed")

        WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil)

        XCTAssertNil(try Self.coverOnDisk(), "the cover outlived the session")
    }

    /// The cover for `/a` arrives after a delay; any other arrives at once. Each is distinct
    /// bytes, so the file on disk says whose cover it is.
    @MainActor
    private static func slowCoverForA(_ url: URL?) async -> Data? {
        let name = url?.lastPathComponent ?? ""
        if name == "a" { try? await Task.sleep(for: .milliseconds(300)) }
        return coverBytes(name)
    }

    private static func coverBytes(_ name: String) -> Data { Data("cover-\(name)".utf8) }

    /// The cover file in the App Group, or nil when there is none.
    private static func coverOnDisk() throws -> Data? {
        let container = try XCTUnwrap(WidgetBridge.containerURL, "no App Group container")
        return try? Data(contentsOf: container.appendingPathComponent(WidgetBridge.artworkFilename))
    }

    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Track \(id)", artist: "Tests")
    }
}
