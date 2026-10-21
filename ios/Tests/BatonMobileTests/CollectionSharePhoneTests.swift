import AVFoundation
@testable import BatonMobile
import BatonShareKit
import BatonSubsonicModels
import Foundation
import XCTest

/// A stand-in music server answering `stream` through URLProtocol, which `URLSession.shared` consults.
private final class PhoneStreamPeer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: (Int, String, Data)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "collection-peer.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let format = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "format" }?.value ?? "raw"
        let (status, type, body) = Self.answers[format] ?? (404, "text/plain", Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                             headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The iPhone's half of collection sharing: the same composer pieces, and a
/// track converted to AAC in M4A by the phone's own AVFoundation.
final class CollectionSharePhoneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-phone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        URLProtocol.registerClass(PhoneStreamPeer.self)
        PhoneStreamPeer.answers = [:]
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(PhoneStreamPeer.self)
        try? FileManager.default.removeItem(at: root)
    }

    private func wav(seconds: Double) -> Data {
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

    func testTheDraftSaysWhatTheLinkHolds() {
        XCTAssertEqual(CollectionShareDraft.album(id: "a", name: "Blue", artist: "Joni").kind, .album)
        XCTAssertFalse(CollectionShareDraft.album(id: "a", name: "Blue", artist: "Joni").isReorderable)
        XCTAssertEqual(CollectionShareDraft.selection([]).kind, .playlist)
        XCTAssertFalse(SongSharing.collectionTrack(NavidromeSong(id: "file:///x.m4a", title: "X", duration: 3)).onServer)
    }

    func testAServerAnswerThatIsNotAACIsConvertedOnThePhone() async throws {
        PhoneStreamPeer.answers["aac"] = (200, "audio/wav", wav(seconds: 2.5))
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = staging.appendingPathComponent(PreparedBookShare.plaintextName(0))
        let source = SongSharing.TrackSource.server(
            aac: URL(string: "https://collection-peer.test/rest/stream.view?id=1&format=aac")!,
            mp3: URL(string: "https://collection-peer.test/rest/stream.view?id=1&format=mp3")!,
            headers: [:], download: nil, title: "One")
        let seconds = try await SongSharing.produceTrack(source, bitRate: 128_000, destination: destination)
        XCTAssertEqual(seconds, 3)
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(ShareCollectionAudio.container(of: data), .mp4)
        let track = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).first
        let codec = try await track?.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        XCTAssertEqual(codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [PreparedBookShare.plaintextName(0)],
                       "only the track's own M4A is left for the sealer")
    }
}
