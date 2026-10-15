import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// A book narrated on this Mac (M3.1): the shared render loop with the Mac's encoder, and each
/// finished chapter moved into Clippings as a chapter of the book.
///
/// The synthesizer is a fake that counts its calls, so "a quit resumes and synthesizes nothing
/// twice" and "a host outage pauses, never switches voice" are asserted rather than hoped for.
/// The encoder is the real one: a chapter that does not decode is the failure that matters.
@MainActor
final class DocumentLibraryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-books-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Answers every request with a fifth of a second of 24 kHz mono silence, or fails while
    /// `down` is set, and counts what it was asked for.
    actor FakeKokoro: SpeechSynthesizing {
        private(set) var calls = 0
        private(set) var voices: Set<String> = []
        var down = false

        func setDown(_ value: Bool) { down = value }

        func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
            if down { throw SynthesisError.transient("kokoro did not answer: connection refused") }
            calls += 1
            voices.insert(voice)
            let pcm = Data(count: 24_000 / 5 * 2)
            return WAV.header(format: .init(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16),
                              dataBytes: pcm.count) + pcm
        }
    }

    private func book() throws -> PreparedBook {
        let url = root.appendingPathComponent("two-rooms.md")
        try """
        # Two Rooms

        ## The Cell

        Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee. It is lighted \
        neither by window nor by lamp, yet it is filled with a soft radiance.

        An electric bell rang. The woman touched a switch and the music was silent.

        ## The Surface

        He went up to the surface. The stairway was long, and the light at the top was grey.
        """.write(to: url, atomically: true, encoding: .utf8)
        let document = try DocumentImporter.importFile(at: url)
        return DocumentSpeech.prepare(document, voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    private func library(_ kokoro: FakeKokoro, clippings: ClippingStore) -> DocumentLibrary {
        DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                        synthesizer: kokoro, retry: .init(initialDelay: 0.02, maximumDelay: 0.05),
                        refreshInterval: .milliseconds(50))
    }

    private func clippingStore() -> ClippingStore {
        ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("documents"))
    }

    /// Wait for a condition the render loop reaches on its own, refreshing as the UI would.
    private func eventually(_ library: DocumentLibrary, timeout: TimeInterval = 20,
                            _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            library.refresh()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out")
    }

    func testEveryChapterLandsInClippingsAsAChapterOfTheBook() async throws {
        let kokoro = FakeKokoro()
        let clippings = clippingStore()
        let library = library(kokoro, clippings: clippings)
        library.start(force: true)
        let book = try book()
        XCTAssertGreaterThanOrEqual(book.chapters.count, 2)

        try await library.submit(book)
        try await eventually(library) { clippings.chapters(ofDocument: book.documentID).count == book.chapters.count }

        let chapters = clippings.chapters(ofDocument: book.documentID)
        XCTAssertEqual(chapters.map(\.clipping.chapterIndex), Array(0..<book.chapters.count))
        XCTAssertEqual(chapters.map(\.clipping.title), book.chapters.map(\.title))
        for item in chapters {
            XCTAssertTrue(item.isPresent)
            XCTAssertEqual(item.url.pathExtension, "m4a")
            XCTAssertEqual(item.asSong.album, book.title)
            XCTAssertNotNil(item.clipping.sha256)
            XCTAssertGreaterThan(item.clipping.durationSeconds ?? 0, 0)
            XCTAssertFalse(item.clipping.text?.isEmpty ?? true, "the chapter's words come with it, for the transcript")
        }
        let calls = await kokoro.calls
        XCTAssertEqual(calls, book.segmentCount, "one request per chunk, none twice")
        let voices = await kokoro.voices
        XCTAssertEqual(voices, ["kokoro:bf_emma"])

        // Moved, not copied: the job keeps its record and no second copy of the audio.
        let jobDir = try XCTUnwrap(library.store.jobDirectory(BookJob.id(for: book)))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: jobDir.path).filter { $0.hasSuffix(".m4a") }
        XCTAssertEqual(leftovers, [])
        XCTAssertEqual(library.jobs.first?.summary.status, .ready)
    }

    /// The walk's "quit during chapter 2, relaunch": a second library over the same directory
    /// resumes and asks Kokoro for nothing it already has.
    func testARelaunchResumesWithoutSynthesizingAnythingTwice() async throws {
        let clippings = clippingStore()
        let first = FakeKokoro()
        let library = library(first, clippings: clippings)
        library.start(force: true)
        let book = try book()
        try await library.submit(book)
        try await eventually(library) { clippings.chapters(ofDocument: book.documentID).count == book.chapters.count }
        let firstCalls = await first.calls

        let second = FakeKokoro()
        let relaunched = self.library(second, clippings: clippings)
        relaunched.start(force: true)
        let id = try await relaunched.submit(book)
        try await eventually(relaunched) { relaunched.jobs.first { $0.id == id }?.summary.status == .ready }
        let secondCalls = await second.calls
        XCTAssertEqual(firstCalls, book.segmentCount)
        XCTAssertEqual(secondCalls, 0, "a relaunch must not synthesize a chunk that is already cached")
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, book.chapters.count,
                       "and must not adopt a chapter twice")
    }

    /// Kokoro stops answering: the book says paused, with the reason, and finishes in the same
    /// voice once it is back. Never in the built-in voice.
    func testAnOutagePausesWithTheReasonAndResumesInTheSameVoice() async throws {
        let kokoro = FakeKokoro()
        await kokoro.setDown(true)
        let clippings = clippingStore()
        let library = library(kokoro, clippings: clippings)
        library.start(force: true)
        let book = try book()
        let id = try await library.submit(book)

        try await eventually(library) { library.jobs.first { $0.id == id }?.summary.status == .paused }
        let paused = try XCTUnwrap(library.jobs.first { $0.id == id }?.summary)
        // The listener's words in the reason, the engine's own in the detail (board F2).
        XCTAssertEqual(paused.pauseReason, "the voice server isn't answering")
        XCTAssertTrue(paused.pauseDetail?.contains("did not answer") ?? false, paused.pauseDetail ?? "no detail")
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, 0)

        await kokoro.setDown(false)
        try await eventually(library) { clippings.chapters(ofDocument: book.documentID).count == book.chapters.count }
        let voices = await kokoro.voices
        XCTAssertEqual(voices, ["kokoro:bf_emma"])
        XCTAssertNil(library.jobs.first { $0.id == id }?.summary.pauseReason)
    }

    func testOffByDefault() {
        let defaults = ThrowawayDefaults.make("documents")
        XCTAssertFalse(DocumentLibrary.isEnabled(in: defaults), "behind baton.documents.enabled, which defaults to off")
        defaults.set(true, forKey: DocumentLibrary.enabledKey)
        XCTAssertTrue(DocumentLibrary.isEnabled(in: defaults))
    }
}

/// The Mac's encoder against a WAV of known length: duration, bitrate and the tags the player
/// shows.
final class AVAssetWriterMuxerTests: XCTestCase {

    func testEncodesTaggedAACAtTheBooksBitrate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-mux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Three seconds of deterministic noise, 24 kHz mono 16-bit, as Kokoro answers. Noise, not
        // a tone: a pure tone is so compressible that average-bitrate AAC spends about 27 kbps
        // of a 48 kbps budget on it, which says nothing about the setting.
        var pcm = Data()
        var state: UInt32 = 0x2545F491
        for _ in 0..<(24_000 * 3) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let sample = Int16(truncatingIfNeeded: Int32(bitPattern: state) >> 18)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let wav = dir.appendingPathComponent("chapter-2.wav")
        try (WAV.header(format: .init(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16),
                        dataBytes: pcm.count) + pcm).write(to: wav)
        let m4a = dir.appendingPathComponent("chapter-2.m4a")

        try await AVAssetWriterMuxer().encode(wav: wav, to: m4a, bitrate: 48_000, channels: 1, tags: [
            "title": "The Mending Apparatus", "album": "The Machine Stops", "artist": "E. M. Forster",
            "track": "2/3", "genre": "Audiobook",
        ])

        let asset = AVURLAsset(url: m4a)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.15)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let rate = try await track.load(.estimatedDataRate)
        XCTAssertEqual(Double(rate), 48_000, accuracy: 12_000, "AAC at the book's bitrate")
        let format = try await track.load(.formatDescriptions).first
        XCTAssertEqual(format.map { CMFormatDescriptionGetMediaSubType($0) }, kAudioFormatMPEG4AAC)

        let common = try await asset.load(.commonMetadata)
        func string(_ key: AVMetadataKey) async throws -> String? {
            guard let item = AVMetadataItem.metadataItems(from: common, withKey: key, keySpace: .common).first else { return nil }
            return try await item.load(.stringValue)
        }
        let title = try await string(.commonKeyTitle)
        let album = try await string(.commonKeyAlbumName)
        let artist = try await string(.commonKeyArtist)
        XCTAssertEqual(title, "The Mending Apparatus")
        XCTAssertEqual(album, "The Machine Stops")
        XCTAssertEqual(artist, "E. M. Forster")
        let all = try await asset.load(.metadata)
        let track2 = AVMetadataItem.metadataItems(from: all, filteredByIdentifier: .iTunesMetadataTrackNumber).first
        let trackData = try await track2?.load(.dataValue)
        XCTAssertEqual(trackData.map { [UInt8]($0) }, [0, 0, 0, 2, 0, 3, 0, 0])

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("partial") }
        XCTAssertEqual(leftovers, [], "the temporary file is moved into place, not left beside it")
    }
}

/// M5.6: a book made on the home server. The gateway is a fake that answers the real routes with
/// the real summary JSON, so the Mac's side (submit, remember, collect each ready chapter once,
/// cancel there) is tested against the wire format the deployed gateway speaks.
@MainActor
final class DocumentLibraryHomeServerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The home server: books it holds, how many chapters of each are ready, every request seen.
    final class FakeGateway: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [String: BookJob] = [:]
        private var readyCount: [String: Int] = [:]
        private(set) var requests: [String] = []
        let audio = Data(repeating: 0x41, count: 4_096)

        func setReady(_ id: String, _ count: Int) { lock.withLock { readyCount[id] = count } }
        var seen: [String] { lock.withLock { requests } }

        func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            lock.withLock {
                let method = request.httpMethod ?? "GET"
                let path = request.url!.path
                requests.append("\(method) \(path)")
                func reply(_ status: Int, _ body: Data, _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
                    (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
                }
                let parts = path.split(separator: "/").map(String.init)   // v1 books {id} ...
                if method == "GET", parts == ["v1", "books"] {
                    return reply(200, Data(#"{"available":true,"books":[],"used_bytes":0,"maximum_bytes":4294967296,"keep_finished_days":30}"#.utf8))
                }
                guard parts.count >= 3 else { return reply(404, Data()) }
                let id = parts[2]
                if method == "PUT" {
                    let book = try! PreparedBook.decode(request.httpBody ?? Data())
                    jobs[id] = BookJob(id: id, book: book)
                    return reply(201, try! BookJSON.encoder.encode(jobs[id]!.summary))
                }
                guard var job = jobs[id] else { return reply(404, Data()) }
                if method == "DELETE" { jobs[id] = nil; return reply(204, Data()) }
                if method == "POST" { return reply(204, Data()) }
                if parts.count == 5, parts[3] == "chapters", let n = Int(parts[4]) {
                    return reply(200, audio, ["X-Baton-SHA256": SHA256Digest.hex(of: audio), "X-Baton-Duration": "60.0",
                                              "X-Baton-Name": "chapter \(n)"])
                }
                let ready = readyCount[id] ?? 0
                for i in job.chapters.indices {
                    job.chapters[i] = i < ready ? .ready(file: "chapter-\(i + 1).m4a", bytes: audio.count, seconds: 60,
                                                         sha256: SHA256Digest.hex(of: audio))
                                                : (i == ready ? .rendering(done: 1, of: 4) : .queued)
                }
                job.status = ready >= job.chapters.count ? .ready : .rendering
                return reply(200, try! BookJSON.encoder.encode(job.summary))
            }
        }
    }

    private func book() throws -> PreparedBook {
        let url = root.appendingPathComponent("two-rooms.md")
        try "# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee.\n\n## The Surface\n\nThe light at the top was grey."
            .write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    private func library(_ fake: FakeGateway, clippings: ClippingStore) -> DocumentLibrary {
        DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                        synthesizer: DocumentLibraryTests.FakeKokoro(),
                        gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
    }

    func testABookMadeOnTheHomeServerIsCollectedChapterByChapterOnce() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let library = library(fake, clippings: clippings)
        let available = await library.homeServerAvailable()
        XCTAssertTrue(available)

        let book = try book()
        let id = try await library.submit(book, on: .homeServer)
        XCTAssertTrue(fake.seen.contains("PUT /v1/books/\(id)"))
        XCTAssertEqual(library.jobs.first?.renderer, .homeServer)
        XCTAssertEqual(library.remoteBooks.map(\.documentID), [book.documentID])

        fake.setReady(id, 1)
        await library.refreshHomeServer()
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).map(\.clipping.chapterIndex), [0])
        let first = try XCTUnwrap(clippings.chapters(ofDocument: book.documentID).first)
        XCTAssertEqual(first.clipping.sha256, SHA256Digest.hex(of: fake.audio))
        XCTAssertEqual(first.clipping.durationSeconds, 60)
        XCTAssertEqual(first.asSong.album, book.title)

        fake.setReady(id, book.chapters.count)
        await library.refreshHomeServer()
        await library.refreshHomeServer()
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, book.chapters.count)
        let downloads = fake.seen.filter { $0.contains("/chapters/") }
        XCTAssertEqual(downloads.count, book.chapters.count, "each chapter fetched exactly once: \(downloads)")

        let shelf = BookShelf.entries(items: clippings.items, jobs: library.jobs, ledger: clippings.ledger)
        guard case let .book(row)? = shelf.first else { return XCTFail("no book row") }
        XCTAssertEqual(row.madeOn, .homeServer)
        XCTAssertEqual(row.storedText, "On this Mac", "every chapter has come down")
    }

    func testTheRecordSurvivesARelaunchAndCancellingDeletesItOnTheServer() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let book = try book()
        let id = try await library(fake, clippings: clippings).submit(book, on: .homeServer)

        let relaunched = library(fake, clippings: clippings)
        XCTAssertEqual(relaunched.remoteBooks.map(\.jobID), [id])
        await relaunched.refreshHomeServer()
        XCTAssertEqual(relaunched.jobs.first?.id, id)
        let shelf = BookShelf.entries(items: clippings.items, jobs: relaunched.jobs, ledger: clippings.ledger)
        guard case let .book(row)? = shelf.first else { return XCTFail("no book row") }
        XCTAssertEqual(row.storedText, "On the home server")

        await relaunched.cancel(id)
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(id)"))
        XCTAssertEqual(relaunched.remoteBooks, [])
    }

    func testWithNoGatewayConfiguredTheHomeServerIsNotOffered() async {
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: DocumentLibraryTests.FakeKokoro(), gateway: { nil })
        let available = await library.homeServerAvailable()
        XCTAssertFalse(available)
    }
}
