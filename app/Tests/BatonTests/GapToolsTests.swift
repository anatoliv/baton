import XCTest
@testable import Baton

/// Coverage for the 10 gap-filler MCP tools (seek / repeat / shuffle / queue view /
/// reorder / remove / play-next / radio / sleep timer / EQ). Where a live Navidrome server
/// would be needed (search-backed play_next / radio) we don't exercise the network path;
/// instead we cover the pure argument parsing/validation and the queue/seek/mode logic
/// against a `StreamingPlaybackController` seeded with synthetic songs — the same style as
/// `StreamingPlaybackControllerTests`.
@MainActor
final class GapToolsTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.gaptools"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist \(id)", album: "Album", duration: 180, coverArtID: nil)
    }

    /// A MusicModel whose player is seeded from an isolated suite + a throwaway URL provider,
    /// so no test touches the real app's stored state and nothing streams.
    private func makeModel(seed ids: [String] = []) -> MusicModel {
        let model = MusicModel()
        // Reset the shared EQ back to a known baseline (it reads .standard).
        model.musicEqualizer.isEnabled = false
        model.musicEqualizer.apply(preset: "Flat")
        if !ids.isEmpty { model.music.play(ids.map(song)) }
        return model
    }

    // MARK: - tools/list

    func testCatalogListsAllTenNewTools() {
        let names = Set(BatonMCPToolCatalog.definitions().compactMap { $0["name"] as? String })
        let expected = [
            "music_seek", "music_set_repeat", "music_set_shuffle", "music_get_queue",
            "music_reorder_queue", "music_remove_from_queue", "music_play_next",
            "music_start_radio", "music_sleep_timer", "music_set_eq",
        ]
        for tool in expected {
            XCTAssertTrue(names.contains(tool), "missing tool \(tool)")
        }
        // 21 existing (18 music_* incl. music_build_mix + audio_suspend/audio_resume
        // + speak_summary) + 10 new = 31. NOTE: a bare count is brittle; W-41/W-46
        // replace this with a schema snapshot of the full catalog.
        XCTAssertEqual(names.count, 31, "unexpected total tool count: \(names.count)")
    }

    func testGetQueueIsAnnotatedReadOnly() {
        let def = BatonMCPToolCatalog.definitions().first { ($0["name"] as? String) == "music_get_queue" }
        let ann = def?["annotations"] as? [String: Any]
        XCTAssertEqual(ann?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(ann?["openWorldHint"] as? Bool, true)
        // None of the new tools are destructive.
        for name in ["music_reorder_queue", "music_remove_from_queue", "music_seek"] {
            let d = BatonMCPToolCatalog.definitions().first { ($0["name"] as? String) == name }
            let a = d?["annotations"] as? [String: Any]
            XCTAssertEqual(a?["destructiveHint"] as? Bool, false, "\(name) should not be destructive")
        }
    }

    // MARK: - set_repeat

    func testSetRepeatReachesEachMode() {
        let m = makeModel(seed: ["a", "b"])
        for mode in ["all", "one", "off", "one", "all", "off"] {
            let out = run("music_set_repeat", ["mode": mode], m)
            XCTAssertEqual(json(out)["repeat_mode"] as? String, mode)
            XCTAssertEqual(m.music.repeatMode.rawValue, mode)
        }
    }

    func testSetRepeatRejectsUnknownMode() {
        let m = makeModel(seed: ["a"])
        let (_, isError) = runResult("music_set_repeat", ["mode": "sometimes"], m)
        XCTAssertTrue(isError)
    }

    // MARK: - set_shuffle

    func testSetShuffleToggles() {
        let m = makeModel(seed: ["a", "b", "c", "d", "e"])
        XCTAssertFalse(m.music.isShuffled)

        var out = run("music_set_shuffle", ["enabled": true], m)
        XCTAssertEqual(json(out)["shuffle"] as? Bool, true)
        XCTAssertTrue(m.music.isShuffled)

        // Idempotent: enabling again keeps it on (no double-toggle).
        out = run("music_set_shuffle", ["enabled": true], m)
        XCTAssertTrue(m.music.isShuffled)

        out = run("music_set_shuffle", ["enabled": false], m)
        XCTAssertEqual(json(out)["shuffle"] as? Bool, false)
        XCTAssertFalse(m.music.isShuffled)
    }

    func testSetShuffleRequiresBool() {
        let m = makeModel(seed: ["a"])
        let (_, isError) = runResult("music_set_shuffle", [:], m)
        XCTAssertTrue(isError)
    }

    // MARK: - get_queue

    func testGetQueueReportsTracksAndIndex() {
        let m = makeModel()
        m.music.play(["a", "b", "c"].map(song), startAt: 1, source: .init(label: "Test Src", kind: .search, id: nil))
        let out = run("music_get_queue", [:], m)
        let obj = json(out)
        XCTAssertEqual(obj["length"] as? Int, 3)
        XCTAssertEqual(obj["current_index"] as? Int, 1)
        XCTAssertEqual(obj["source"] as? String, "Test Src")
        let queue = obj["queue"] as? [[String: Any]]
        XCTAssertEqual(queue?.count, 3)
        XCTAssertEqual(queue?[0]["index"] as? Int, 0)
        XCTAssertEqual(queue?[0]["id"] as? String, "a")
        XCTAssertEqual(queue?[2]["duration_seconds"] as? Int, 180)
    }

    // MARK: - reorder_queue

    func testReorderQueueMovesTrack() {
        let m = makeModel(seed: ["a", "b", "c", "d"])
        let out = run("music_reorder_queue", ["from": 0, "to": 3], m)
        XCTAssertNotNil(json(out)["queue"])
        // Move index 0 to offset 3 → SwiftUI move semantics place "a" before the old index-3.
        XCTAssertEqual(m.music.queue.map(\.id), ["b", "c", "a", "d"])
    }

    func testReorderQueueRejectsBadIndex() {
        let m = makeModel(seed: ["a", "b"])
        let (_, fromErr) = runResult("music_reorder_queue", ["from": 9, "to": 0], m)
        XCTAssertTrue(fromErr)
        let (_, toErr) = runResult("music_reorder_queue", ["from": 0, "to": 99], m)
        XCTAssertTrue(toErr)
    }

    // MARK: - remove_from_queue

    func testRemoveFromQueueShrinksQueue() {
        let m = makeModel(seed: ["a", "b", "c"])
        let out = run("music_remove_from_queue", ["index": 2], m)
        XCTAssertEqual(json(out)["queue_length"] as? Int, 2)
        XCTAssertEqual(m.music.queue.map(\.id), ["a", "b"])
    }

    func testRemoveFromQueueRejectsBadIndex() {
        let m = makeModel(seed: ["a"])
        let (_, isError) = runResult("music_remove_from_queue", ["index": 5], m)
        XCTAssertTrue(isError)
    }

    // MARK: - seek

    func testSeekClampsAndRequiresPlayback() {
        // Under test there's no configured server, so the queued track can't stream and the
        // controller never learns a finite duration — the seek tool then clamps only the
        // lower bound (negative → 0) and passes the requested position through. Duration-
        // ceiling clamping is covered by StreamingPlaybackControllerTests against a real asset.
        let m = makeModel(seed: ["a"])
        XCTAssertNotNil(m.music.nowPlaying) // a track is selected even without streaming

        let out = run("music_seek", ["seconds": 90], m)
        XCTAssertEqual(out["seeked_to_seconds"] as? Int, 90)

        // Negative clamps to 0.
        let low = run("music_seek", ["seconds": -20], m)
        XCTAssertEqual(low["seeked_to_seconds"] as? Int, 0)
    }

    func testSeekWithNothingPlayingErrors() {
        let m = makeModel()
        let (_, isError) = runResult("music_seek", ["seconds": 10], m)
        XCTAssertTrue(isError)
    }

    // MARK: - sleep_timer

    func testSleepTimerArmsAndCancels() {
        let m = makeModel(seed: ["a"])
        let armed = run("music_sleep_timer", ["minutes": 30], m)
        XCTAssertEqual(json(armed)["armed"] as? Bool, true)
        XCTAssertTrue(m.music.sleepTimerArmed)
        XCTAssertNotNil(json(armed)["ends_at"])

        let cancelled = run("music_sleep_timer", ["minutes": 0], m)
        XCTAssertEqual(json(cancelled)["armed"] as? Bool, false)
        XCTAssertFalse(m.music.sleepTimerArmed)
    }

    func testSleepTimerNullCancels() {
        let m = makeModel(seed: ["a"])
        _ = run("music_sleep_timer", ["minutes": 15], m)
        XCTAssertTrue(m.music.sleepTimerArmed)
        _ = run("music_sleep_timer", [:], m) // no minutes → cancel
        XCTAssertFalse(m.music.sleepTimerArmed)
    }

    // MARK: - set_eq

    func testSetEqTogglesAndAppliesPreset() {
        let m = makeModel()
        let out = run("music_set_eq", ["enabled": true, "preset": "Bass Boost"], m)
        let obj = json(out)
        XCTAssertEqual(obj["enabled"] as? Bool, true)
        XCTAssertEqual(obj["preset"] as? String, "Bass Boost")
        XCTAssertTrue(m.musicEqualizer.isEnabled)
        XCTAssertEqual(m.musicEqualizer.preset, "Bass Boost")
    }

    func testSetEqUnknownPresetListsAvailable() {
        let m = makeModel()
        let out = run("music_set_eq", ["preset": "Nonexistent"], m)
        let obj = json(out)
        XCTAssertNotNil(obj["error"])
        let available = obj["available_presets"] as? [String]
        XCTAssertTrue(available?.contains("Flat") ?? false)
        // Preset was NOT changed by the unknown name.
        XCTAssertNotEqual(m.musicEqualizer.preset, "Nonexistent")
    }

    func testSetEqEnableOnlyLeavesPreset() {
        let m = makeModel()
        m.musicEqualizer.apply(preset: "Rock")
        let out = run("music_set_eq", ["enabled": true], m)
        XCTAssertEqual(json(out)["preset"] as? String, "Rock")
        XCTAssertTrue(m.musicEqualizer.isEnabled)
    }

    // MARK: - Harness

    private var focus: BatonAudioFocusRegistry { BatonAudioFocusRegistry() }

    /// Run a tool and assert it did not error, returning the parsed JSON result.
    // MARK: - seek marker (drives the now-playing seek notification)

    func testSeekBumpsSeekMarker() {
        let m = makeModel(seed: ["a", "b"])
        let before = m.music.seekMarker
        _ = run("music_seek", ["seconds": 20], m)
        XCTAssertGreaterThan(
            m.music.seekMarker, before,
            "a seek must bump seekMarker so the MCP server emits a now-playing notification")
    }

    // MARK: - start_radio (audit #7: behavioral coverage of the relatedProvider path)

    @MainActor
    func testStartRadioBuildsQueueFromRelatedProvider() async {
        let m = makeModel(seed: ["seed"])
        // Inject a "more like this" provider so the tool builds a station without network.
        m.music.relatedProvider = { _ in ["r1", "r2", "r3"].map { self.song($0) } }
        let (text, isError) = await BatonMCPToolCatalog.run(
            name: "music_start_radio", arguments: [:], music: m, focus: focus)
        XCTAssertFalse(isError, "start_radio errored: \(text)")
        XCTAssertGreaterThan(m.music.queue.count, 1, "radio should extend the queue from the seed")
    }

    // MARK: - audio_suspend session scoping (fix #2 end-to-end)

    @MainActor
    func testAudioSuspendHandleScopedToSession() async {
        let m = makeModel(seed: ["a", "b"])
        let reg = focus  // capture one instance (the property vends a fresh registry each access)
        _ = await BatonMCPToolCatalog.run(
            name: "audio_suspend", arguments: ["owner": "claude"],
            music: m, focus: reg, sessionID: "sess-x")
        // The MCP-created handle must be scoped to its session, so closing that session's
        // SSE stream expires it (not just the 10-min sweep). A different session must not.
        XCTAssertEqual(reg.expireHandles(forConnection: "other", on: m.music), 0,
                       "a different session must not expire this handle")
        XCTAssertEqual(reg.expireHandles(forConnection: "sess-x", on: m.music), 1,
                       "MCP handle should expire when its own session stream closes")
    }

    private func run(_ name: String, _ args: [String: Any], _ music: MusicModel) -> [String: Any] {
        let (text, isError) = runResult(name, args, music)
        XCTAssertFalse(isError, "tool \(name) errored: \(text)")
        return parse(text)
    }

    private func runResult(_ name: String, _ args: [String: Any], _ music: MusicModel) -> (String, Bool) {
        let expectation = expectation(description: "run \(name)")
        var result: (String, Bool) = ("", false)
        Task { @MainActor in
            result = await BatonMCPToolCatalog.run(name: name, arguments: args, music: music, focus: focus)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return result
    }

    /// The tools return a JSON object as the result text.
    private func json(_ obj: [String: Any]) -> [String: Any] { obj }

    private func parse(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}
