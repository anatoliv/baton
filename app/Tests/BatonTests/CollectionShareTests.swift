import AVFoundation
import BatonShareKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import Baton

/// A stand-in music server on a port nothing listens on, answering `stream` through URLProtocol,
/// which `URLSession.shared` (the app's fetch) consults.
private final class StreamPeer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: (Int, String, Data)] = [:]
    nonisolated(unsafe) static var asked: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "collection-peer.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let format = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "format" }?.value ?? "raw"
        Self.asked.append(format + (request.value(forHTTPHeaderField: "X-Proxy") ?? ""))
        let (status, type, body) = Self.answers[format] ?? (404, "text/plain", Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The collection composer's pieces that need the app (specs/collection-sharing.md):
/// the draft's kind, the planner's view of a song, and fetching one track as M4A.
final class CollectionShareTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        URLProtocol.registerClass(StreamPeer.self)
        StreamPeer.answers = [:]
        StreamPeer.asked = []
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(StreamPeer.self)
        try? FileManager.default.removeItem(at: root)
    }

    private func wav(seconds: Double) throws -> Data {
        let rate = 44_100, frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * 4)
        for frame in 0 ..< frames {
            let sample = Int16(sin(Double(frame) * 2 * .pi * 330 / Double(rate)) * 10_000)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
        }
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var file = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        file += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(2)) + le(UInt32(rate)) + le(UInt32(rate * 4)) + le(UInt16(4)) + le(UInt16(16))
        return file + Data("data".utf8) + le(UInt32(pcm.count)) + pcm
    }

    private func adts(seconds: Double) throws -> Data {
        let input = root.appendingPathComponent("in-\(UUID().uuidString).wav"), output = root.appendingPathComponent("out.aac")
        try wav(seconds: seconds).write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "adts", "-d", "aac", "-b", "128000", input.path, output.path]
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: output) }
        return try Data(contentsOf: output)
    }

    private func server(download: URL? = nil) -> SongSharing.TrackSource {
        .server(aac: URL(string: "https://collection-peer.test/rest/stream.view?id=1&format=aac&maxBitRate=128")!,
                mp3: URL(string: "https://collection-peer.test/rest/stream.view?id=1&format=mp3&maxBitRate=320")!,
                headers: ["X-Proxy": "+header"], download: download, title: "Song One")
    }

    private var staging: URL { root.appendingPathComponent("staging") }

    private func produce(_ source: SongSharing.TrackSource) async throws -> (seconds: Int, file: Data) {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = staging.appendingPathComponent(PreparedBookShare.plaintextName(0))
        let seconds = try await SongSharing.produceTrack(source, bitRate: 128_000, destination: destination)
        return (seconds, try Data(contentsOf: destination))
    }

    /// Everything in the staging folder but the track's own plaintext: nothing, once a track is made.
    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [])
            .filter { $0 != PreparedBookShare.plaintextName(0) }
    }

    private func codec(_ data: Data) async throws -> FourCharCode? {
        let file = root.appendingPathComponent("check-\(UUID().uuidString).m4a")
        try data.write(to: file)
        let track = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio).first
        return try await track?.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
    }

    func testTheDraftSaysWhatTheLinkHolds() {
        XCTAssertEqual(CollectionShareDraft.album(id: "a", name: "Blue", artist: "Joni").kind, .album)
        XCTAssertFalse(CollectionShareDraft.album(id: "a", name: "Blue", artist: "Joni").isReorderable)
        XCTAssertEqual(CollectionShareDraft.playlist(id: "p", name: "Drive").kind, .playlist)
        XCTAssertTrue(CollectionShareDraft.playlist(id: "p", name: "Drive").isReorderable)
        XCTAssertEqual(CollectionShareDraft.selection([]).kind, .playlist, "picked songs go as a playlist")
        XCTAssertTrue(CollectionShareDraft.selection([]).isReorderable)
    }

    func testThePlannerSeesASongAsTheSongAndMixtapePathsWould() {
        let mp3 = NavidromeSong(id: "s1", title: "One", duration: 240, bitRate: 192, suffix: "mp3", size: 5_800_000)
        XCTAssertEqual(SongSharing.collectionTrack(mp3), .init(id: "s1", title: "One", seconds: 240, onServer: true, mp3Bytes: 5_800_000))
        let flac = NavidromeSong(id: "s2", title: "Two", duration: 240, bitRate: 900, suffix: "flac", size: 30_000_000)
        XCTAssertEqual(SongSharing.collectionTrack(flac).mp3Bytes, 240 * 40_000 + 65_536, "transcoded at 320 kbps")
        let local = NavidromeSong(id: "file:///tmp/demo.m4a", title: "Demo", duration: 30)
        XCTAssertFalse(SongSharing.collectionTrack(local).onServer)
    }

    func testAnAACAnswerIsRemuxedAndNothingButTheTrackIsLeft() async throws {
        StreamPeer.answers["aac"] = (200, "audio/aac", try adts(seconds: 3))
        let made = try await produce(server())
        XCTAssertTrue((3 ... 4).contains(made.seconds))
        XCTAssertEqual(ShareCollectionAudio.container(of: made.file), .mp4)
        let written = try await codec(made.file)
        XCTAssertEqual(written, kAudioFormatMPEG4AAC)
        XCTAssertEqual(StreamPeer.asked, ["aac+header"], "asked once, with the proxy headers")
        XCTAssertEqual(leftovers(), [], "the fetched answer is deleted")
    }

    func testAServerWithoutAACTranscodingIsConvertedOnTheDevice() async throws {
        // Navidrome with no aac transcoding answers `format=aac` with the original file.
        StreamPeer.answers["aac"] = (200, "audio/wav", try wav(seconds: 2.5))
        let made = try await produce(server())
        XCTAssertEqual(made.seconds, 3)
        let written = try await codec(made.file)
        XCTAssertEqual(written, kAudioFormatMPEG4AAC)
        XCTAssertLessThan(made.file.count, 80_000, "128 kbps, not the WAV's 440 KB")
        XCTAssertEqual(leftovers(), [])
    }

    func testAnAnswerTheDeviceCannotReadIsAskedForAgainAsMP3() async throws {
        StreamPeer.answers["aac"] = (200, "audio/ogg", Data("OggS not really".utf8))
        // The MP3 answer here is a WAV in disguise; the bytes, not the label, decide how it is opened.
        StreamPeer.answers["mp3"] = (200, "audio/wav", try wav(seconds: 2))
        let made = try await produce(server())
        XCTAssertEqual(StreamPeer.asked, ["aac+header", "mp3+header"])
        XCTAssertEqual(made.seconds, 2)
        XCTAssertEqual(leftovers(), [])
    }

    func testAnUnreachableServerFallsBackToTheOfflineDownload() async throws {
        let download = root.appendingPathComponent("offline.wav")
        try wav(seconds: 2).write(to: download)
        StreamPeer.answers["aac"] = (503, "text/plain", Data())
        let made = try await produce(server(download: download))
        XCTAssertEqual(made.seconds, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path), "the offline copy itself is kept")
        do {
            _ = try await produce(server())
            XCTFail("without a download, a failed fetch refuses")
        } catch let error as SongShareError {
            XCTAssertEqual(error, .fetchFailed)
        }
    }

    func testAFileOnlyOnThisDeviceIsConvertedInPlace() async throws {
        let file = root.appendingPathComponent("local.wav")
        try wav(seconds: 1.5).write(to: file)
        let made = try await produce(.file(file, title: "Local"))
        XCTAssertEqual(made.seconds, 2)
        let written = try await codec(made.file)
        XCTAssertEqual(written, kAudioFormatMPEG4AAC)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let junk = root.appendingPathComponent("junk.mp3")
        try Data("nope".utf8).write(to: junk)
        do {
            _ = try await produce(.file(junk, title: "Junk"))
            XCTFail("junk must refuse")
        } catch {
            XCTAssertTrue(SongShareError(error).errorDescription?.contains("“Junk” couldn't be converted") == true)
        }
    }

    @MainActor
    func testUnfinishedLinksAndFailuresNameWhatTheyAre() {
        XCTAssertEqual(SongSharing.PendingBook(directory: root, title: "A").noun, "Book")
        XCTAssertEqual(SongSharing.PendingBook(directory: root, title: "A", kind: .album).noun, "Album")
        XCTAssertEqual(SongSharing.PendingBook(directory: root, title: "A", kind: .playlist).noun, "Playlist")
        XCTAssertEqual(SongShareError.collection(.chapterTooLarge(chapter: 3)).errorDescription,
                       "Song 3 came out too large for one link. Turn it off to send the rest.")
        XCTAssertEqual(SongShareError.collection(.bookTooLarge).reportReason, "too_large")
        XCTAssertFalse(SongShareError.collection(.noChapters).errorDescription!.contains("chapter"))
    }
}
