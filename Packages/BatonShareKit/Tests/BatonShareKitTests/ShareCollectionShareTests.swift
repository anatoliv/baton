@testable import BatonShareKit
import Foundation
import XCTest

/// Sealing an album or playlist one track at a time (`PreparedBookShare.makeCollection`).
final class ShareCollectionShareTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("staged") }
    private let info = ShareClientInfo(platform: "ios", appVersion: "1.0 (1)")
    private let limits = ShareBookLimits(limits: .standard)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func planned(_ count: Int, seconds: Int = 200) -> [PreparedBookShare.PlannedTrack] {
        (0 ..< count).map { .init(title: "Track \($0 + 1)", artist: $0 == 1 ? "Guest" : "The Band", album: "The Album",
                                  trackNumber: $0 + 1, estimatedSeconds: seconds) }
    }

    /// Plaintext for track `index`: a few kilobytes, different for each track.
    private static func bytes(_ index: Int) -> Data {
        Data((0 ..< (4000 + index * 100)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ index) })
    }

    private let cover = ShareBookManifest.Cover(type: "image/jpeg", bytes: Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 2000))

    private func make(_ tracks: [PreparedBookShare.PlannedTrack], kind: ShareCollectionKind = .album,
                      cover: ShareBookManifest.Cover? = nil, limits: ShareBookLimits? = nil,
                      produce: @escaping PreparedBookShare.TrackProducer) async throws -> PreparedBookShare {
        try await PreparedBookShare.makeCollection(
            kind: kind, tracks: tracks, title: "The Album", artist: "The Band", from: "Ana", note: "For the drive",
            cover: cover, preview: BookPreview(title: "The Album", author: "The Band", from: "Ana", note: "For the drive"),
            expiresInSeconds: 604_800, listenerCap: 10, client: info, limits: limits ?? self.limits,
            directory: directory, produce: produce)
    }

    private func plaintexts() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".plain.m4a") }
    }

    func testTracksAreSealedOneAtATimeAndEachPlaintextIsGoneBeforeTheNext() async throws {
        let seen = Log()
        let book = try await make(planned(3), cover: cover) { index, destination in
            // The folder holds no other plaintext when a track is asked for.
            let others = ((try? FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)) ?? [])
                .filter { $0.hasSuffix(".plain.m4a") }
            seen.append("\(index):\(others.count):\(destination.lastPathComponent)")
            try Self.bytes(index).write(to: destination)
            return 190 + index
        }
        XCTAssertEqual(seen.values, ["0:0:track-0.plain.m4a", "1:0:track-1.plain.m4a", "2:0:track-2.plain.m4a"])
        XCTAssertEqual(plaintexts(), [], "no plaintext is left")
        let manifest = book.manifest
        XCTAssertEqual(manifest.schema, ShareBookManifest.collectionSchemaVersion)
        XCTAssertEqual(manifest.kind, .album)
        XCTAssertEqual(manifest.author, "The Band")
        XCTAssertEqual(manifest.cover, cover)
        XCTAssertEqual(manifest.chapters.map(\.title), ["Track 1", "Track 2", "Track 3"])
        XCTAssertEqual(manifest.chapters.map(\.artist), ["The Band", "Guest", "The Band"])
        XCTAssertEqual(manifest.chapters.map(\.album), ["The Album", "The Album", "The Album"])
        XCTAssertEqual(manifest.chapters.map(\.trackNumber), [1, 2, 3])
        XCTAssertEqual(manifest.chapters.map(\.durationSeconds), [190, 191, 192], "the measured durations, not the library's")
        XCTAssertEqual(manifest.chapters.map(\.audioBytes),
                       (0 ..< 3).map { ShareCrypto.sealedLength(plaintextLength: Self.bytes($0).count) })
        XCTAssertEqual(book.request.kind, .album)
        XCTAssertEqual(book.request.schema, ShareBookManifest.collectionSchemaVersion)
        XCTAssertEqual(book.request.blobs.count, 3)
        XCTAssertTrue(book.request.blobs.values.allSatisfy { $0.role == .audio })
        // Each sealed track opens under its own key to exactly the plaintext produced.
        for (index, chapter) in manifest.chapters.enumerated() {
            let sealed = try Data(contentsOf: book.file(chapter.id))
            XCTAssertEqual(try manifest.openAudio(sealed, chapterID: chapter.id, rootKey: book.key), Self.bytes(index))
        }
    }

    func testTheTicketLoadsForARetryWithTheIdenticalBody() async throws {
        let book = try await make(planned(2), kind: .playlist) { index, destination in
            try Self.bytes(index).write(to: destination); return 200
        }
        let loaded = try PreparedBookShare.load(from: directory)
        XCTAssertEqual(loaded.requestBody, book.requestBody)
        XCTAssertEqual(loaded.key, book.key)
        XCTAssertEqual(loaded.manifest, book.manifest)
        XCTAssertEqual(loaded.manifest.kind, .playlist)
        XCTAssertEqual(loaded.blobs, book.blobs)
        let opened = try ShareBookManifest.open(Data(base64Encoded: loaded.request.encryptedManifest)!, rootKey: loaded.key)
        XCTAssertEqual(opened.kind, .playlist)
        let decoded = try JSONDecoder().decode(CreateBookRequest.self, from: loaded.requestBody)
        XCTAssertEqual(decoded.kind, .playlist)
    }

    func testEveryCapIsCheckedBeforeTheFirstTrackIsFetched() async throws {
        let calls = Log()
        func refused(_ tracks: [PreparedBookShare.PlannedTrack], limits: ShareBookLimits? = nil) async -> PreparedBookShare.Failure? {
            do {
                _ = try await make(tracks, limits: limits) { index, destination in
                    calls.append("\(index)"); try Data([1]).write(to: destination); return 1
                }
                return nil
            } catch { return error as? PreparedBookShare.Failure }
        }
        let r1 = await refused([])
        XCTAssertEqual(r1, .noChapters)
        let r2 = await refused(planned(201, seconds: 10))
        XCTAssertEqual(r2, .tooManyChapters(max: 200))
        // 30 minutes at 128 kbps is past the 25 MiB per-track cap.
        let r3 = await refused(planned(2, seconds: 1800))
        XCTAssertEqual(r3, .chapterTooLarge(chapter: 1))
        var tight = limits
        tight.maxBookBytes = 10_000_000
        let r4 = await refused(planned(3, seconds: 240), limits: tight)
        XCTAssertEqual(r4, .bookTooLarge)
        let r5 = await refused(planned(1, seconds: 0))
        XCTAssertEqual(r5, .chapterTooLong(chapter: 1))
        var short = limits
        short.maxBookSeconds = 300
        let r6 = await refused(planned(2, seconds: 200), limits: short)
        XCTAssertEqual(r6, .tooLong)
        XCTAssertEqual(calls.values, [], "nothing was fetched for a collection that cannot fit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing was staged")
    }

    func testATrackThatLandsTooLargeFailsAndLeavesNothingBehind() async throws {
        var small = limits
        small.maxChapterBytes = 4_000_000 // the estimate for 200 s at 128 kbps (about 3.3 MB) fits
        do {
            _ = try await make(planned(3), limits: small) { index, destination in
                try Data(count: index == 1 ? 4_100_000 : 1000).write(to: destination); return 200
            }
            XCTFail("a track over the cap must refuse")
        } catch let failure as PreparedBookShare.Failure {
            XCTAssertEqual(failure, .chapterTooLarge(chapter: 2))
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(left, [], "no sealed track, plaintext or ticket is left")
    }

    func testAFailingProducerLeavesNothingBehind() async throws {
        struct Offline: Error {}
        do {
            _ = try await make(planned(3)) { index, destination in
                try Data(count: 1000).write(to: destination)
                if index == 2 { throw Offline() }
                return 200
            }
            XCTFail("expected the producer's error")
        } catch is Offline {}
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], [])
    }

    func testACoverThatWouldOverflowTheManifestIsLeftOff() async throws {
        var tight = limits
        tight.maxManifestBytes = 2048 // room for the tracks, not for a 2 KB cover in base64
        let book = try await make(planned(2), cover: cover, limits: tight) { index, destination in
            try Self.bytes(index).write(to: destination); return 200
        }
        XCTAssertNil(book.manifest.cover)
    }

    func testTheBookPathIsUnchanged() throws {
        let audio = root.appendingPathComponent("chapter.m4a")
        try Data(count: 5000).write(to: audio)
        let book = try PreparedBookShare.make(chapters: [.init(audio: audio, title: "One", durationSeconds: 61)], title: "A Book",
                                              author: "Someone", preview: nil, expiresInSeconds: 604_800, listenerCap: 10,
                                              client: info, limits: limits, directory: directory)
        XCTAssertNil(book.request.kind)
        XCTAssertEqual(book.request.schema, ShareBookManifest.schemaVersion)
        XCTAssertNil(book.manifest.chapters[0].artist)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "a book's own chapter file is never deleted")
    }
}

/// A small thread-safe log for producers, which run off the test's own task.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [String]()
    func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
