import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// Change Voice…: a book made again in another narrator's voice, on the home server
/// through `resubmit` or by this Mac's renderer, and a kept reading read again. One row
/// throughout, the old voice playable until each new chapter lands in its place, the listener's
/// place kept, the pronunciations and the cast carried over, and Stop putting the old voice back.
@MainActor
final class BookVoiceChangeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-voice-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private typealias FakeGateway = DocumentLibraryHomeServerTests.FakeGateway

    private func book(cast: Bool = false) throws -> PreparedBook {
        let url = root.appendingPathComponent("machine-\(UUID().uuidString).md")
        try """
        # The Machine Stops

        ## The Air-Ship

        Vashti sat in her room. The bell rang and she touched a switch. \u{201C}Who is it?\u{201D} said Vashti.

        ## The Mending Apparatus

        Kuno called from the other side of the earth. \u{201C}I want to see you,\u{201D} said Kuno.
        """.write(to: url, atomically: true, encoding: .utf8)
        let document = try DocumentImporter.importFile(at: url)
        var book = DocumentSpeech.prepare(document, voices: VoicePlan(narrator: "kokoro:af_heart"))
        if cast {
            // A cast as "Voice the dialogue" leaves it (G4): each quote given to its speaker, and
            // each speaker a voice of their own.
            book.voices.characters = ["Vashti": "kokoro:bf_emma", "Kuno": "kokoro:bm_george"]
            for c in book.chapters.indices {
                for s in book.chapters[c].segments.indices where book.chapters[c].segments[s].text.contains("\u{201C}") {
                    book.chapters[c].segments[s].speaker = c == 0 ? "Vashti" : "Kuno"
                }
            }
        }
        var lexicon = PronunciationLexicon()
        lexicon.set("Kuno", ipa: "kˈuːnoʊ")
        book.lexicon = lexicon
        return book
    }

    private func gatewayLibrary(_ fake: FakeGateway, clippings: ClippingStore, name: String = "Books") -> DocumentLibrary {
        DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent(name),
                        synthesizer: DocumentLibraryTests.FakeKokoro(), storageDefaults: ThrowawayDefaults.make("voice-change-storage"),
                        gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
    }

    private func clippingStore(_ name: String = "Clippings") -> ClippingStore {
        ClippingStore(directory: root.appendingPathComponent(name), defaults: ThrowawayDefaults.make("voice-change-\(name)"))
    }

    private func row(_ library: DocumentLibrary, _ documentID: String) throws -> BookShelf.Book {
        try XCTUnwrap(library.shelf.first { $0.documentID == documentID })
    }

    private func digests(_ clippings: ClippingStore, _ documentID: String) -> [String?] {
        clippings.chapters(ofDocument: documentID).map(\.clipping.sha256)
    }

    /// A home-server book with both chapters here and the listener 30 s into chapter 2.
    private func collectedOnHomeServer(_ fake: FakeGateway, _ clippings: ClippingStore, cast: Bool = false) async throws
        -> (library: DocumentLibrary, book: PreparedBook, jobID: String) {
        fake.audioByJob = true
        let library = gatewayLibrary(fake, clippings: clippings)
        let book = try book(cast: cast)
        let id = try await library.submit(book, on: .homeServer)
        fake.setReady(id, book.chapters.count)
        await library.refreshHomeServer()
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, 2)
        var ledger = clippings.ledger
        ledger.setPosition(documentID: book.documentID, chapterIndex: 1, seconds: 30)
        clippings.ledger = ledger
        return (library, book, id)
    }

    // MARK: - Home server, through resubmit

    func testAHomeServerBookIsMadeAgainInTheNewVoiceKeepingItsRowsPlaceAndPronunciations() async throws {
        let fake = FakeGateway()
        let clippings = clippingStore()
        let (library, book, oldID) = try await collectedOnHomeServer(fake, clippings)
        let before = clippings.chapters(ofDocument: book.documentID)
        let oldDigests = digests(clippings, book.documentID)
        XCTAssertTrue(library.canChangeVoice(try row(library, book.documentID)))
        XCTAssertEqual(library.voices(of: try row(library, book.documentID))?.plan.narrator, "kokoro:af_heart")

        try await library.changeVoice(try row(library, book.documentID), to: "kokoro:af_sky")

        // One record, following the job id the new voice gives the book; the old job is gone.
        let record = try XCTUnwrap(library.homeServer.record(forDocument: book.documentID))
        XCTAssertNotEqual(record.jobID, oldID)
        XCTAssertEqual(library.remoteBooks.count, 1, "one record, moved to the new job")
        XCTAssertEqual(record.documentID, book.documentID)
        XCTAssertTrue(fake.seen.contains("PUT /v1/books/\(record.jobID)"))
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(oldID)"))
        let sent = try XCTUnwrap(fake.submitted(record.jobID))
        XCTAssertEqual(sent.voices.narrator, "kokoro:af_sky")
        XCTAssertEqual(sent.lexicon, book.lexicon, "the pronunciations carry over")
        XCTAssertEqual(sent.chapters, book.chapters)

        // Nothing is ready yet: the old voice still plays, in the same rows.
        await library.refreshHomeServer()
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).map(\.id), before.map(\.id))
        XCTAssertEqual(digests(clippings, book.documentID), oldDigests)
        var making = try row(library, book.documentID)
        XCTAssertEqual(making.chapters.map { $0.item?.isPresent }, [true, true], "no silent gap")
        XCTAssertEqual(MusicBooksView.statusLine(making)?.text, "Making again in af_sky on Kokoro… chapter 1 of 2, 25%")
        XCTAssertTrue(making.canStopRemaking)

        // Chapter 1 lands: it replaces the old one in its row; chapter 2 is still the old voice.
        fake.setReady(record.jobID, 1)
        await library.refreshHomeServer()
        let afterOne = clippings.chapters(ofDocument: book.documentID)
        XCTAssertEqual(afterOne.map(\.id), before.map(\.id), "the same rows, no duplicates")
        XCTAssertEqual(afterOne.map(\.url), before.map(\.url), "the queue's URLs play the new audio")
        XCTAssertEqual(afterOne[0].clipping.sha256, SHA256Digest.hex(of: fake.chapterAudio(for: record.jobID)))
        XCTAssertEqual(afterOne[0].clipping.voice, "kokoro:af_sky")
        XCTAssertEqual(afterOne[1].clipping.sha256, oldDigests[1])
        making = try row(library, book.documentID)
        XCTAssertEqual(MusicBooksView.statusLine(making)?.text, "Making again in af_sky on Kokoro… chapter 2 of 2, 25%")

        // Chapter 2 lands: the change is over and the line goes.
        fake.setReady(record.jobID, 2)
        await library.refreshHomeServer()
        let after = clippings.chapters(ofDocument: book.documentID)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(Set(after.map(\.clipping.sha256)), [SHA256Digest.hex(of: fake.chapterAudio(for: record.jobID))])
        XCTAssertNil(library.voiceChange(for: try row(library, book.documentID)))
        let done = try row(library, book.documentID)
        XCTAssertNil(MusicBooksView.statusLine(done))
        XCTAssertEqual(done.position?.chapterIndex, 1, "the place is kept by chapter")
        XCTAssertEqual(done.position?.seconds, 30, "and by time")
        let hold = root.appendingPathComponent("Books/voice-change-hold")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: hold.path)) ?? [], [], "the old audio goes once it is done")
    }

    func testStopPutsTheOldVoiceBackInTheChaptersAlreadyReplaced() async throws {
        let fake = FakeGateway()
        let clippings = clippingStore()
        let (library, book, oldID) = try await collectedOnHomeServer(fake, clippings)
        let oldDigests = digests(clippings, book.documentID)
        try await library.changeVoice(try row(library, book.documentID), to: "kokoro:af_sky")
        let newID = try XCTUnwrap(library.homeServer.record(forDocument: book.documentID)?.jobID)
        fake.setReady(newID, 1)
        await library.refreshHomeServer()
        XCTAssertNotEqual(digests(clippings, book.documentID), oldDigests, "chapter 1 is in the new voice")

        try await library.cancelVoiceChange(try row(library, book.documentID))

        XCTAssertEqual(digests(clippings, book.documentID), oldDigests, "both chapters in the old voice again")
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).map(\.clipping.voice), ["kokoro:af_heart", "kokoro:af_heart"])
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, oldID, "the old voices are the old job")
        XCTAssertTrue(fake.seen.contains("DELETE /v1/books/\(newID)"))
        XCTAssertNil(library.voiceChange(for: try row(library, book.documentID)))
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, 2)
    }

    func testACastBookChangesItsNarratorOnlyOnTheHomeServer() async throws {
        let fake = FakeGateway()
        let clippings = clippingStore()
        let (library, book, _) = try await collectedOnHomeServer(fake, clippings, cast: true)
        XCTAssertTrue(book.hasCast)
        XCTAssertEqual(library.voices(of: try row(library, book.documentID))?.hasCast, true, "the picker says so")

        try await library.changeVoice(try row(library, book.documentID), to: "kokoro:am_adam")

        let record = try XCTUnwrap(library.homeServer.record(forDocument: book.documentID))
        let sent = try XCTUnwrap(fake.submitted(record.jobID))
        XCTAssertEqual(sent.voices.narrator, "kokoro:am_adam")
        XCTAssertEqual(sent.voices.characters, book.voices.characters, "the cast keeps its voices")
        XCTAssertEqual(sent.voices.characters["Vashti"], "kokoro:bf_emma")
        XCTAssertEqual(sent.chapters.flatMap(\.segments).map(\.speaker), book.chapters.flatMap(\.segments).map(\.speaker))
        XCTAssertEqual(library.homeServer.preparedBook(forJob: record.jobID)?.voices.characters, book.voices.characters)
    }

    /// Voice the dialogue in Change Voice…: a book made with one narrator is given a
    /// cast, which travels to the home server in the book; Stop puts back the book it was.
    func testABookIsGivenACastAndStopTakesItAway() async throws {
        let fake = FakeGateway()
        let clippings = clippingStore()
        let (library, book, oldID) = try await collectedOnHomeServer(fake, clippings)
        let prepared = try XCTUnwrap(library.pronunciationSource(documentID: book.documentID)?.book)
        var change = DialogueCastFlow.Change(prepared)
        XCTAssertFalse(change.hadCast)
        let sheet = DialogueCast.CastSheet(characters: [DialogueCast.Character(name: "Vashti", gender: "f"),
                                                        DialogueCast.Character(name: "Kuno", gender: "m")])
        let casting = DialogueCast.Casting(sheet: sheet, document: prepared.spokenDocument, narrator: "kokoro:af_heart",
                                           available: ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george"], source: "a test model")
        change.choice.isOn = true
        change.choice.phase = .ready(casting)
        change.choice.reviewed = true
        change.choice.placing = .placed(DialogueCast.Fill(), line: DialogueCastFlow.skippedLine)
        XCTAssertTrue(change.changes(narrator: "kokoro:af_heart"), "the same narrator, a new cast")

        try await library.changeVoice(try row(library, book.documentID), to: change.book(narrator: "kokoro:af_heart"))

        let record = try XCTUnwrap(library.homeServer.record(forDocument: book.documentID))
        XCTAssertNotEqual(record.jobID, oldID)
        let sent = try XCTUnwrap(fake.submitted(record.jobID))
        XCTAssertEqual(Set(sent.voices.characters.keys), ["Vashti", "Kuno"])
        XCTAssertEqual(Set(sent.chapters.flatMap(\.segments).compactMap(\.speaker)), ["Vashti", "Kuno"], "each line knows its speaker")
        XCTAssertEqual(sent.lexicon, book.lexicon, "the pronunciations stay")
        XCTAssertNotNil(library.voiceChange(for: try row(library, book.documentID)))

        try await library.cancelVoiceChange(try row(library, book.documentID))
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, oldID, "the book it was, one narrator")
    }

    /// A cast edited (a speaker renamed and revoiced) or turned off; Stop puts the cast back.
    func testACastIsEditedOrTurnedOffAndStopPutsItBack() async throws {
        let fake = FakeGateway()
        let clippings = clippingStore()
        let (library, book, oldID) = try await collectedOnHomeServer(fake, clippings, cast: true)
        let prepared = try XCTUnwrap(library.pronunciationSource(documentID: book.documentID)?.book)
        var change = DialogueCastFlow.Change(prepared)
        XCTAssertTrue(change.hadCast)
        var edited = try XCTUnwrap(change.edited)
        XCTAssertTrue(edited.rename("Vashti", to: "Mother"))
        edited.setVoice("Kuno", "kokoro:bm_fable")
        change.edited = edited

        try await library.changeVoice(try row(library, book.documentID), to: change.book(narrator: "kokoro:af_heart"))
        var sent = try XCTUnwrap(fake.submitted(try XCTUnwrap(library.homeServer.record(forDocument: book.documentID)).jobID))
        XCTAssertEqual(sent.voices.characters, ["Mother": "kokoro:bf_emma", "Kuno": "kokoro:bm_fable"])
        XCTAssertEqual(sent.chapters.flatMap(\.segments).map(\.speaker),
                       book.chapters.flatMap(\.segments).map { $0.speaker == "Vashti" ? "Mother" : $0.speaker })
        try await library.cancelVoiceChange(try row(library, book.documentID))
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, oldID, "the cast it had")

        change.choice.isOn = false
        try await library.changeVoice(try row(library, book.documentID), to: change.book(narrator: "kokoro:am_adam"))
        sent = try XCTUnwrap(fake.submitted(try XCTUnwrap(library.homeServer.record(forDocument: book.documentID)).jobID))
        XCTAssertEqual(sent.voices.narrator, "kokoro:am_adam")
        XCTAssertEqual(sent.voices.characters, [:])
        XCTAssertFalse(sent.chapters.flatMap(\.segments).contains { $0.speaker != nil }, "one narrator reads everything")
        try await library.cancelVoiceChange(try row(library, book.documentID))
        XCTAssertEqual(library.homeServer.record(forDocument: book.documentID)?.jobID, oldID)
    }

    /// TBX-10985's other device: a book it adopted from the home server follows the job the first
    /// device made again, and its chapters are replaced in their rows rather than kept in the old
    /// voice for ever.
    func testABookAdoptedOnTheOtherDevicePicksUpTheChaptersMadeAgain() async throws {
        let fake = FakeGateway()
        let mac = clippingStore("MacClippings")
        let (library, book, oldID) = try await collectedOnHomeServer(fake, mac)
        let phoneClippings = clippingStore("PhoneClippings")
        let phone = HomeServerBooks(directory: root.appendingPathComponent("PhoneBooks"), clippings: phoneClippings,
                                    gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
        await phone.collect()
        XCTAssertEqual(phone.record(forDocument: book.documentID)?.jobID, oldID)
        XCTAssertEqual(phone.record(forDocument: book.documentID)?.adopted, true)
        let phoneRows = phoneClippings.chapters(ofDocument: book.documentID)
        XCTAssertEqual(phoneRows.count, 2)

        try await library.changeVoice(try row(library, book.documentID), to: "kokoro:af_sky")
        let newID = try XCTUnwrap(library.homeServer.record(forDocument: book.documentID)?.jobID)
        fake.setReady(newID, 2)

        await phone.collect()
        XCTAssertEqual(phone.records.count, 1, "followed, not adopted a second time")
        XCTAssertEqual(phone.record(forDocument: book.documentID)?.jobID, newID)
        let replaced = phoneClippings.chapters(ofDocument: book.documentID)
        XCTAssertEqual(replaced.map(\.id), phoneRows.map(\.id), "the phone's rows are kept")
        XCTAssertEqual(Set(replaced.map(\.clipping.sha256)), [SHA256Digest.hex(of: fake.chapterAudio(for: newID))])
        XCTAssertNil(phone.voiceChanges.change(forDocument: book.documentID))
    }

    // MARK: - This Mac's renderer

    /// A voice server whose audio is a tone set by the voice, so another voice is other audio,
    /// and slow enough that the chapters land one after another.
    actor VoicedKokoro: SpeechSynthesizing {
        private(set) var voices: [String] = []
        func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
            voices.append(voice)
            try await Task.sleep(for: .milliseconds(15))
            let level = Int16(1_000 + abs(voice.hashValue % 8_000))
            var pcm = Data()
            for i in 0..<(24_000 / 5) {
                let sample = (i / 40) % 2 == 0 ? level : -level
                withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
            }
            return WAV.header(format: .init(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16),
                              dataBytes: pcm.count) + pcm
        }
    }

    func testTheMacRendererMakesItAgainAndReplacesTheChaptersInOrder() async throws {
        let kokoro = VoicedKokoro()
        let clippings = clippingStore()
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: kokoro, retry: .init(initialDelay: 0.02, maximumDelay: 0.05),
                                      refreshInterval: .milliseconds(20), storageDefaults: ThrowawayDefaults.make("voice-change-mac"),
                                      gateway: { nil })
        library.start(force: true)
        let book = try book()
        let oldID = try await library.submit(book)
        try await eventually(library) { clippings.chapters(ofDocument: book.documentID).count == 2 }
        var ledger = clippings.ledger
        ledger.setPosition(documentID: book.documentID, chapterIndex: 1, seconds: 4)
        clippings.ledger = ledger
        let before = clippings.chapters(ofDocument: book.documentID)
        let oldDigests = before.map(\.clipping.sha256)
        XCTAssertEqual(before.map(\.clipping.voice), ["kokoro:af_heart", "kokoro:af_heart"])

        try await library.changeVoice(try row(library, book.documentID), to: "kokoro:af_sky")
        let newID = BookJob.id(for: book.inVoice("kokoro:af_sky"))
        XCTAssertEqual(library.job(forDocument: book.documentID)?.id, newID,
                       "jobs: \(library.jobs.map { "\($0.id.prefix(8)) \($0.summary.createdAt.timeIntervalSince1970) \(library.store.load($0.id)?.book.voices.narrator ?? "-")" }), old \(oldID.prefix(8))")
        XCTAssertEqual(library.shelf.filter { $0.documentID == book.documentID }.count, 1, "one row for the book")

        // Watch the chapters change: chapter 1 before chapter 2, never the other way round.
        var seen: [[Bool]] = []
        try await eventually(library) {
            let now = clippings.chapters(ofDocument: book.documentID)
            let changed = zip(now, oldDigests).map { $0.clipping.sha256 != $1 }
            if seen.last != changed { seen.append(changed) }
            XCTAssertEqual(now.count, 2, "never a duplicate row")
            XCTAssertTrue(now.allSatisfy(\.isPresent), "never a silent gap")
            return changed == [true, true]
        }
        XCTAssertFalse(seen.contains([false, true]), "chapter 2 never lands before chapter 1: \(seen)")
        XCTAssertTrue(seen.contains([true, false]), "chapter 1 lands while chapter 2 is still in the old voice: \(seen)")

        let after = clippings.chapters(ofDocument: book.documentID)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.url), before.map(\.url))
        XCTAssertEqual(after.map(\.clipping.voice), ["kokoro:af_sky", "kokoro:af_sky"])
        let voices = await kokoro.voices
        XCTAssertTrue(voices.contains("kokoro:af_sky"))
        let done = try row(library, book.documentID)
        XCTAssertEqual(done.position?.chapterIndex, 1)
        XCTAssertEqual(done.position?.seconds, 4)
        XCTAssertNil(library.voiceChange(for: done))
        XCTAssertEqual(library.store.load(newID)?.book.lexicon, book.lexicon, "the pronunciations carry over")
        try await eventuallyTrue { library.store.load(oldID) == nil }
    }

    // MARK: - A kept reading on the Mac

    func testAKeptReadingIsReadAgainInTheNewVoiceKeepingItsRowAndStoringTheVoice() async throws {
        let clippings = clippingStore()
        let first = root.appendingPathComponent("first.m4a")
        try Data(repeating: 0x41, count: 2_048).write(to: first)
        let kept = try clippings.adopt(first, title: "Ghostty 2026-10-15 10.00", sourceName: "Ghostty",
                                       text: "The machine stops. Nobody noticed at first.", sha256: "olddigest",
                                       voice: "kokoro:af_heart")
        let revoicer = ClippingRevoicer()
        var asked: [(String, String)] = []
        revoicer.synthesize = { text, voice in
            asked.append((text, voice.voice))
            var pcm = Data()
            for i in 0..<(24_000 / 4) {
                let sample: Int16 = (i / 30) % 2 == 0 ? 6_000 : -6_000
                withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
            }
            return WAV.header(format: .init(audioFormat: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16),
                              dataBytes: pcm.count) + pcm
        }
        var uploaded: [String] = []
        var removed: [String] = []
        revoicer.upload = { url, name, _ in
            uploaded.append(name)
            return SHA256Digest.hex(of: try Data(contentsOf: url))
        }
        revoicer.removeShared = { removed.append($0) }

        try await revoicer.revoice(kept, to: "kokoro:af_sky", in: clippings)

        XCTAssertEqual(asked.map(\.1), ["af_sky"], "the words, read once more in the chosen voice")
        XCTAssertEqual(asked.first?.0, "The machine stops. Nobody noticed at first.")
        XCTAssertEqual(clippings.items.count, 1, "the same row")
        let item = try XCTUnwrap(clippings.item(id: kept.id))
        XCTAssertEqual(item.url, kept.url)
        XCTAssertEqual(item.clipping.voice, "kokoro:af_sky", "the voice is stored from now on")
        XCTAssertEqual(item.clipping.title, kept.clipping.title)
        XCTAssertEqual(item.clipping.text, kept.clipping.text)
        let bytes = try Data(contentsOf: item.url)
        XCTAssertNotEqual(bytes, Data(repeating: 0x41, count: 2_048), "the audio is replaced")
        XCTAssertGreaterThan(item.clipping.durationSeconds ?? 0, 0.2)
        XCTAssertEqual(item.clipping.sha256, SHA256Digest.hex(of: bytes), "sent again, under its new digest")
        XCTAssertEqual(uploaded, ["Ghostty 2026-10-15 10.00.m4a"])
        XCTAssertNotNil(clippings.ledger.record(for: "olddigest")?.removedAt, "the old copy is gone from the other devices")
        XCTAssertEqual(removed, ["olddigest"])
        XCTAssertNil(revoicer.running[kept.id])
    }

    func testAReadingKeepsItsVoiceWhenTheVoiceServerFails() async throws {
        let clippings = clippingStore()
        let first = root.appendingPathComponent("first.m4a")
        try Data(repeating: 0x41, count: 2_048).write(to: first)
        let kept = try clippings.adopt(first, title: "Reading", text: "One sentence.", voice: "kokoro:af_heart")
        let revoicer = ClippingRevoicer()
        revoicer.synthesize = { _, _ in throw URLError(.cannotConnectToHost) }
        revoicer.upload = { _, _, _ in XCTFail("nothing to send"); return nil }
        do {
            try await revoicer.revoice(kept, to: "kokoro:af_sky", in: clippings)
            XCTFail("a failed voice server is an error, not the system voice")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: kept.url), Data(repeating: 0x41, count: 2_048))
        XCTAssertEqual(clippings.item(id: kept.id)?.clipping.voice, "kokoro:af_heart")
    }

    // MARK: - A voice that cannot be had

    /// Refuses one voice as unreachable, every time, the way a voice server that is down or an
    /// engine that will not read the voice does; reads any other.
    actor OneVoiceDown: SpeechSynthesizing {
        let down: String
        init(down: String) { self.down = down }
        func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
            if voice == down { throw SynthesisError.transient("kokoro did not answer: connection refused") }
            return try await VoicedKokoro().synthesize(text: text, voice: voice, speed: speed)
        }
    }

    /// Owner report, 2026-10-17: "after changing the voice, the old voices stays active until
    /// application is restarted". A book paused because its voice cannot be had is the usual
    /// reason to change the voice; the paused job's retry went on after Change Voice cancelled
    /// it, and this Mac's renderer, which makes one book at a time, never reached the book in
    /// its new voice until a relaunch. It is made at once now, and says so while it is.
    func testABookPausedOnItsVoiceIsMadeInTheNewVoiceWithoutARelaunch() async throws {
        let clippings = clippingStore()
        // A long backoff, as in the app: the retry is asleep when Change Voice comes.
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: OneVoiceDown(down: "kokoro:af_heart"),
                                      retry: .init(initialDelay: 30, maximumDelay: 60),
                                      refreshInterval: .milliseconds(20), storageDefaults: ThrowawayDefaults.make("voice-change-paused"),
                                      gateway: { nil })
        library.start(force: true)
        let book = try book()
        let oldID = try await library.submit(book)
        try await eventually(library, timeout: 10) { library.store.load(oldID)?.status == .paused }
        XCTAssertEqual(library.store.load(oldID)?.status, .paused, "the old voice cannot be had")
        XCTAssertTrue(library.canChangeVoice(try row(library, book.documentID)))

        try await library.changeVoice(try row(library, book.documentID), to: "kokoro:af_sky")
        let newID = BookJob.id(for: book.inVoice("kokoro:af_sky"))
        XCTAssertEqual(library.job(forDocument: book.documentID)?.id, newID)

        try await eventually(library, timeout: 10) {
            clippings.chapters(ofDocument: book.documentID).count == 2
        }
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).map(\.clipping.voice), ["kokoro:af_sky", "kokoro:af_sky"],
                       "the book is made in its new voice without a relaunch")
        XCTAssertNil(library.store.load(oldID), "the paused job is gone")
    }

    /// Read Along shows the timing of the audio a chapter has now: a chapter given a new voice
    /// keeps its row and id, so the panel's timing is keyed by the audio as well.
    func testReadAlongTimingFollowsTheChaptersAudio() throws {
        let clippings = clippingStore()
        let first = root.appendingPathComponent("first.m4a")
        try Data(repeating: 0x41, count: 2_048).write(to: first)
        let kept = try clippings.adopt(first, title: "Chapter 1", sha256: "aa",
                                       chapter: .init(documentID: "doc", documentTitle: "Book", author: nil,
                                                      chapterIndex: 0, chapterTitle: "Chapter 1"),
                                       voice: "kokoro:af_heart")
        let second = root.appendingPathComponent("second.m4a")
        try Data(repeating: 0x42, count: 2_048).write(to: second)
        let (replaced, _) = try clippings.replaceAudio(id: kept.id, with: second, durationSeconds: 3, sha256: "bb",
                                                       voice: "kokoro:af_sky")
        XCTAssertEqual(replaced.id, kept.id)
        XCTAssertNotEqual(ReadAlongPanel.timingIdentity(of: replaced), ReadAlongPanel.timingIdentity(of: kept))
    }

    // MARK: - Waiting

    private func eventually(_ library: DocumentLibrary, timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            library.refresh()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out")
    }

    private func eventuallyTrue(timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out")
    }
}
