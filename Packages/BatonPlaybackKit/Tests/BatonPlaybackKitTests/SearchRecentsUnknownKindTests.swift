import XCTest
@testable import BatonPlaybackKit

/// One stored entry this build does not understand must not empty the list (S-F27).
///
/// `SearchRecents.Entry` has a hand-written decoder, written so that entries saved before
/// `lastOpened` and `serverID` existed still decode. One field stayed strict: `kind`. An array
/// decode is all-or-nothing, so adding a `Kind` case on the phone made the Mac's whole array throw
/// on the next read. `reload` set `all = []`, the next `record()` persisted the empty list over the
/// good one, and in `mergedValue` the remote blob decoded to `[]` too, so the merge pushed this
/// device alone and took the phone's entries out of the shared document as well.
///
/// The point of these tests is the asymmetry: one row nobody can draw yet is a small loss, and
/// every row on both devices is not.
@MainActor
final class SearchRecentsUnknownKindTests: XCTestCase {
    /// A stored list holding a `kind` this build has never heard of, alongside two it has.
    private func storedList() throws -> Data {
        let known = SearchRecents.Entry(kind: .album, id: "a1", title: "Selected Ambient Works",
                                        lastOpened: Date(timeIntervalSince1970: 2_000),
                                        serverID: "srv")
        let alsoKnown = SearchRecents.Entry(kind: .artist, id: "r1", title: "Dido",
                                            lastOpened: Date(timeIntervalSince1970: 1_000),
                                            serverID: "srv")
        var objects = try [known, alsoKnown].map { entry -> [String: Any] in
            let data = try JSONEncoder().encode(entry)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        // What a newer build writes: the same shape with a `Kind` this one cannot decode.
        objects.insert(["kind": "playlist", "id": "p1", "title": "Late night",
                        "lastOpened": 3_000.0, "serverID": "srv"], at: 0)
        return try JSONSerialization.data(withJSONObject: objects)
    }

    func testAnUnknownKindCostsThatEntryAndNoOther() throws {
        let decoded = SearchRecents.decodeList(try storedList())

        XCTAssertEqual(decoded.map(\.id), ["a1", "r1"], """
            One entry written by a build that knows a `Kind` this one does not emptied the whole \
            list. The next `record()` then persists that empty list over the good one.
            """)
    }

    /// The store itself, not just the decoder: this is the path that then persists.
    func testReloadKeepsTheEntriesItCanRead() throws {
        let suite = "baton.searchrecents.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try storedList(), forKey: SearchRecents.storageKey)

        let recents = SearchRecents(defaults: defaults, serverID: "srv")

        XCTAssertEqual(recents.all.map(\.id), ["a1", "r1"])
    }

    /// And the sync side, which is where it cost the *other* device's rows too: `mergedValue`
    /// decoded the remote blob to `[]` and pushed this device's list alone.
    func testTheMergeDoesNotDropTheOtherDevicesReadableEntries() throws {
        let local = try JSONEncoder().encode([
            SearchRecents.Entry(kind: .album, id: "local-1", title: "Here",
                                lastOpened: Date(timeIntervalSince1970: 500), serverID: "srv"),
        ])

        let merged = PreferenceSync.mergedValue(key: SearchRecents.storageKey,
                                                local: local, remote: try storedList()) as? Data
        let decoded = SearchRecents.decodeList(try XCTUnwrap(merged))

        XCTAssertEqual(Set(decoded.map(\.id)), ["local-1", "a1", "r1"], """
            The remote list failed to decode as a whole, so the merge returned this device's \
            entries alone and the PUT removed the other device's from the shared document.
            """)
    }

    /// Bytes that are not a list at all are still an empty list, not a crash: that path is
    /// unchanged and is what an absent key has always produced.
    func testGarbageIsStillAnEmptyList() {
        XCTAssertEqual(SearchRecents.decodeList(Data("not json".utf8)).count, 0)
        XCTAssertEqual(SearchRecents.decodeList(nil).count, 0)
    }
}
