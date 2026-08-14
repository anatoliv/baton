import XCTest
@testable import Baton

/// The coordinator's gating: it never runs unasked, it never runs twice, and it distinguishes
/// "unavailable" from "failed" — which is what the pane's copy hangs on.
/// See `specs/track-transcription.md`.
@MainActor
final class TranscriptionCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var store: TranscriptStore!
    private var coordinator: TranscriptionCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        SpeechConfig.defaults = UserDefaults(suiteName: "coordinator-\(UUID().uuidString)")!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TranscriptStore(directory: directory)
        coordinator = TranscriptionCoordinator(store: store)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        SpeechConfig.defaults = .standard
        try await super.tearDown()
    }

    private func song(id: String = "https://feeds.example.com/ep-1.mp3") -> NavidromeSong {
        NavidromeSong(id: id, title: "Episode 1", artist: "Show", album: nil, duration: 3600)
    }

    // MARK: - Offer gating

    /// Podcast episodes are what this is for. Music has the lyrics chain, and a transcribe
    /// button on every song invites someone to spend a GPU-hour on a synth record.
    func testTranscriptionIsOfferedForPodcastEpisodesAndNotForLibraryMusic() {
        XCTAssertTrue(TranscriptionCoordinator.isOfferedAutomatically(for: song()))
        XCTAssertFalse(TranscriptionCoordinator.isOfferedAutomatically(for: song(id: "abc123")))
    }

    // MARK: - Configuration gate

    /// Off by default, so nothing uploads audio until someone says so — and the refusal reads
    /// as an absence with an instruction, not as an error.
    func testTranscribingWithoutAConfiguredHostIsUnavailableRatherThanAFailure() async {
        XCTAssertFalse(SpeechConfig.transcriptionEnabled)

        let result = await coordinator.transcribe(song: song(), client: nil)

        XCTAssertNil(result)
        let failure = coordinator.failure(for: song().id)
        XCTAssertEqual(failure?.isUnavailable, true)
        XCTAssertTrue(failure?.message.contains("Settings → Speech") == true, "got: \(failure?.message ?? "nil")")
        XCTAssertFalse(coordinator.isBusy(song().id), "nothing should be left running")
    }

    /// A library track needs a server to resolve its audio; without one this is a failure with
    /// a readable reason rather than a silent no-op.
    func testALibraryTrackWithNoServerFailsWithAReason() async {
        SpeechConfig.transcriptionEnabled = true
        SpeechConfig.whisperBaseURL = "http://127.0.0.1:9"

        let result = await coordinator.transcribe(song: song(id: "abc123"), client: nil)

        XCTAssertNil(result)
        XCTAssertTrue(coordinator.failure(for: "abc123")?.message.contains("Not connected") == true)
        XCTAssertFalse(coordinator.isBusy("abc123"))
    }

    // MARK: - Summarize gating

    func testSummarizingWithoutATranscriptIsRefused() async {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.baseURL = "http://127.0.0.1:8000/v1"

        let summary = await coordinator.summarize(trackID: "never-transcribed", config: config)

        XCTAssertNil(summary)
        XCTAssertTrue(coordinator.failure(for: "never-transcribed")?.message.contains("no transcript") == true)
    }

    /// A consent refusal is a question, not a fault, so it is flagged the way an absence is —
    /// the pane offers the choice instead of showing a red error.
    func testSummarizingToAHostedEndpointReadsAsAQuestionNotAFault() async {
        store.save(Transcript(trackID: "ep-1", segments: [.init(start: 0, end: 5, text: "hello")]))
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.provider = .anthropic
        config.baseURL = "https://api.anthropic.com"
        config.model = "m"
        config.apiKey = "k"

        let summary = await coordinator.summarize(trackID: "ep-1", config: config)

        XCTAssertNil(summary)
        let failure = coordinator.failure(for: "ep-1")
        XCTAssertEqual(failure?.isUnavailable, true, "consent is a choice to offer, not an error to report")
        XCTAssertTrue(failure?.message.contains("isn't on your network") == true)
    }

    /// Regression: `summarize` used to report "no transcript" through `finishWork`, which
    /// releases the claim. Called while a transcription was running, that handed the lock away
    /// mid-pass and let a third call start a duplicate GPU job on the same hour of audio.
    func testSummarizingDuringATranscriptionDoesNotReleaseTheClaim() async {
        XCTAssertTrue(store.beginWork(on: "ep-busy"), "stand in for a transcription in progress")

        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.baseURL = "http://127.0.0.1:8000/v1"
        let summary = await coordinator.summarize(trackID: "ep-busy", config: config)

        XCTAssertNil(summary)
        XCTAssertTrue(store.isWorking(on: "ep-busy"), "the running transcription still holds the claim")
        XCTAssertFalse(store.beginWork(on: "ep-busy"), "so nothing else can start one")
    }

    // MARK: - Cached reads

    /// The acceptance criterion for the second play: a stored transcript is served with the
    /// host switched off entirely.
    func testAStoredTranscriptIsServedWithNoHostConfigured() {
        store.save(Transcript(trackID: "ep-1", segments: [.init(start: 0, end: 5, text: "cached")]))
        XCTAssertFalse(SpeechConfig.isTranscriptionConfigured)
        XCTAssertEqual(coordinator.transcript(for: "ep-1")?.plainText, "cached")
    }
}
