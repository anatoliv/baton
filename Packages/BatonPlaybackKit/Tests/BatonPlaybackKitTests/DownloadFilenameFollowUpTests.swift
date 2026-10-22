import XCTest
@testable import BatonPlaybackKit

/// Download names for podcast episodes, whose id is their enclosure URL (
/// C2-5 and C2-12).
final class DownloadFilenameFollowUpTests: XCTestCase {
    private func name(title: String = "Episode", id: String, taken: [String: String] = [:],
                      template: String = "{artist} - {title}", artist: String? = "Show") -> String {
        MusicDownloadStore.renderFilename(template: template, artist: artist, album: nil,
                                          title: title, id: id, taken: taken)
    }

    func testTwoEpisodesWithOneTitleGetDifferentSafeNames() {
        let first = "https://cdn.example/feed/ep1.mp3"
        let second = "https://cdn.example/feed/ep2.mp3"
        let taken = ["someone": "Show - Episode.mp3", first: name(id: first, taken: ["someone": "Show - Episode.mp3"])]
        let a = taken[first]!
        let b = name(id: second, taken: taken)
        XCTAssertNotEqual(a, b, "two episodes were given one name")
        for n in [a, b] {
            XCTAssertFalse(n.contains(":"), n)
            XCTAssertFalse(n.contains("/"), n)
            XCTAssertFalse(n.contains("[https"), n)
        }
    }

    func testTheSuffixedNameIsCheckedToo() {
        let id = "abc123zz"
        let taken = ["x": "Show - Episode.mp3", "y": "Show - Episode [abc123].mp3"]
        let n = name(id: id, taken: taken)
        XCTAssertFalse(taken.values.contains(n), "the suffixed name belongs to another song: \(n)")
    }

    func testTheEmptyNameFallbackIsSanitised() {
        let n = name(id: "https://cdn.example/feed/ep1.mp3", template: "{album}", artist: nil)
        XCTAssertFalse(n.contains("/"), "the fallback made directories: \(n)")
        XCTAssertFalse(n.contains(":"), n)
        XCTAssertTrue(n.hasSuffix(".mp3"))
    }

    func testALibraryIDKeepsItsSixCharacterSuffix() {
        XCTAssertEqual(name(id: "mysong", taken: ["other": "Show - Episode.mp3"]), "Show - Episode [mysong].mp3")
    }
}
