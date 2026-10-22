import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Every way the deck makes a different player (or item) the one being heard keeps the spoken
/// speed and the speech-friendly time-pitch algorithm.
///
/// Found while checking an internal task on the simulator: after Next on a book at 1.5×, the next
/// chapter ran 0:02 to 0:16 in about 14 s, 1×, while the player said 1.5×. A blend plays the
/// incoming item on a second `AVQueuePlayer`, which starts at 1×, and promoting it never gave it
/// the speed. The controller only re-applies the speed when the *target* changes, and chapter to
/// chapter it does not, so the promoted player stayed at 1× for the rest of the book, through
/// later cuts and gapless advances on it too.
@MainActor
final class SwapRateTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.swaprate"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private var files: [String: URL] = [:]

    override func tearDown() {
        for url in files.values { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    /// Real 20 s files, so the players genuinely run and a blend genuinely promotes.
    private func makeController(gapless: Bool = true) -> StreamingPlaybackController {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tbx-10988-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, id) in ["ch1", "ch2", "ch3", "song"].enumerated() {
            let url = dir.appendingPathComponent("\(id).wav")
            try? EngineTestSignals.sineWAV(frequency: 220 * Double(n + 1), seconds: 20).write(to: url)
            files[id] = url
        }
        let urls = files
        let c = StreamingPlaybackController(
            streamURLProvider: { id in urls[id]! }, defaults: suite, systemNowPlaying: false
        )
        c.isSpokenItem = { $0.id.hasPrefix("ch") }
        c.gaplessEnabled = gapless
        c.crossfadeSeconds = 0
        c.spokenRate = 1.5
        return c
    }

    private func item(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: id, artist: "Reader", album: nil, duration: 20, coverArtID: nil)
    }

    private func book() -> [NavidromeSong] { ["ch1", "ch2", "ch3"].map(item) }

    private func settle(_ c: StreamingPlaybackController) async throws {
        let deadline = Date().addingTimeInterval(8)
        while c.isCrossfadingForTesting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(c.isCrossfadingForTesting, "the blend never finished")
    }

    private func assertHeardAt(_ rate: Float, _ c: StreamingPlaybackController, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let rates = c.deckPlayerRatesForTesting
        XCTAssertEqual(rates.defaultRate, rate, "\(what): the player's default rate", file: file, line: line)
        XCTAssertEqual(rates.rate, rate, "\(what): the running player's rate", file: file, line: line)
        XCTAssertEqual(c.currentItemTimePitchForTesting, .timeDomain, "\(what): the pitch algorithm", file: file, line: line)
        XCTAssertEqual(c.playbackRate, rate, "\(what): the controller's speed", file: file, line: line)
    }

    /// A Next on a playing chapter is a skip blend: the promoted player must run at 1.5×.
    func testANextBlendKeepsTheSpokenSpeed() async throws {
        let c = makeController()
        defer { c.stop() }
        c.play(book(), startAt: 0)
        try await Task.sleep(for: .milliseconds(400))
        assertHeardAt(1.5, c, "chapter 1")
        c.next()
        try await settle(c)
        XCTAssertEqual(c.nowPlaying?.id, "ch2")
        assertHeardAt(1.5, c, "chapter 2 after a Next blend")
    }

    /// The automatic crossfade between chapters: the incoming player runs at the spoken speed
    /// during the fade, and after promotion.
    func testACrossfadeKeepsTheSpokenSpeed() async throws {
        let c = makeController(gapless: false)
        defer { c.stop() }
        c.play(book(), startAt: 0)
        try await Task.sleep(for: .milliseconds(400))
        c.startCrossfadeForTesting(to: 1)
        XCTAssertEqual(c.crossfadeRampForTesting.player?.defaultRate, 1.5, "the incoming player during the fade")
        try await settle(c)
        XCTAssertEqual(c.nowPlaying?.id, "ch2")
        assertHeardAt(1.5, c, "chapter 2 after a crossfade")
    }

    /// Crossfading from a chapter into a song: the song fades in at 1×, not at the book's speed.
    func testACrossfadeIntoMusicFadesInAtOneTimes() async throws {
        let c = makeController(gapless: false)
        defer { c.stop() }
        c.play([item("ch1"), item("song")], startAt: 0)
        try await Task.sleep(for: .milliseconds(400))
        c.startCrossfadeForTesting(to: 1)
        XCTAssertEqual(c.crossfadeRampForTesting.player?.defaultRate, 1, "a song is never sped up, not even while fading in")
        try await settle(c)
        assertHeardAt(1, c, "the song after the crossfade")
    }

    /// A gapless advance on the player a Next promoted keeps the speed.
    func testAGaplessAdvanceAfterANextKeepsTheSpokenSpeed() async throws {
        let c = makeController()
        defer { c.stop() }
        c.play(book(), startAt: 0)
        try await Task.sleep(for: .milliseconds(400))
        c.next()
        try await settle(c)
        XCTAssertEqual(c.gaplessPreloadIndexForTesting, 2, "precondition: chapter 3 is preloaded")
        c.seek(to: 19.6)
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.gaplessAdvanceCountForTesting, 1, "precondition: the boundary was a gapless advance")
        XCTAssertEqual(c.nowPlaying?.id, "ch3")
        assertHeardAt(1.5, c, "chapter 3 after a gapless advance")
    }

    /// A cut (a jump reloads the item) on the player a Next promoted keeps the speed.
    func testACutAfterANextKeepsTheSpokenSpeed() async throws {
        let c = makeController()
        defer { c.stop() }
        c.play(book(), startAt: 0)
        try await Task.sleep(for: .milliseconds(400))
        c.next()
        try await settle(c)
        c.jump(to: 2)
        XCTAssertEqual(c.nowPlaying?.id, "ch3")
        assertHeardAt(1.5, c, "chapter 3 after a cut")
    }
}
