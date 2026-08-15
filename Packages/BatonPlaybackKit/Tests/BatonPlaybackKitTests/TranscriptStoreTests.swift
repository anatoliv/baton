import XCTest
@testable import BatonPlaybackKit
import BatonSubsonicModels

/// `TranscriptStore` persistence and the in-flight bookkeeping the UI leans on.
/// See `specs/track-transcription.md`.
@MainActor
final class TranscriptStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func transcript(_ id: String = "ep-1") -> Transcript {
        Transcript(
            trackID: id,
            segments: [
                .init(start: 0, end: 4, text: "Welcome back."),
                .init(start: 4, end: 9, text: "About storage."),
            ],
            language: "en",
            model: "whisper-1",
            duration: 9
        )
    }

    func testSavesAndReadsBackATranscript() {
        let store = TranscriptStore(directory: directory)
        store.save(transcript())

        XCTAssertTrue(store.hasTranscript(for: "ep-1"))
        XCTAssertEqual(store.transcribedIDs, ["ep-1"])
        XCTAssertEqual(store.transcript(for: "ep-1")?.segments.count, 2)
        XCTAssertNil(store.transcript(for: "nobody"))
    }

    /// The acceptance criterion that matters most: transcribe once, and it is there next time
    /// with nothing running — a cold store, a fresh instance, no network in the picture.
    func testTranscriptSurvivesARelaunch() {
        TranscriptStore(directory: directory).save(transcript())

        let reopened = TranscriptStore(directory: directory)
        XCTAssertTrue(reopened.hasTranscript(for: "ep-1"))
        XCTAssertEqual(reopened.transcript(for: "ep-1")?.plainText, "Welcome back. About storage.")
    }

    func testKeysByPlaybackIDSoAnEnclosureURLWorksAsAnID() {
        let url = "https://feeds.example.com/show/episode-42.mp3?token=abc"
        let store = TranscriptStore(directory: directory)
        store.save(transcript(url))

        let reopened = TranscriptStore(directory: directory)
        XCTAssertEqual(reopened.transcript(for: url)?.trackID, url)
    }

    /// A URL is neither filesystem-safe nor short enough to be a file name; the hash is what
    /// makes the previous test possible, so assert its shape directly.
    func testFileNameIsAHashRatherThanTheRawID() {
        let name = TranscriptStore.fileName(for: "https://feeds.example.com/a/b.mp3?x=1")
        XCTAssertTrue(name.hasPrefix("transcript-"))
        XCTAssertTrue(name.hasSuffix(".json"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertEqual(name.count, "transcript-".count + 64 + ".json".count)
        XCTAssertEqual(name, TranscriptStore.fileName(for: "https://feeds.example.com/a/b.mp3?x=1"), "stable")
        XCTAssertNotEqual(name, TranscriptStore.fileName(for: "https://feeds.example.com/a/b.mp3?x=2"))
    }

    func testAttachingASummaryUpdatesTheStoredTranscript() {
        let store = TranscriptStore(directory: directory)
        store.save(transcript())

        let summary = Summary(
            overview: "Storage, mostly.",
            sections: [.init(start: 0, end: 9, title: "Intro", text: "Hellos.")],
            model: "chat"
        )
        XCTAssertTrue(store.attach(summary, to: "ep-1"))

        let reopened = TranscriptStore(directory: directory)
        XCTAssertEqual(reopened.transcript(for: "ep-1")?.summary?.overview, "Storage, mostly.")
    }

    func testAttachingASummaryToAnUntranscribedTrackFailsRatherThanInventingOne() {
        let store = TranscriptStore(directory: directory)
        XCTAssertFalse(store.attach(Summary(overview: "x", sections: []), to: "never-transcribed"))
        XCTAssertFalse(store.hasTranscript(for: "never-transcribed"))
    }

    func testRemoveDeletesTheFileAndTheIndexEntry() {
        let store = TranscriptStore(directory: directory)
        store.save(transcript())
        store.remove(trackID: "ep-1")

        XCTAssertFalse(store.hasTranscript(for: "ep-1"))
        XCTAssertTrue(store.transcribedIDs.isEmpty)
        XCTAssertNil(TranscriptStore(directory: directory).transcript(for: "ep-1"))
    }

    func testClearForgetsEverything() {
        let store = TranscriptStore(directory: directory)
        store.save(transcript("a"))
        store.save(transcript("b"))
        store.clear()

        XCTAssertTrue(store.transcribedIDs.isEmpty)
        let reopened = TranscriptStore(directory: directory)
        XCTAssertNil(reopened.transcript(for: "a"))
        XCTAssertNil(reopened.transcript(for: "b"))
    }

    /// An index entry pointing at an unreadable file must not leave the UI offering a
    /// transcript it can never show.
    func testAnIndexedButUnreadableFileDropsOutOfTheIndex() throws {
        let store = TranscriptStore(directory: directory)
        store.save(transcript())
        let file = directory.appendingPathComponent(TranscriptStore.fileName(for: "ep-1"))
        try Data("not json".utf8).write(to: file)
        // The backup VersionedStore keeps would otherwise rescue it, which is right in
        // production and beside the point here.
        try? FileManager.default.removeItem(at: file.appendingPathExtension("bak"))

        let reopened = TranscriptStore(directory: directory)
        XCTAssertNil(reopened.transcript(for: "ep-1"))
        XCTAssertFalse(reopened.hasTranscript(for: "ep-1"))
    }

    // MARK: - In-flight

    func testASecondRequestForTheSameTrackIsRefused() {
        let store = TranscriptStore(directory: directory)
        XCTAssertTrue(store.beginWork(on: "ep-1"))
        XCTAssertFalse(store.beginWork(on: "ep-1"), "a double tap must not start two GPU passes")
        XCTAssertTrue(store.isWorking(on: "ep-1"))

        store.finishWork(on: "ep-1")
        XCTAssertFalse(store.isWorking(on: "ep-1"))
        XCTAssertTrue(store.beginWork(on: "ep-1"))
    }

    func testAFailureIsRetainedForThePaneAndClearedOnRetry() {
        let store = TranscriptStore(directory: directory)
        _ = store.beginWork(on: "ep-1")
        store.finishWork(on: "ep-1", failure: .init(message: "host unreachable", isUnavailable: true))
        XCTAssertEqual(store.failures["ep-1"]?.message, "host unreachable")
        XCTAssertEqual(store.failures["ep-1"]?.isUnavailable, true)

        XCTAssertTrue(store.beginWork(on: "ep-1"))
        XCTAssertNil(store.failures["ep-1"], "retrying clears the last failure")
    }

    func testASuccessfulSaveClearsAPriorFailure() {
        let store = TranscriptStore(directory: directory)
        _ = store.beginWork(on: "ep-1")
        store.finishWork(on: "ep-1", failure: .init(message: "boom"))
        store.save(transcript())
        XCTAssertNil(store.failures["ep-1"])
    }

    /// The real artifact, read off disk: one segment covering 1.7 s of a 434.7 s track, from a
    /// pipeline that no longer exists. The guard that would refuse to *make* this only ever ran
    /// at parse time, so it went on being served to the pane and to agents over MCP for as long
    /// as it sat there. Judge a stored transcript on the way out too.
    func testAStoredTranscriptTodaysRulesWouldRefuseIsDroppedOnRead() throws {
        let bad = Transcript(
            trackID: "riders",
            segments: [.init(start: 55.6, end: 57.28, text: "Do this as we\u{2019}re born.")],
            language: "en",
            model: "faster-whisper-large-v3-turbo",
            duration: 434.7335
        )
        TranscriptStore(directory: directory).save(bad)

        let reopened = TranscriptStore(directory: directory)
        XCTAssertNil(reopened.transcript(for: "riders"), "a fragment of a song is not a transcript of it")
        XCTAssertFalse(reopened.hasTranscript(for: "riders"), "and the index must not keep claiming one")
        XCTAssertFalse(reopened.transcribedIDs.contains("riders"))

        // Dropped from the index, not deleted. "Today's rules reject it" is not the same
        // claim as "it is worthless", and a transcript costs a GPU pass to make again.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.filter { $0.hasPrefix("transcript-") && $0.hasSuffix(".json") }.count, 1,
                       "the artifact stays on disk; dropping the index entry is enough")
    }

    /// The other half of that: a good transcript is not thrown away for being old.
    func testAnOrdinaryStoredTranscriptIsKept() {
        TranscriptStore(directory: directory).save(transcript())
        let reopened = TranscriptStore(directory: directory)
        XCTAssertEqual(reopened.transcript(for: "ep-1")?.segments.count, 2)
    }
}
