import BatonSubsonicKit
import XCTest
@testable import Baton

/// C3-18: a transcribe call made after the host was switched off answered
/// "not set up" through `finishWork`, which releases the claim. Made while a transcription was
/// still running for that track, it handed the lock away mid-pass, as summarize once did.
@MainActor
final class TranscriptionNotConfiguredClaimTests: XCTestCase {
    private var directory: URL!
    private var store: TranscriptStore!

    override func setUp() async throws {
        try await super.setUp()
        SpeechConfig.defaults = UserDefaults(suiteName: ThrowawayDefaults.name("coordinator-claim"))!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-coordinator-claim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TranscriptStore(directory: directory)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        SpeechConfig.defaults = .standard
        try await super.tearDown()
    }

    func testTheNotConfiguredAnswerLeavesARunningTranscriptionsClaimAlone() async {
        XCTAssertFalse(SpeechConfig.isTranscriptionConfigured)
        let id = "https://feeds.example.com/ep-busy.mp3"
        XCTAssertTrue(store.beginWork(on: id), "stand in for a transcription in progress")

        let result = await TranscriptionCoordinator(store: store)
            .transcribe(song: NavidromeSong(id: id, title: "Episode", artist: "Show", album: nil, duration: 3600), client: nil)

        XCTAssertNil(result)
        XCTAssertTrue(store.isWorking(on: id), "the running transcription still holds the claim")
        XCTAssertFalse(store.beginWork(on: id), "so nothing else can start one")
    }
}
