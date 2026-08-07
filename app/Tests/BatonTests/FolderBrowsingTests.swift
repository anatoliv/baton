import XCTest
import BatonSubsonicKit
import BatonSubsonicModels
@testable import Baton

/// Decoding the Subsonic folder tree.
///
/// The interesting part is `child`: Subsonic's directory listing is one array where each
/// row is either a subfolder or a song, split by `isDir` — and the song rows are the same
/// shape as `SongWire`, which is why the decoder hands them to `SongWire` wholesale
/// instead of keeping a second copy of twenty field mappings that would drift.
final class FolderBrowsingTests: XCTestCase {
    func testIndexBucketsFlattenToFolders() throws {
        let json = Data("""
        {"status":"ok","indexes":{"index":[
            {"name":"A","artist":[{"id":"d1","name":"ABBA"},{"id":"d2","name":"AC-DC"}]},
            {"name":"B","artist":[{"id":"d3","name":"Beatles"}]}
        ]}}
        """.utf8)
        let response = try JSONDecoder().decode(SubsonicResponse.self, from: json)

        let entries = (response.indexes?.index ?? []).flatMap { $0.artist ?? [] }

        XCTAssertEqual(entries.map(\.name), ["ABBA", "AC-DC", "Beatles"],
                       "the server's A-Z buckets flatten in order")
    }

    func testDirectoryChildrenSplitIntoFoldersAndSongs() throws {
        let json = Data("""
        {"status":"ok","directory":{"id":"d1","name":"ABBA","child":[
            {"id":"d9","isDir":true,"title":"Arrival (1976)"},
            {"id":"s1","isDir":false,"title":"Dancing Queen","artist":"ABBA","album":"Arrival",
             "duration":231,"bitRate":1017,"suffix":"flac"}
        ]}}
        """.utf8)
        let response = try JSONDecoder().decode(SubsonicResponse.self, from: json)

        let children = response.directory?.child ?? []
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].folder?.name, "Arrival (1976)")
        XCTAssertNil(children[0].song, "a folder row must not also decode as a song")

        let song = children[1].song?.toDomain()
        XCTAssertEqual(song?.title, "Dancing Queen")
        XCTAssertEqual(song?.bitRate, 1017, "song rows keep the full song shape — same mapping as everywhere else")
        XCTAssertNil(children[1].folder)
    }

    /// Old servers omit `isDir` on song rows; absence means "not a directory".
    func testAMissingIsDirReadsAsASong() throws {
        let json = Data("""
        {"status":"ok","directory":{"id":"d1","name":"X","child":[
            {"id":"s2","title":"Untitled"}
        ]}}
        """.utf8)
        let response = try JSONDecoder().decode(SubsonicResponse.self, from: json)

        XCTAssertNotNil(response.directory?.child?.first?.song)
    }
}
