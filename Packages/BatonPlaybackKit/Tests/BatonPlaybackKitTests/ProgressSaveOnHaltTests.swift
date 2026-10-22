import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Pause and Stop save the place where listening halted, not the last 5 s mark (an internal task
/// re-walk). The Mac stopped a book at 0:15 of chapter 2 and the phone resumed it at 0:10; the
/// phone paused just as chapter 2 ended into chapter 3, and the Mac played chapter 2 again from
/// the top, because the ledger still held the end of chapter 2.
@MainActor
final class ProgressSaveOnHaltTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.progresssaveonhalt"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private var files: [String: URL] = [:]
    private var saves: [(id: String, time: TimeInterval)] = []

    override func tearDown() {
        for url in files.values { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func makeController() -> StreamingPlaybackController {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("halt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, id) in ["ch1", "ch2"].enumerated() {
            let url = dir.appendingPathComponent("\(id).wav")
            try? EngineTestSignals.sineWAV(frequency: 220 * Double(n + 1), seconds: 20).write(to: url)
            files[id] = url
        }
        let urls = files
        let c = StreamingPlaybackController(streamURLProvider: { id in urls[id]! }, defaults: suite, systemNowPlaying: false)
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.onProgressUpdate = { [weak self] song, time, _ in self?.saves.append((song.id, time)) }
        return c
    }

    private func chapters() -> [NavidromeSong] {
        ["ch1", "ch2"].map { NavidromeSong(id: $0, title: $0, artist: "Reader", album: nil, duration: 20, coverArtID: nil) }
    }

    /// Play from 7 s (saved there) to past 9.5 s: the 5 s clock has not saved again.
    private func playPastTheLastSave() async throws -> StreamingPlaybackController {
        let c = makeController()
        c.play(chapters(), startAt: 0)
        let ready = Date().addingTimeInterval(8)
        while c.duration <= 1, Date() < ready { try await Task.sleep(for: .milliseconds(50)) }
        c.seek(to: 7)
        let deadline = Date().addingTimeInterval(8)
        while c.currentTime < 9.5, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(c.currentTime, 9.5, "precondition: the item played on past 9.5 s")
        XCTAssertLessThan(saves.last?.time ?? 0, 9, "precondition: no save since the 7 s mark")
        return c
    }

    func testPauseSavesWhereItPaused() async throws {
        let c = try await playPastTheLastSave()
        defer { c.stop() }
        let place = c.currentTime
        c.pause()
        XCTAssertEqual(saves.last?.id, "ch1")
        XCTAssertEqual(saves.last?.time ?? 0, place, accuracy: 0.01, "Pause left the place at the last 5 s mark")
    }

    func testStopSavesWhereItStoppedNotTheRewind() async throws {
        let c = try await playPastTheLastSave()
        let place = c.currentTime
        c.stop()
        XCTAssertEqual(saves.last?.id, "ch1")
        XCTAssertEqual(saves.last?.time ?? 0, place, accuracy: 0.01, "Stop left the place at the last 5 s mark")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(saves.last?.time ?? 0, place, accuracy: 0.01, "the rewind after Stop was saved")
    }

    /// The walk's phone: Pause just as chapter 1 ended into chapter 2. The place is the start of
    /// chapter 2, not the end of chapter 1.
    func testPauseRightAfterAChapterEndsSavesTheStartOfTheNext() async throws {
        let c = makeController()
        defer { c.stop() }
        c.play(chapters(), startAt: 0)
        let ready = Date().addingTimeInterval(8)
        while c.gaplessPreloadIndexForTesting != 1, Date() < ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(c.gaplessPreloadIndexForTesting, 1, "precondition: chapter 2 preloaded")
        c.seek(to: 19.6)
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.nowPlaying?.id, "ch2", "precondition: chapter 1 ended into chapter 2")
        c.pause()
        XCTAssertEqual(saves.last?.id, "ch2", "Pause left the place at the end of chapter 1")
        XCTAssertLessThan(saves.last?.time ?? 99, 1)
    }

    /// Pause before a resume offset has been applied must not save 0:00 over the saved place.
    func testPauseBeforeTheResumeLandsSavesNothing() {
        let c = makeController()
        defer { c.stop() }
        c.resumeOffsetProvider = { _ in 12 }
        c.play(chapters(), startAt: 0)
        c.pause()
        c.stop()
        XCTAssertTrue(saves.isEmpty, "a place was saved before the resume offset applied: \(saves)")
    }
}
