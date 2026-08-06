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
}
