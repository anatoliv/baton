#if os(iOS) || os(macOS)
import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The alarm's sound on the iPhone: saving an alarm or timer cuts the first 29
/// seconds of its track into a Linear PCM CAF named `baton-alarm-<id>.caf` in the sounds
/// directory, from a local file or a fetched stream; otherwise the chime rings, and without a
/// chime the system's sound.
@MainActor
final class AlarmClipStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("alarm-clips-\(UUID().uuidString)/Sounds")
        StubStream.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil))
    }

    private func clips(_ name: String, hasChime: Bool = true, session: URLSession = .shared,
                       resolve: @escaping (String) -> URL?) -> AlarmClipStore {
        let store = AlarmClipStore(directory: directory, defaults: ThrowawayDefaults.make(name), session: session,
                                   hasChime: hasChime, timeout: .seconds(30))
        store.resolve = resolve
        return store
    }

    private func alarms(_ name: String) -> AlarmStore { AlarmStore(defaults: ThrowawayDefaults.make(name)) }

    private let song = NavidromeSong(id: "song-1", title: "Variatio 4", artist: "Kimiko Ishizaka")

    private func assertValidClip(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let info = try XCTUnwrap(AlarmClipStore.clipInfo(at: url), "a readable sound file", file: file, line: line)
        XCTAssertTrue(info.isLinearPCM, "Linear PCM", file: file, line: line)
        XCTAssertLessThanOrEqual(info.seconds, 29.05, "at most 29 seconds", file: file, line: line)
        XCTAssertGreaterThan(info.seconds, 28, "the first 29 seconds of a 68-second track", file: file, line: line)
        XCTAssertEqual(info.sampleRate, 22_050, file: file, line: line)
        XCTAssertEqual(info.channels, 1, file: file, line: line)
        XCTAssertEqual(url.pathExtension, "caf", file: file, line: line)
    }

    func testSavingAnAlarmCutsAValidClipFromALocalFile() async throws {
        let source = try fixture()
        let clips = clips("clips.local") { _ in source }
        let store = alarms("clips.local.store")
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm)
        XCTAssertEqual(clips.soundName(for: alarm.id), AlarmClipStore.chime, "the chime until the clip is made")

        let changed = await clips.prepare(store)
        XCTAssertTrue(changed, "a new clip is a new sound, so the caller schedules again")
        let url = directory.appendingPathComponent("baton-alarm-\(alarm.id.uuidString).caf")
        XCTAssertEqual(clips.clipURL(for: alarm.id), url)
        try assertValidClip(url)
        XCTAssertEqual(clips.soundName(for: alarm.id), "baton-alarm-\(alarm.id.uuidString).caf")

        let again = await clips.prepare(store)
        XCTAssertFalse(again, "an unchanged alarm keeps its clip and is not cut again")
    }

    func testATimerGetsAClipToo() async throws {
        let source = try fixture()
        let clips = clips("clips.timer") { _ in source }
        let store = alarms("clips.timer.store")
        store.startTimer(duration: 600, choice: .song(song))
        let timer = try XCTUnwrap(store.timer)
        _ = await clips.prepare(store)
        try assertValidClip(clips.clipURL(for: timer.id))
        XCTAssertTrue(clips.soundName(for: timer.id).hasPrefix("baton-alarm-"))
    }

    /// A server track: AVAssetReader refuses a non-local URL, so the stream is fetched first.
    /// The stub answers as a transcoding server does, with no length and no ranges.
    func testAStreamIsFetchedAndCut() async throws {
        StubStream.body = try Data(contentsOf: fixture())
        StubStream.mime = "audio/mpeg"
        let clips = clips("clips.stream", session: StubStream.session()) { _ in URL(string: "https://music.example/rest/stream?id=song-1")! }
        let store = alarms("clips.stream.store")
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm)
        let changed = await clips.prepare(store)
        XCTAssertTrue(changed)
        XCTAssertEqual(StubStream.requests, 1)
        try assertValidClip(clips.clipURL(for: alarm.id))
        XCTAssertTrue(clips.soundName(for: alarm.id).hasPrefix("baton-alarm-"))
    }

    /// A server behind a header-checking proxy: the stream is fetched with the server's extra
    /// headers, as the player fetches it (TBX-1000000410 review).
    func testAStreamIsFetchedWithTheServersHeaders() async throws {
        StubStream.body = try Data(contentsOf: fixture())
        StubStream.requiredHeader = ("X-Proxy-Key", "k1")
        let server = URL(string: "https://music.example/rest/stream?id=song-1")!
        let fetching = clips("clips.headers", session: StubStream.session()) { _ in server }
        var asked: [URL] = []
        fetching.headers = { url in asked.append(url); return ["X-Proxy-Key": "k1"] }
        let store = alarms("clips.headers.store")
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm)
        _ = await fetching.prepare(store)
        XCTAssertEqual(asked, [server])
        try assertValidClip(fetching.clipURL(for: alarm.id))

        // Without the header the proxy refuses, and the chime rings.
        let refused = clips("clips.headers.refused", session: StubStream.session()) { _ in server }
        refused.headers = { _ in [:] }
        let other = BatonAlarm(hour: 8, minute: 0, choice: .song(song))
        store.save(other)
        _ = await refused.prepare(store)
        XCTAssertEqual(refused.soundName(for: other.id), AlarmClipStore.chime)
    }

    func testAFailedStreamKeepsTheChimeAndLeavesNoFile() async throws {
        StubStream.status = 404
        let clips = clips("clips.404", session: StubStream.session()) { _ in URL(string: "https://music.example/rest/stream?id=gone")! }
        let store = alarms("clips.404.store")
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm)
        let changed = await clips.prepare(store)
        XCTAssertFalse(changed, "still the chime")
        XCTAssertEqual(clips.soundName(for: alarm.id), AlarmClipStore.chime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clips.clipURL(for: alarm.id).path))
    }

    func testNothingToReadRingsTheChimeAndWithoutAChimeTheSystemSound() async {
        let store = alarms("clips.none.store")
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm)
        let withChime = clips("clips.none") { _ in nil }
        _ = await withChime.prepare(store)
        XCTAssertEqual(withChime.soundName(for: alarm.id), AlarmClipStore.chime)
        let noChime = clips("clips.none2", hasChime: false) { _ in nil }
        _ = await noChime.prepare(store)
        XCTAssertEqual(noChime.soundName(for: alarm.id), "", "the system's own sound, the last resort")
    }

    /// A track that cannot be cut is not tried again at every sync for ten minutes, so a server
    /// that is away does not cost each sync a fetch timeout; after that, or for a new track, it is.
    func testAFailedClipIsNotRetriedAtEverySync() async throws {
        var asked = 0
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let clips = clips("clips.retry") { _ in asked += 1; return nil }
        clips.now = { clock }
        let store = alarms("clips.retry.store")
        var alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm)
        _ = await clips.prepare(store)
        _ = await clips.prepare(store)
        XCTAssertEqual(asked, 1, "not again within ten minutes")
        clock = clock.addingTimeInterval(11 * 60)
        _ = await clips.prepare(store)
        XCTAssertEqual(asked, 2, "tried again later")
        alarm.choice = .song(NavidromeSong(id: "song-2", title: "Aria"))
        store.save(alarm)
        _ = await clips.prepare(store)
        XCTAssertEqual(asked, 3, "a new track is tried at once")
        XCTAssertEqual(clips.soundName(for: alarm.id), AlarmClipStore.chime)
    }

    func testDeletingOrSwitchingOffAnAlarmRemovesItsClip() async throws {
        let source = try fixture()
        let clips = clips("clips.remove") { _ in source }
        let store = alarms("clips.remove.store")
        let kept = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        let off = BatonAlarm(hour: 8, minute: 0, choice: .song(song))
        store.save(kept)
        store.save(off)
        _ = await clips.prepare(store)
        XCTAssertTrue(clips.hasClip(for: kept.id))
        XCTAssertTrue(clips.hasClip(for: off.id))

        store.setEnabled(false, id: off.id)
        let changed = await clips.prepare(store)
        XCTAssertTrue(changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clips.clipURL(for: off.id).path))
        XCTAssertTrue(clips.hasClip(for: kept.id))

        store.delete(id: kept.id)
        _ = await clips.prepare(store)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".caf") }
        XCTAssertEqual(left, [])
    }

    func testChangingTheTrackCutsANewClip() async throws {
        let source = try fixture()
        var asked: [String] = []
        let clips = clips("clips.change") { id in asked.append(id); return source }
        let store = alarms("clips.change.store")
        var alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm)
        _ = await clips.prepare(store)
        alarm.choice = .song(NavidromeSong(id: "song-2", title: "Aria"))
        store.save(alarm)
        let changed = await clips.prepare(store)
        XCTAssertTrue(changed)
        XCTAssertEqual(asked, ["song-1", "song-2"])
        try assertValidClip(clips.clipURL(for: alarm.id))
    }

    /// Two syncs at once (a store change starts one while another is still cutting) cut the clip
    /// once, and the file is whole.
    func testOverlappingPreparationsCutOnce() async throws {
        let source = try fixture()
        var asked = 0
        let clips = clips("clips.overlap") { _ in asked += 1; return source }
        let store = alarms("clips.overlap.store")
        let alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song))
        store.save(alarm)
        async let first = clips.prepare(store)
        async let second = clips.prepare(store)
        let results = await [first, second]
        XCTAssertEqual(asked, 1, "one cut")
        XCTAssertEqual(results.filter { $0 }.count, 1, "one of them made it")
        try assertValidClip(clips.clipURL(for: alarm.id))
    }

    func testAStalledSourceTimesOutAndLeavesTheTargetAlone() async throws {
        StubStream.stall = true
        let target = directory.appendingPathComponent("baton-alarm-stall.caf")
        let started = Date()
        let ok = await AlarmClipStore.render(from: URL(string: "https://music.example/stall")!, to: target, seconds: 29,
                                             timeout: .seconds(1), session: StubStream.session())
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testFileExtensionsForStreamTypes() {
        XCTAssertEqual(AlarmClipStore.fileExtension(forMIME: "audio/mpeg"), "mp3")
        XCTAssertEqual(AlarmClipStore.fileExtension(forMIME: "audio/mp4"), "m4a")
        XCTAssertEqual(AlarmClipStore.fileExtension(forMIME: "audio/flac"), "flac")
        XCTAssertNil(AlarmClipStore.fileExtension(forMIME: "application/octet-stream"))
    }
}

/// A stream server in the test process: a fixed body, a type, and no length or ranges, the way a
/// transcoding Navidrome answers.
final class StubStream: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var mime = "audio/mpeg"
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var stall = false
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var requiredHeader: (String, String)?

    static func reset() {
        body = Data()
        mime = "audio/mpeg"
        status = 200
        stall = false
        requests = 0
        requiredHeader = nil
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubStream.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        guard !Self.stall, let url = request.url else { return }
        var status = Self.status
        if let (name, value) = Self.requiredHeader, request.value(forHTTPHeaderField: name) != value { status = 403 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": Self.mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 { client?.urlProtocol(self, didLoad: Self.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
