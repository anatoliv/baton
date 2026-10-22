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

    /// TBX-10960: a chapter made on this Mac goes into Clippings with its read-along timing, by
    /// the audio's digest, and the timing fits the chapter's audio and words.
    func testAChapterMadeHereKeepsItsReadAlongTiming() async throws {
        let clippings = clippingStore()
        let library = library(FakeKokoro(), clippings: clippings)
        library.start(force: true)
        let book = try book()
        try await library.submit(book)
        try await eventually(library) { clippings.chapters(ofDocument: book.documentID).count == book.chapters.count }

        for item in clippings.chapters(ofDocument: book.documentID) {
            let index = try XCTUnwrap(item.clipping.chapterIndex)
            let timing = try XCTUnwrap(library.homeServer.readAlong.load(forAudio: item.clipping.sha256),
                                       "chapter \(index + 1) has its timing")
            XCTAssertEqual(timing.segments.map(\.text), book.chapters[index].segments.map(\.text))
            XCTAssertEqual(try XCTUnwrap(timing.segments.last).end, try XCTUnwrap(item.clipping.durationSeconds), accuracy: 0.05)
            let shown = await library.readAlongTiming(for: item)
            XCTAssertEqual(shown, timing)
            let along = ReadAlong(timing: shown, fallbackText: item.clipping.text)
            XCTAssertTrue(along.isTimed)
            XCTAssertEqual(along.sentenceIndex(at: along.seekTarget(for: along.sentences.count - 1)!), along.sentences.count - 1)
        }
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
        /// Each job's chapters sound different, as a book in another voice does.
        /// Off by default, so every other test sees the one audio it always did.
        var audioByJob = false
        func chapterAudio(for jobID: String) -> Data {
            audioByJob ? Data(String(repeating: String(jobID.prefix(12)), count: 64).utf8) : audio
        }

        /// The home server answers every DELETE with a 503, as when its disk is unavailable.
        private var _failDeletes = false
        var failDeletes: Bool {
            get { lock.withLock { _failDeletes } }
            set { lock.withLock { _failDeletes = newValue } }
        }

        /// The home server answers every PUT with a 503, as when it is away.
        private var _failPuts = false
        var failPuts: Bool {
            get { lock.withLock { _failPuts } }
            set { lock.withLock { _failPuts = newValue } }
        }

        /// The books submitted, by job id, as the home server received them.
        func submitted(_ id: String) -> PreparedBook? { lock.withLock { jobs[id]?.book } }

        func setReady(_ id: String, _ count: Int) { lock.withLock { readyCount[id] = count } }

        /// A book another device sent: on the home server, never submitted from here.
        @discardableResult
        func add(_ book: PreparedBook, ready: Int = 0) -> String {
            let id = BookJob.id(for: book)
            lock.withLock {
                jobs[id] = BookJob(id: id, book: book)
                readyCount[id] = ready
            }
            return id
        }

        /// Books that failed for good on the home server.
        private var failed: Set<String> = []
        func fail(_ id: String) { lock.withLock { _ = failed.insert(id) } }

        /// The job as the home server reports it now: chapters ready up to `readyCount`.
        private func current(_ job: BookJob) -> BookJob {
            var job = job
            let ready = readyCount[job.id] ?? 0
            for i in job.chapters.indices {
                let audio = chapterAudio(for: job.id)
                job.chapters[i] = i < ready ? .ready(file: "chapter-\(i + 1).m4a", bytes: audio.count, seconds: 60,
                                                     sha256: SHA256Digest.hex(of: audio))
                                            : (i == ready ? .rendering(done: 1, of: 4) : .queued)
            }
            job.status = failed.contains(job.id) ? .failed : (ready >= job.chapters.count ? .ready : .rendering)
            return job
        }
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
                    // As `BookRoutes.list`: every book's summary, newest first.
                    let books = jobs.values.sorted { $0.createdAt > $1.createdAt }.map { job in
                        try! JSONSerialization.jsonObject(with: BookJSON.encoder.encode(current(job).summary))
                    }
                    let body: [String: Any] = ["available": true, "books": books, "used_bytes": 0,
                                               "maximum_bytes": 4_294_967_296, "keep_finished_days": 30]
                    return reply(200, try! JSONSerialization.data(withJSONObject: body))
                }
                guard parts.count >= 3 else { return reply(404, Data()) }
                let id = parts[2]
                if method == "DELETE", _failDeletes { return reply(503, Data("unavailable".utf8)) }
                if method == "PUT" {
                    if _failPuts { return reply(503, Data("unavailable".utf8)) }
                    // A chapter's audio or its read-along timing, as MacBookUploads sends them after
                    // `PUT /v1/books/{id}/upload` for a book made on this Mac. Only `/v1/books/{id}` and
                    // its `/upload` carry a whole book; decoding a chapter as one trapped the test host
                    // whenever an upload landed before its test ended.
                    if parts.count > 3, parts[3] == "chapters" {
                        guard let job = jobs[id] else { return reply(404, Data()) }
                        return reply(200, try! BookJSON.encoder.encode(current(job).summary))
                    }
                    let book = try! PreparedBook.decode(request.httpBody ?? Data())
                    // As `BookRoutes.handleUpload` does: the id is the book's content.
                    guard BookJob.id(for: book) == id else { return reply(400, Data("book id does not match its content".utf8)) }
                    jobs[id] = BookJob(id: id, book: book)
                    return reply(201, try! BookJSON.encoder.encode(jobs[id]!.summary))
                }
                guard let job = jobs[id] else { return reply(404, Data()) }
                if method == "DELETE" { jobs[id] = nil; return reply(204, Data()) }
                if method == "POST" { return reply(204, Data()) }
                if parts.count == 4, parts[3] == "book" { return reply(200, try! job.book.encoded()) }
                // Read-along timing for chapter 1 only: chapter 2 answers as a
                // chapter made before timing was kept, or a gateway older than the route.
                if parts.count == 6, parts[3] == "chapters", parts[5] == "timing", let n = Int(parts[4]) {
                    guard n == 1, let segments = job.book.chapters.first?.segments else {
                        return reply(404, Data(#"{"error":"no timing for this chapter"}"#.utf8))
                    }
                    let timing = ReadAlongTiming(segments: segments.enumerated().map { i, segment in
                        .init(text: segment.text, paragraph: segment.paragraph, start: Double(i), end: Double(i) + 0.5)
                    })
                    return reply(200, try! timing.encoded())
                }
                if parts.count == 5, parts[3] == "chapters", let n = Int(parts[4]) {
                    let audio = chapterAudio(for: id)
                    return reply(200, audio, ["X-Baton-SHA256": SHA256Digest.hex(of: audio), "X-Baton-Duration": "60.0",
                                              "X-Baton-Name": "chapter \(n)"])
                }
                return reply(200, try! BookJSON.encoder.encode(current(job).summary))
            }
        }
    }

    private func book() throws -> PreparedBook {
        let url = root.appendingPathComponent("two-rooms.md")
        try "# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee.\n\n## The Surface\n\nThe light at the top was grey."
            .write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    private func library(_ fake: FakeGateway, clippings: ClippingStore,
                         storageDefaults: UserDefaults = ThrowawayDefaults.make("home-storage")) -> DocumentLibrary {
        DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                        synthesizer: DocumentLibraryTests.FakeKokoro(), storageDefaults: storageDefaults,
                        gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
    }

    /// TBX-1000000570: the fake takes a book made on this Mac as the home server does: the whole
    /// book through `/upload`, then each chapter's audio and its read-along timing, which it must
    /// not read as a whole book. A Mac-made book sends them in the background, and one that landed
    /// before its test ended used to trap the test host.
    func testTheFakeHomeServerTakesAMacMadeBookThenItsChaptersAudioAndTiming() throws {
        let fake = FakeGateway()
        let book = try book()
        let id = BookJob.id(for: book)
        func put(_ path: String, _ body: Data) -> Int {
            var request = URLRequest(url: URL(string: "http://gateway.test:8788/v1/books/\(id)/\(path)")!)
            request.httpMethod = "PUT"
            request.httpBody = body
            return fake.answer(request).1.statusCode
        }
        XCTAssertEqual(put("upload", try book.encoded()), 201)
        XCTAssertNotNil(fake.submitted(id), "the upload put the book on the fake home server")
        XCTAssertEqual(put("chapters/1", Data(repeating: 0x41, count: 64)), 200)
        XCTAssertEqual(put("chapters/1/timing", Data(#"{"segments":[]}"#.utf8)), 200)
        XCTAssertEqual(fake.seen, ["PUT /v1/books/\(id)/upload", "PUT /v1/books/\(id)/chapters/1",
                                   "PUT /v1/books/\(id)/chapters/1/timing"])
    }

    /// TBX-10954: after a relaunch, a book made on the home server counts as removable only once
    /// the home server has answered about it, which can be after Clippings first asks for the
    /// weekly suggestion. Asking that early makes none and leaves the week unspent, and
    /// `removableBookIDs`, which Clippings watches, changes when the answer lands, so asking
    /// again then offers it.
    func testAFinishedHomeServerBookIsSuggestedOnceTheHomeServerAnswersAfterARelaunch() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let book = try book()
        let first = library(fake, clippings: clippings)
        let id = try await first.submit(book, on: .homeServer)
        fake.setReady(id, book.chapters.count)
        await first.refreshHomeServer()
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, book.chapters.count)
        var ledger = clippings.ledger
        ledger.setFinished(true, documentID: book.documentID, at: Date().addingTimeInterval(-9 * StoragePolicy.day))
        clippings.ledger = ledger

        let storage = ThrowawayDefaults.make("home-storage-relaunch")
        let relaunched = library(fake, clippings: clippings, storageDefaults: storage)
        XCTAssertEqual(relaunched.removableBookIDs, [], "the home server has not answered since the relaunch")
        XCTAssertNil(relaunched.cleanup.suggestion(for: relaunched.storedBooks, freeBytes: nil))
        XCTAssertNil(relaunched.cleanup.settings.lastSuggestedAt, "asking too early does not spend the week")

        await relaunched.refreshHomeServer()
        XCTAssertEqual(relaunched.removableBookIDs, [book.documentID])
        let offered = try XCTUnwrap(relaunched.cleanup.suggestion(for: relaunched.storedBooks, freeBytes: nil))
        XCTAssertEqual(offered.kind, .finishedBook)
        XCTAssertEqual(offered.ids, [book.documentID])
        XCTAssertEqual(relaunched.cleanup.suggestion(for: relaunched.storedBooks, freeBytes: nil), offered,
                       "asking again returns the same suggestion rather than a new one")
    }

    /// TBX-10959: the storage rules run in `start()`, before the home server has answered after a
    /// relaunch, when a book made there has no job and so looks unable to come back. They run
    /// again once the answer arrives, so a book finished 8 days ago under "After 7 days" loses its
    /// download then rather than at the next time something applies the rules.
    func testAStorageRuleRemovesAHomeServerBookOnceTheHomeServerAnswersAfterARelaunch() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let book = try book()
        let first = library(fake, clippings: clippings)
        let id = try await first.submit(book, on: .homeServer)
        fake.setReady(id, book.chapters.count)
        await first.refreshHomeServer()
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, book.chapters.count)
        var ledger = clippings.ledger
        ledger.setFinished(true, documentID: book.documentID, at: Date().addingTimeInterval(-8 * StoragePolicy.day))
        clippings.ledger = ledger

        let relaunched = library(fake, clippings: clippings, storageDefaults: ThrowawayDefaults.make("home-storage-rules"))
        relaunched.cleanup.setRules(.init(afterFinished: 7 * StoragePolicy.day))
        relaunched.start(force: true)
        defer { relaunched.stop() }
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, book.chapters.count,
                       "at start the home server has not answered, so the book cannot come back yet")

        let deadline = Date().addingTimeInterval(20)
        while !clippings.chapters(ofDocument: book.documentID).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID), [], "the rule ran once the home server answered")
        XCTAssertEqual(relaunched.cleanup.removed.first?.automatic, true)
        XCTAssertTrue(try XCTUnwrap(relaunched.shelf.first).isOffloaded)
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
        let downloads = fake.seen.filter { $0.contains("/chapters/") && !$0.hasSuffix("/timing") }
        XCTAssertEqual(downloads.count, book.chapters.count, "each chapter fetched exactly once: \(downloads)")

        let shelf = BookShelf.entries(items: clippings.items, jobs: library.jobs, ledger: clippings.ledger)
        guard case let .book(row)? = shelf.first else { return XCTFail("no book row") }
        XCTAssertEqual(row.madeOn, .homeServer)
        XCTAssertEqual(row.storedText, "On this Mac", "every chapter has come down")
    }

    /// TBX-10960: a chapter's read-along timing comes down with it when the home server kept
    /// one, and a 404 (an older gateway, an older chapter) leaves the chapter collected without.
    func testAHomeServerChapterBringsItsReadAlongTimingWhenThereIsOne() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let library = library(fake, clippings: clippings)
        let book = try book()
        let id = try await library.submit(book, on: .homeServer)
        fake.setReady(id, book.chapters.count)
        await library.refreshHomeServer()

        let chapters = clippings.chapters(ofDocument: book.documentID)
        XCTAssertEqual(chapters.count, book.chapters.count, "a missing timing never holds a chapter back")
        XCTAssertTrue(fake.seen.contains("GET /v1/books/\(id)/chapters/1/timing"))
        XCTAssertTrue(fake.seen.contains("GET /v1/books/\(id)/chapters/2/timing"))
        let first = try XCTUnwrap(chapters.first)
        let timing = try XCTUnwrap(library.homeServer.readAlong.load(forAudio: first.clipping.sha256))
        XCTAssertEqual(timing.segments.map(\.text), book.chapters[0].segments.map(\.text))
        let shown = await library.readAlongTiming(for: first)
        XCTAssertEqual(shown, timing)
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
        XCTAssertEqual(row.storedText, "On the Baton server")

        await relaunched.cancel(id)
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(id)"))
        XCTAssertEqual(relaunched.remoteBooks, [])
    }

    /// Cancelled while the home server cannot delete: gone from the shelf at once, deleted
    /// there by the next refresh after a relaunch, then forgotten.
    func testACancelThatFailsIsDeletedOnALaterRefresh() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let first = library(fake, clippings: clippings)
        let id = try await first.submit(try book(), on: .homeServer)

        fake.failDeletes = true
        await first.cancel(id)
        XCTAssertEqual(first.remoteBooks, [])
        XCTAssertEqual(first.homeServer.pendingDeleteIDs, [id])

        fake.failDeletes = false
        let relaunched = library(fake, clippings: clippings)
        await relaunched.refreshHomeServer()
        XCTAssertEqual(relaunched.homeServer.pendingDeleteIDs, [])
        XCTAssertEqual(fake.seen.filter { $0 == "DELETE /v1/books/\(id)" }.count, 2)
        XCTAssertEqual(relaunched.remoteBooks, [])
    }

    // MARK: - A book the iPhone sent

    private func phoneBook(narrator: String = "kokoro:af_heart") throws -> PreparedBook {
        let url = root.appendingPathComponent("the-ferry.md")
        try "# The Ferry\n\n## Morning\n\nThe ferry left at dawn.\n\n## Evening\n\nIt came back under the lamps."
            .write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: narrator))
    }

    /// The reverse of TBX-10974's literal path: a book the iPhone sent to the home server is a
    /// row in this Mac's Clippings, made on the home server, under the iPhone's job, its
    /// chapters collected with their words and its place shared by document id.
    func testABookTheIPhoneSentIsAdoptedAndCollectedWithoutResubmittingIt() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let library = library(fake, clippings: clippings)
        let phone = try phoneBook()
        let id = fake.add(phone, ready: 2)

        await library.refreshHomeServer()
        XCTAssertFalse(fake.seen.contains { $0.hasPrefix("PUT") }, "adopting must not send the book again: \(fake.seen)")
        let job = try XCTUnwrap(library.jobs.first)
        XCTAssertEqual(job.id, id, "the iPhone's job id, unchanged")
        XCTAssertEqual(job.renderer, .homeServer)
        XCTAssertTrue(job.adopted)
        XCTAssertEqual(clippings.chapters(ofDocument: phone.documentID).count, 2)
        XCTAssertTrue(clippings.chapters(ofDocument: phone.documentID).first?.clipping.text?.contains("The ferry left at dawn.") == true)

        // The iPhone stopped in chapter 2 at 0:10; the shared ledger brings it.
        var ledger = clippings.ledger
        ledger.setPosition(documentID: phone.documentID, chapterIndex: 1, seconds: 10)
        clippings.ledger = ledger
        guard case let .book(row)? = BookShelf.entries(items: clippings.items, jobs: library.jobs, ledger: clippings.ledger).first
        else { return XCTFail("no book row") }
        XCTAssertEqual(row.title, "The Ferry")
        XCTAssertEqual(row.originText, "Made on the Baton server")
        XCTAssertEqual(row.storedText, "On this Mac")
        XCTAssertEqual(row.position?.chapterIndex, 1)
        XCTAssertEqual(row.position?.seconds, 10)

        // Finished on this Mac: the home server hears it under the iPhone's job.
        await library.markFinished(documentID: phone.documentID)
        XCTAssertTrue(fake.seen.contains("POST /v1/books/\(id)/finished"), "\(fake.seen)")

        await library.refreshHomeServer()
        XCTAssertEqual(fake.seen.filter { $0 == "GET /v1/books/\(id)/book" }.count, 1, "the shaped book comes down once")
        XCTAssertEqual(library.jobs.count, 1)
    }

    /// Remove from This Mac leaves the iPhone's book on the home server and keeps it hidden here;
    /// Delete Everywhere deletes it there.
    func testRemovingFromThisMacHidesItAndDeleteEverywhereDeletesItOnTheServer() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let library = library(fake, clippings: clippings)
        let phone = try phoneBook()
        let id = fake.add(phone, ready: 2)
        await library.refreshHomeServer()
        var book = try XCTUnwrap(library.shelf.first)

        await library.deleteBook(book, everywhere: false)
        XCTAssertFalse(fake.seen.contains("DELETE /v1/books/\(id)"), "the iPhone keeps it")
        XCTAssertEqual(library.homeServer.hiddenDocumentIDs, [phone.documentID])
        let relaunched = self.library(fake, clippings: clippings)
        await relaunched.refreshHomeServer()
        XCTAssertEqual(relaunched.remoteBooks, [], "not adopted again")
        XCTAssertTrue(relaunched.shelf.isEmpty)

        // Restored, it is this Mac's again, and Delete Everywhere then deletes it on the server.
        try relaunched.restore(try XCTUnwrap(relaunched.cleanup.removed.first))
        await relaunched.refreshHomeServer()
        XCTAssertEqual(relaunched.remoteBooks.map(\.jobID), [id])
        book = try XCTUnwrap(relaunched.shelf.first)
        await relaunched.deleteBook(book, everywhere: true)
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(id)"))
        await relaunched.refreshHomeServer()
        XCTAssertEqual(relaunched.remoteBooks, [])
    }

    /// A failed book is not adopted, nor a second copy of a book this Mac makes itself (the
    /// iPhone sent the same document in another voice).
    func testAFailedBookAndASecondCopyOfABookMadeHereAreNotAdopted() async throws {
        let fake = FakeGateway()
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let library = library(fake, clippings: clippings)
        let here = try book()
        let hereID = try await library.submit(here, on: .thisMac)
        var phoneCopy = here
        phoneCopy.voices = VoicePlan(narrator: "kokoro:af_heart")
        fake.add(phoneCopy, ready: 2)
        let failed = fake.add(try phoneBook())
        fake.fail(failed)

        await library.refreshHomeServer()
        XCTAssertEqual(library.remoteBooks, [])
        XCTAssertEqual(library.jobs.map(\.id), [hereID])
        XCTAssertFalse(fake.seen.contains { $0.hasSuffix("/book") }, "\(fake.seen)")
        await library.cancel(hereID)
    }

    func testWithNoGatewayConfiguredTheHomeServerIsNotOffered() async {
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("home"))
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: DocumentLibraryTests.FakeKokoro(), gateway: { nil })
        let available = await library.homeServerAvailable()
        XCTAssertFalse(available)
    }
}
