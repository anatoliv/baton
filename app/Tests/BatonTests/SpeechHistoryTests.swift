import XCTest
@testable import Baton

/// Coverage for `SpeechHistoryStore` — the persisted, bounded history that lets any past spoken
/// summary be replayed. Isolated to a throwaway `UserDefaults` suite.
@MainActor
final class SpeechHistoryTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "io.tonebox.tests.speechhistory.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRecordsNewestFirst() {
        let store = SpeechHistoryStore(defaults: suite)
        store.record(text: "first", voice: "kokoro:af_bella", engine: "kokoro", category: "research")
        store.record(text: "second", voice: nil, engine: "system", category: nil)
        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])
        XCTAssertNil(store.entries[0].voice)
        XCTAssertEqual(store.entries[1].voice, "kokoro:af_bella")
    }

    func testTrimsToMax() {
        let store = SpeechHistoryStore(defaults: suite)
        for i in 0 ..< (SpeechHistoryStore.maxEntries + 20) {
            store.record(text: "msg \(i)", voice: nil, engine: "system", category: nil)
        }
        XCTAssertEqual(store.entries.count, SpeechHistoryStore.maxEntries)
        XCTAssertEqual(store.entries.first?.text, "msg \(SpeechHistoryStore.maxEntries + 19)", "newest kept")
        XCTAssertEqual(store.entries.last?.text, "msg 20", "oldest-over-cap dropped")
    }

    func testPersistsAcrossInstances() {
        SpeechHistoryStore(defaults: suite).record(text: "remembered", voice: "chatterbox:Emily.wav", engine: "chatterbox", category: "premium")
        let reloaded = SpeechHistoryStore(defaults: suite)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.text, "remembered")
        XCTAssertEqual(reloaded.entries.first?.voice, "chatterbox:Emily.wav")
    }

    func testClearEmptiesAndPersists() {
        let store = SpeechHistoryStore(defaults: suite)
        store.record(text: "a", voice: nil, engine: "system", category: nil)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(SpeechHistoryStore(defaults: suite).entries.isEmpty, "clear persists")
    }
}
