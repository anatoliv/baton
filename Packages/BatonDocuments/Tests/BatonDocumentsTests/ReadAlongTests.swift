import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

/// Read-along: the timing the renderer keeps beside each chapter, the sentence lit at
/// a time, the seek target of a tapped sentence, and the chapter made before timing existed.
final class ReadAlongTests: XCTestCase {
    private func timing(_ spans: [(Double, Double)], paragraphs: [Int]? = nil) -> ReadAlongTiming {
        ReadAlongTiming(segments: spans.enumerated().map { i, span in
            .init(text: "Sentence \(i).", paragraph: paragraphs?[i] ?? i, start: span.0, end: span.1)
        })
    }

    // MARK: Rendering keeps the timing

    func testTheRendererKeepsWhereEachChunkSitsBesideTheChapter() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir.appendingPathComponent("books"))
        let renderer = BookRenderer(store: store, cacheDirectory: dir.appendingPathComponent("cache"),
                                    synthesizer: FakeSynthesizer(secondsPerClip: 0.2), muxer: CopyMuxer(),
                                    concurrency: 1, retry: .init(initialDelay: 0.01, maximumDelay: 0.02))
        let book = sampleBook()
        let id = BookJob.id(for: book)
        _ = try await renderer.submit(book, id: id)
        await renderer.waitUntilIdle()

        let job = try XCTUnwrap(store.load(id))
        guard case let .ready(file, _, seconds, _) = job.chapters[0] else { return XCTFail("chapter 1 not ready") }
        XCTAssertEqual(file, "chapter-1.m4a")
        let kept = try XCTUnwrap(store.chapterTiming(id, file: file), "a chapter made now has its timing")
        let segments = book.chapters[0].segments
        XCTAssertEqual(kept.segments.map(\.text), segments.map(\.text), "the words as written, one entry per chunk")
        XCTAssertEqual(kept.segments.map(\.paragraph), segments.map(\.paragraph))

        // Each chunk starts after its own pause, and lasts its clip.
        var clock = 0.0
        for (segment, entry) in zip(segments, kept.segments) {
            clock += Double(segment.pauseBeforeMs) / 1000
            XCTAssertEqual(entry.start, clock, accuracy: 0.001)
            XCTAssertEqual(entry.end - entry.start, 0.2, accuracy: 0.001)
            clock = entry.end
        }
        XCTAssertEqual(try XCTUnwrap(kept.segments.last).end, seconds, accuracy: 0.001, "the last chunk ends the chapter")
        XCTAssertNotNil(store.chapterTiming(id, file: "chapter-2.m4a"))
        XCTAssertNil(store.chapterTiming(id, file: "../job.json"), "only chapter files have timing")
    }

    // MARK: Which sentence, where to seek

    func testTheSentenceLitAtATime() {
        // 0.0-1.0, a pause, 1.5-2.5, 2.5-4.0.
        let along = ReadAlong(timing: timing([(0, 1), (1.5, 2.5), (2.5, 4)]))
        XCTAssertTrue(along.isTimed)
        XCTAssertEqual(along.sentenceIndex(at: 0), 0)
        XCTAssertEqual(along.sentenceIndex(at: 0.99), 0)
        XCTAssertEqual(along.sentenceIndex(at: 1.2), 0, "in the pause before a sentence, the one before stays lit")
        XCTAssertEqual(along.sentenceIndex(at: 1.5), 1)
        XCTAssertEqual(along.sentenceIndex(at: 2.5), 2, "a sentence starting exactly now is the one heard")
        XCTAssertEqual(along.sentenceIndex(at: 99), 2, "past the end, the last")
        XCTAssertEqual(along.sentenceIndex(at: -3), 0)

        let late = ReadAlong(timing: timing([(0.4, 1), (1, 2)]))
        XCTAssertEqual(late.sentenceIndex(at: 0.1), 0, "before the first starts, the first")
    }

    func testATappedSentenceSeeksToWhereItsSpeechStarts() {
        let along = ReadAlong(timing: timing([(0, 1), (1.5, 2.5), (2.5, 4)]))
        XCTAssertEqual(along.seekTarget(for: 1), 1.5)
        XCTAssertEqual(along.seekTarget(for: 0), 0)
        XCTAssertNil(along.seekTarget(for: 3))
        XCTAssertNil(along.seekTarget(for: -1))
        // Seeking there lights the sentence that was tapped.
        for index in along.sentences.indices {
            XCTAssertEqual(along.sentenceIndex(at: along.seekTarget(for: index)!), index)
        }
    }

    /// A tap seeks to a sentence's start, and the player keeps time in 1/600 s: 1.7425833 s
    /// (a real chapter's second sentence) became 1.7416667 s, and the sentence before stayed lit
    /// until the audio started again. Within 5 ms, the sentence is the one heard.
    func testASeekRoundedToThePlayersClockLightsTheTappedSentence() {
        let along = ReadAlong(timing: timing([(0.2, 1.4), (1.7425833333, 7.0), (7.4316667, 13.0)]))
        let rounded = (1.7425833333 * 600).rounded(.down) / 600
        XCTAssertEqual(along.sentenceIndex(at: rounded), 1, "the tapped sentence, not the one before")
        XCTAssertEqual(along.sentenceIndex(at: 1.73), 0, "a hundredth of a second before, still the one before")
    }

    func testManySentencesAreFoundByTheSearch() {
        let spans = (0..<500).map { (Double($0) * 2, Double($0) * 2 + 1.5) }
        let along = ReadAlong(timing: timing(spans))
        XCTAssertEqual(along.sentenceIndex(at: 0), 0)
        XCTAssertEqual(along.sentenceIndex(at: 1.7), 0)
        XCTAssertEqual(along.sentenceIndex(at: 2), 1)
        XCTAssertEqual(along.sentenceIndex(at: 777.3), 388)
        XCTAssertEqual(along.sentenceIndex(at: 998), 499)
    }

    // MARK: Books made before timing

    func testAChapterWithoutTimingShowsItsTextWithoutAHighlight() {
        let text = "One sentence here. Two sentences now. Three of them. Four in all. And a fifth one."
        let along = ReadAlong(timing: nil, fallbackText: text)
        XCTAssertFalse(along.isTimed)
        XCTAssertEqual(along.sentences.count, 5)
        XCTAssertNil(along.sentenceIndex(at: 3))
        XCTAssertNil(along.seekTarget(for: 0))
        XCTAssertEqual(along.paragraphs.map { $0.sentences.count }, [4, 1], "a few sentences to a paragraph")

        XCTAssertFalse(ReadAlong(timing: nil, fallbackText: nil).isTimed)
        XCTAssertTrue(ReadAlong(timing: nil, fallbackText: nil).sentences.isEmpty)
        XCTAssertFalse(ReadAlong(timing: ReadAlongTiming(segments: []), fallbackText: text).isTimed,
                       "an empty timing is no timing")
    }

    func testParagraphsFollowTheChunks() {
        let along = ReadAlong(timing: timing([(0, 1), (1, 2), (2, 3), (3, 4)], paragraphs: [-1, 0, 0, 1]))
        XCTAssertEqual(along.paragraphs.map(\.paragraph), [-1, 0, 1])
        XCTAssertEqual(along.paragraphs.map { $0.sentences.map(\.id) }, [[0], [1, 2], [3]])
    }

    // MARK: The format

    func testTheFormatRoundTripsAndRefusesWhatItDoesNotKnow() throws {
        let original = timing([(0, 1.25), (1.5, 3)])
        XCTAssertEqual(ReadAlongTiming.decode(try original.encoded()), original)
        var newer = original
        newer.version = ReadAlongTiming.currentVersion + 1
        XCTAssertNil(ReadAlongTiming.decode(try newer.encoded()), "a newer format reads as no timing, not a guess")
        XCTAssertNil(ReadAlongTiming.decode(Data("not json".utf8)))

        XCTAssertEqual(ReadAlongTiming.fileName(forChapterFile: "chapter-12.m4a"), "chapter-12.timing.json")
        XCTAssertNil(ReadAlongTiming.fileName(forChapterFile: "job.json"))
        XCTAssertNil(ReadAlongTiming.fileName(forChapterFile: "../chapter-1.m4a"))
    }

    func testTheStoreKeepsTimingByTheAudiosDigest() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReadAlongStore.inBooks(dir)
        let sha = String(repeating: "ab", count: 32)
        let kept = timing([(0, 1)])
        XCTAssertNil(store.load(forAudio: sha))
        try store.save(kept, forAudio: sha.uppercased())
        XCTAssertEqual(store.load(forAudio: sha), kept)
        XCTAssertNil(store.load(forAudio: nil))
        XCTAssertThrowsError(try store.save(kept, forAudio: "../../etc/passwd"))
        XCTAssertNil(store.url(forAudio: "not-a-digest"))
        store.remove(forAudio: sha)
        XCTAssertNil(store.load(forAudio: sha))
    }

    // MARK: From the home server

    func testTheClientReadsTimingAndTakesA404AsNone() async throws {
        let kept = timing([(0, 1), (1.2, 2)])
        let body = try kept.encoded()
        let paths = PathRecorder()
        let client = GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "tok") { request in
            paths.add(request.url!.path)
            let status = request.url!.path.contains("/chapters/1/") ? 200 : 404
            return (status == 200 ? body : Data(#"{"error":"no such book"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        let first = try await client.chapterTiming("abc", number: 1)
        XCTAssertEqual(first, kept)
        let second = try await client.chapterTiming("abc", number: 2)
        XCTAssertNil(second, "an older gateway, or a chapter made before timing: no highlight, no error")
        XCTAssertEqual(paths.all, ["/v1/books/abc/chapters/1/timing", "/v1/books/abc/chapters/2/timing"])

        let failing = GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "tok") { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        do {
            _ = try await failing.chapterTiming("abc", number: 1)
            XCTFail("a server error is not 'no timing'")
        } catch {}
    }
}

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.withLock { paths.append(path) } }
    var all: [String] { lock.withLock { paths } }
}
