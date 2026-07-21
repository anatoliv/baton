import XCTest
@testable import Baton

/// : the destructive `music_delete_playlist` must never fuzzy-match — exact id
/// or exact (case-insensitive) name only, else refuse and list candidates.
@MainActor
final class PlaylistDeleteTests: XCTestCase {
    private func pl(_ id: String, _ name: String) -> NavidromePlaylist {
        NavidromePlaylist(id: id, name: name, songCount: 0)
    }
    private lazy var all = [pl("1", "Monday Mix"), pl("2", "Mix 2024"), pl("3", "Focus")]

    func testExactNameDeletes() throws {
        let t = try BatonMCPToolCatalog.exactPlaylistToDelete(name: "focus", playlistID: nil, from: all)
        XCTAssertEqual(t.id, "3")
    }

    func testExactIdDeletes() throws {
        let t = try BatonMCPToolCatalog.exactPlaylistToDelete(name: nil, playlistID: "2", from: all)
        XCTAssertEqual(t.name, "Mix 2024")
    }

    func testSubstringOnlyRefusesAndListsCandidates() {
        XCTAssertThrowsError(try BatonMCPToolCatalog.exactPlaylistToDelete(name: "mix", playlistID: nil, from: all)) { err in
            let msg = (err as? BatonMCPToolError)?.message ?? ""
            XCTAssertTrue(msg.contains("Monday Mix [1]"), "should list candidates: \(msg)")
            XCTAssertTrue(msg.contains("Mix 2024 [2]"), "should list candidates: \(msg)")
            XCTAssertTrue(msg.lowercased().contains("exact"), "should explain exact-match requirement: \(msg)")
        }
    }

    func testNoMatchAtAllThrowsPlainNotFound() {
        XCTAssertThrowsError(try BatonMCPToolCatalog.exactPlaylistToDelete(name: "nonesuch", playlistID: nil, from: all)) { err in
            XCTAssertTrue(((err as? BatonMCPToolError)?.message ?? "").contains("No playlist named"))
        }
    }

    func testUnknownIdThrows() {
        XCTAssertThrowsError(try BatonMCPToolCatalog.exactPlaylistToDelete(name: nil, playlistID: "999", from: all))
    }

    func testNeitherArgThrows() {
        XCTAssertThrowsError(try BatonMCPToolCatalog.exactPlaylistToDelete(name: nil, playlistID: nil, from: all))
    }
}
