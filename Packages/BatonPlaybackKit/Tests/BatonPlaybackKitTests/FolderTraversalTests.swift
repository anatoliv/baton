import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// The recursive folder collector — the logic behind "play this folder".
///
/// It walks server data, so the tests are about what server data does to walkers:
/// cycles must terminate, limits must trip *and be reported*, and the order must read
/// the way the folder does on screen (a directory's songs, then its subfolders,
/// depth-first).
final class FolderTraversalTests: XCTestCase {
    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: id)
    }

    private func directory(
        _ id: String, folders: [(String, String)] = [], songs: [String] = []
    ) -> NavidromeDirectory {
        NavidromeDirectory(
            id: id, name: id,
            folders: folders.map { NavidromeFolder(id: $0.0, name: $0.1) },
            songs: songs.map(song)
        )
    }

    private func collect(
        _ tree: [String: NavidromeDirectory], from root: String,
        maxDirectories: Int = FolderTraversal.maxDirectories,
        maxSongs: Int = FolderTraversal.maxSongs
    ) async -> FolderTraversal.Result {
        await FolderTraversal.collect(
            rootID: root, maxDirectories: maxDirectories, maxSongs: maxSongs
        ) { tree[$0] }
    }

    func testDepthFirstSongsBeforeSubfolders() async {
        // artist/ { single.mp3, Album1/{a1,a2}, Album2/{b1} } — the Finder reading:
        // the folder's own songs, then each album in order, each album complete
        // before the next begins.
        let tree = [
            "artist": directory("artist", folders: [("alb1", "Album1"), ("alb2", "Album2")], songs: ["single"]),
            "alb1": directory("alb1", songs: ["a1", "a2"]),
            "alb2": directory("alb2", songs: ["b1"]),
        ]
        let result = await collect(tree, from: "artist")
        XCTAssertEqual(result.songs.map(\.id), ["single", "a1", "a2", "b1"])
        XCTAssertFalse(result.truncated)
    }

    func testNestingRecursesToAnyDepth() async {
        let tree = [
            "a": directory("a", folders: [("b", "b")]),
            "b": directory("b", folders: [("c", "c")]),
            "c": directory("c", songs: ["deep"]),
        ]
        let result = await collect(tree, from: "a")
        XCTAssertEqual(result.songs.map(\.id), ["deep"])
    }

    func testACycleTerminates() async {
        // a → b → a: a symlinked tree. A naive walker never returns from this.
        let tree = [
            "a": directory("a", folders: [("b", "b")], songs: ["s1"]),
            "b": directory("b", folders: [("a", "a")], songs: ["s2"]),
        ]
        let result = await collect(tree, from: "a")
        XCTAssertEqual(result.songs.map(\.id), ["s1", "s2"], "each directory once, then stop")
        XCTAssertFalse(result.truncated, "a cycle is handled, not reported as truncation")
    }

    func testSongCapTripsAndIsReported() async {
        let tree = [
            "root": directory("root", folders: [("kid", "kid")], songs: ["s1", "s2", "s3"]),
            "kid": directory("kid", songs: ["s4"]),
        ]
        let result = await collect(tree, from: "root", maxSongs: 2)
        XCTAssertEqual(result.songs.count, 2)
        XCTAssertTrue(result.truncated, "a cap that trips silently reads as a small folder")
    }

    func testDirectoryCapTripsAndIsReported() async {
        var tree = ["root": directory("root", folders: (1...5).map { ("d\($0)", "d\($0)") })]
        for i in 1...5 { tree["d\(i)"] = directory("d\(i)", songs: ["song\(i)"]) }
        let result = await collect(tree, from: "root", maxDirectories: 3)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(result.songs.count, 5)
    }

    func testAnUnanswerableDirectoryIsSkippedNotFatal() async {
        // "gone" isn't in the tree — the server 404s it. The walk continues past it.
        let tree = [
            "root": directory("root", folders: [("gone", "gone"), ("ok", "ok")]),
            "ok": directory("ok", songs: ["survivor"]),
        ]
        let result = await collect(tree, from: "root")
        XCTAssertEqual(result.songs.map(\.id), ["survivor"])
        XCTAssertFalse(result.truncated)
    }

    func testEmptyRootYieldsNothing() async {
        let result = await collect(["root": directory("root")], from: "root")
        XCTAssertTrue(result.songs.isEmpty)
        XCTAssertFalse(result.truncated)
    }
}
