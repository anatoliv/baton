import XCTest
@testable import Baton
import BatonSubsonicModels

/// A schema snapshot of the MCP tool catalog, replacing the bare `names.count == N`
/// assertion that / flagged as brittle.
///
/// A count catches "someone added a tool". It misses everything that actually breaks an
/// agent: a renamed parameter, a dropped `required` entry, a property that quietly changed
/// type, a tool losing its read-only annotation. Those are silent and remote — the client
/// is a model in another process that only ever sees this JSON.
///
/// 0.9.0 changed four tool schemas at once (`song_ids` on play/queue_add/add_to_playlist/
/// create_playlist, plus `required` emptied on three of them). Nothing in the suite would
/// have noticed if one had been wrong.
@MainActor
final class MCPSchemaSnapshotTests: XCTestCase {
    private func catalog() -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for def in BatonMCPToolCatalog.definitions() {
            if let name = def["name"] as? String { out[name] = def }
        }
        return out
    }

    private func properties(_ tool: [String: Any]) -> [String: Any] {
        let schema = tool["inputSchema"] as? [String: Any] ?? [:]
        return schema["properties"] as? [String: Any] ?? [:]
    }

    private func required(_ tool: [String: Any]) -> Set<String> {
        let schema = tool["inputSchema"] as? [String: Any] ?? [:]
        return Set(schema["required"] as? [String] ?? [])
    }

    // MARK: - The full name set

    /// The exact published surface. Adding a tool is a deliberate act — update this list
    /// and think about whether it needs annotations.
    private static let expectedNames: Set<String> = [
        "music_search", "music_play", "music_queue_add", "music_pause", "music_resume",
        "music_stop", "music_next", "music_previous", "music_set_volume", "music_now_playing",
        "music_recent_events",
        "music_list_playlists", "music_get_playlist", "music_play_playlist", "music_like",
        "music_rate", "music_create_playlist", "music_add_to_playlist", "music_delete_playlist",
        "music_build_mix", "music_seek", "music_set_repeat", "music_set_shuffle",
        "music_get_queue", "music_reorder_queue", "music_remove_from_queue", "music_play_next",
        "music_start_radio", "music_sleep_timer", "music_set_eq", "music_set_crossfade",
        "audio_suspend", "audio_resume", "speak_summary",
        // Library discovery. Search answers "is this in here"; these answer
        // "what IS in here", which is what a recommendation has to start from.
        "music_list_genres", "music_browse_albums", "music_similar_songs", "music_liked",
        "music_random", "music_artist_info",
    ]

    func testPublishedToolNamesExactlyMatchTheSnapshot() {
        let actual = Set(catalog().keys)
        XCTAssertEqual(
            actual, Self.expectedNames,
            "added: \(actual.subtracting(Self.expectedNames).sorted()) | "
                + "removed: \(Self.expectedNames.subtracting(actual).sorted())"
        )
    }

    // MARK: - Structural invariants that hold for every tool

    func testEveryToolIsWellFormed() {
        for (name, def) in catalog() {
            XCTAssertFalse(
                (def["description"] as? String ?? "").isEmpty, "\(name) needs a description"
            )
            let schema = def["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(name) schema must be an object")
            XCTAssertNotNil(schema?["properties"], "\(name) must declare properties")
            XCTAssertNotNil(schema?["required"], "\(name) must declare required (even if empty)")
            for key in required(def) {
                XCTAssertNotNil(
                    properties(def)[key], "\(name) requires '\(key)' but never declares it"
                )
            }
            for (key, value) in properties(def) {
                let prop = value as? [String: Any]
                XCTAssertNotNil(prop?["type"], "\(name).\(key) has no type")
                XCTAssertFalse(
                    (prop?["description"] as? String ?? "").isEmpty,
                    "\(name).\(key) has no description — the client is a model, it only reads this"
                )
            }
        }
    }

    // MARK: - Contracts an agent actually depends on

    /// The 0.9.0 addition. Losing it silently would send callers back to fuzzy title matching,
    /// which is how five unvetted "Adagio for Strings" tracks once landed in a playlist.
    func testExactAddressingIsAvailableWhereversItMatters() {
        for name in ["music_play", "music_queue_add", "music_add_to_playlist", "music_create_playlist"] {
            let tool = try! XCTUnwrap(catalog()[name])
            let ids = properties(tool)["song_ids"] as? [String: Any]
            XCTAssertEqual(ids?["type"] as? String, "array", "\(name) must accept song_ids")
            XCTAssertEqual(
                (ids?["items"] as? [String: Any])?["type"] as? String, "string",
                "\(name).song_ids must be an array of strings"
            )
        }
    }

    /// Discovery tools exist to be *tried*, often speculatively and in a loop.
    /// A required argument on any of them turns "have a look around" into a
    /// guess about what to look for, which is the problem they were added to fix.
    func testDiscoveryToolsAskForNothingUpFront() {
        for name in ["music_list_genres", "music_browse_albums", "music_liked",
                     "music_random", "music_similar_songs", "music_artist_info"] {
            let tool = try! XCTUnwrap(catalog()[name], "\(name) is missing")
            XCTAssertTrue(required(tool).isEmpty, "\(name) must be callable with no arguments")
            let ann = tool["annotations"] as? [String: Any]
            XCTAssertEqual(ann?["readOnlyHint"] as? Bool, true, "\(name) only reads")
            XCTAssertEqual(ann?["destructiveHint"] as? Bool, false, "\(name) destroys nothing")
        }
    }

    /// These take either `song_ids` or `query`, so neither may be schema-required —
    /// marking one required would make the other unreachable.
    func testEitherOrToolsRequireNeitherAlternative() {
        for name in ["music_play", "music_queue_add", "music_add_to_playlist"] {
            let tool = try! XCTUnwrap(catalog()[name])
            XCTAssertFalse(required(tool).contains("query"), "\(name) must not force query")
            XCTAssertFalse(required(tool).contains("song_ids"), "\(name) must not force song_ids")
        }
    }

    func testReadOnlyToolsAreAnnotatedAndWritersAreNot() {
        for name in ["music_search", "music_now_playing", "music_list_playlists",
                     "music_get_playlist", "music_get_queue"] {
            let ann = catalog()[name]?["annotations"] as? [String: Any]
            XCTAssertEqual(ann?["readOnlyHint"] as? Bool, true, "\(name) should be read-only")
        }
        for name in ["music_play", "music_add_to_playlist", "music_delete_playlist"] {
            let ann = catalog()[name]?["annotations"] as? [String: Any]
            XCTAssertNotEqual(
                ann?["readOnlyHint"] as? Bool, true, "\(name) mutates and must not claim read-only"
            )
        }
    }

    func testDeletePlaylistIsTheOnlyDestructiveTool() {
        let destructive = catalog().filter {
            (($0.value["annotations"] as? [String: Any])?["destructiveHint"] as? Bool) == true
        }.keys.sorted()
        XCTAssertEqual(destructive, ["music_delete_playlist"])
    }

    func testToolsWithRequiredArgumentsStillDeclareThem() {
        XCTAssertEqual(required(catalog()["music_search"]!), ["query"])
        XCTAssertEqual(required(catalog()["music_rate"]!), ["rating"])
        XCTAssertEqual(required(catalog()["music_set_volume"]!), ["percent"])
        XCTAssertEqual(required(catalog()["music_set_crossfade"]!), ["seconds"])
        XCTAssertEqual(required(catalog()["music_create_playlist"]!), ["name"])
    }
}

/// `NavidromeError.isNotFound` — the distinction that stops an outage being reported as
/// "no song with that id". Added after an audit found `songsByID` swallowing every failure
/// with `try?`, which would have blamed correct ids whenever the server was unreachable.
final class NavidromeNotFoundTests: XCTestCase {
    func testSubsonicCode70IsNotFound() {
        XCTAssertTrue(NavidromeError.subsonic(code: 70, message: "not found").isNotFound)
    }

    func testHTTP404IsNotFound() {
        XCTAssertTrue(NavidromeError.http(status: 404).isNotFound)
    }

    func testTransportAndAuthFailuresAreNotMissingItems() {
        XCTAssertFalse(NavidromeError.transport("offline").isNotFound)
        XCTAssertFalse(NavidromeError.unauthorized.isNotFound)
        XCTAssertFalse(NavidromeError.http(status: 500).isNotFound)
        XCTAssertFalse(NavidromeError.notConfigured.isNotFound)
        XCTAssertFalse(NavidromeError.decoding("bad envelope").isNotFound)
    }

    func testOtherSubsonicCodesAreNotMissingItems() {
        XCTAssertFalse(NavidromeError.subsonic(code: 40, message: "wrong credentials").isNotFound)
        XCTAssertFalse(NavidromeError.subsonic(code: 0, message: "generic").isNotFound)
    }
}

/// `previous(force:)` — the restart-first rule, and the escape hatch for remote callers.
///
/// The 3-second rule suits a human at a button, where hearing and pressing are under a
/// second apart. Over MCP a round-trip takes seconds by construction, so `music_previous`
/// restarted the current track essentially every time and stepping back was unreachable.
/// Rather than tune a threshold that is correct for hands, the caller states its intent.
@MainActor
final class PreviousTrackRuleTests: XCTestCase {
    private func restarts(_ time: TimeInterval, _ index: Int, force: Bool = false) -> Bool {
        StreamingPlaybackController.previousRestartsCurrent(
            currentTime: time, currentIndex: index, force: force)
    }

    func testEarlyInATrackStepsBack() {
        XCTAssertFalse(restarts(1.0, 3))
    }

    func testLaterInATrackRestartsIt() {
        XCTAssertTrue(restarts(30.0, 3), "the familiar back-button behaviour must survive")
    }

    /// The MCP handler defaults `force` to true — the opposite of the button — because a
    /// remote round-trip always exceeds the 3s threshold. Pinned here because it is a
    /// deliberate divergence, and a "sensible" later edit aligning it with the button would
    /// silently make stepping back unreachable again.
    func testMCPDefaultsToSteppingBackNotRestarting() {
        let tool = BatonMCPToolCatalog.definitions().first { ($0["name"] as? String) == "music_previous" }
        let schema = tool?["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["force"], "music_previous must expose force")
        let desc = (tool?["description"] as? String ?? "").lowercased()
        XCTAssertTrue(desc.contains("always steps back"),
                      "the description must tell the client the default is step-back")
    }

    func testForceAlwaysStepsBackHoweverFarIn() {
        XCTAssertFalse(restarts(30.0, 3, force: true))
        XCTAssertFalse(restarts(9999.0, 3, force: true))
    }

    func testTheFirstTrackAlwaysRestartsEvenWithForce() {
        // force cannot invent a track that does not exist; stepping back from index 0 would
        // underflow the queue.
        XCTAssertTrue(restarts(0.0, 0))
        XCTAssertTrue(restarts(30.0, 0, force: true))
    }

    func testTheThresholdBoundaryBehavesAsDocumented() {
        XCTAssertFalse(restarts(3.0, 2), "exactly 3s is still 'at the start'")
        XCTAssertTrue(restarts(3.01, 2))
    }
}
