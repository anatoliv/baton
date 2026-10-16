import XCTest
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
@testable import BatonMobile

/// "Previously…" on the phone: Play on a book last heard more than a day ago offers
/// a recap, made from the shaped book this phone sent, of the heard text only, through the models
/// the phone can reach; a cloud model needs consent for chapters; a silent model still plays the
/// book. Against the in-process `HomeServerBooksPhoneTests.FakeGateway` (60-second chapters).
@MainActor
final class BookRecapPhoneTests: XCTestCase {
    private var root: URL!
    private var fake: HomeServerBooksPhoneTests.FakeGateway!
    private var clippings: ClippingStore!
    private var library: HomeServerBooks!
    private var documentID: String!

    /// Chapter 1 is long enough to recap; chapter 2 names the glass key only in its second half.
    private static let markdown: String = {
        let one = (1...30).map { "Ada wound the great clock in the hall for the \($0) time that winter." }.joined(separator: " ")
        let twoHeard = (1...10).map { "A letter came that was not from Tobias, number \($0)." }.joined(separator: " ")
        let twoUnheard = (1...10).map { "Inside the case she found the little glass key, turn \($0)." }.joined(separator: " ")
        return "# The Clock\n\n## The House\n\n\(one)\n\n## The Letter\n\n\(twoHeard)\n\n\(twoUnheard)\n\n## The Return\n\nTobias came home and would not say who sent the letter."
    }()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-phone-recap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fake = HomeServerBooksPhoneTests.FakeGateway()
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: UserDefaults(suiteName: ThrowawayDefaults.name("phone-recap"))!)
        let fake = fake!
        library = HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                                  gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } })
        let url = root.appendingPathComponent("the-clock.md")
        try Self.markdown.write(to: url, atomically: true, encoding: .utf8)
        let prepared = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        documentID = prepared.documentID
        let jobID = try await library.submit(prepared)
        fake.setReady(jobID, 3)
        await library.collect()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func shelf() -> MobileBookShelf.Book {
        MobileBookShelf.books(items: clippings.items, records: library.records, summaries: library.summaries,
                              ledger: clippings.ledger)[0]
    }

    /// Halfway through chapter 2 (30 of 60 seconds), last heard `ago`.
    private func heardHalfOfChapterTwo(ago: TimeInterval) -> MobileBookShelf.Book {
        var ledger = clippings.ledger
        ledger.setPosition(documentID: documentID, chapterIndex: 1, seconds: 30, at: Date(timeIntervalSinceNow: -ago))
        clippings.ledger = ledger
        return shelf()
    }

    private var lastPlayed: Date? { clippings.ledger.document(documentID)?.positionAt }

    private static let lan = ModelSource(name: "qwen3:8b on your network", provider: .openAICompatible,
                                         baseURL: "http://192.168.1.20:11434/v1", model: "qwen3:8b", contextTokens: 8_192)

    // MARK: - The offer

    func testPlayOffersARecapOnlyAfterADayAway() throws {
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let prepared = try XCTUnwrap(MobileRecap.preparedBook(for: stale, homeServer: library))
        XCTAssertEqual(prepared.voices.narrator, "kokoro:bf_emma", "the shaped book this phone sent, not a rebuilt one")
        XCTAssertTrue(MobileRecapOffer().consider(stale, prepared: prepared, lastPlayed: lastPlayed))

        let recent = heardHalfOfChapterTwo(ago: 3_600)
        XCTAssertFalse(MobileRecapOffer().consider(recent, prepared: prepared, lastPlayed: lastPlayed), "an hour is not a break")

        var finished = heardHalfOfChapterTwo(ago: 2 * 86_400)
        finished.finished = true
        XCTAssertFalse(MobileRecapOffer().consider(finished, prepared: prepared, lastPlayed: lastPlayed), "a finished book starts over")
        XCTAssertFalse(MobileRecapOffer().consider(stale, prepared: nil, lastPlayed: lastPlayed), "no words, no recap")
    }

    func testWithoutTheShapedBookTheWordsComeFromTheRecord() throws {
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let fromClippings = try XCTUnwrap(MobileRecap.preparedBook(for: stale, homeServer: nil))
        XCTAssertEqual(fromClippings.chapters.count, 3)
        XCTAssertTrue(MobileRecap.shouldOffer(stale, prepared: fromClippings, lastPlayed: lastPlayed),
                      "the chapters' own text is enough to offer")
    }

    // MARK: - Writing and saying it

    func testTheRecapIsWrittenFromHeardTextOnlyThenSpokenThenTheBookPlays() async throws {
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let offer = MobileRecapOffer()
        XCTAssertTrue(offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed))
        var prompt = ""
        var spoken: String?
        var played = false
        let box = PromptBox()
        await offer.hear(sources: [Self.lan], consent: ModelConsent(), executor: { _, _, user in
            await box.set(user)
            return "## Recap\nPreviously, Ada wound the clock all winter, and a letter came that was not from Tobias."
        }, speak: { text in spoken = text; return true }, thenPlay: { played = true })
        prompt = await box.user
        XCTAssertTrue(prompt.contains("Ada wound the great clock"))
        XCTAssertTrue(prompt.contains("number 10."), "the heard half of chapter 2")
        XCTAssertFalse(prompt.contains("glass key"), "the unheard half of chapter 2 never reaches the model")
        XCTAssertFalse(prompt.contains("Tobias came home"), "nor does chapter 3")
        XCTAssertEqual(spoken, "Previously, Ada wound the clock all winter, and a letter came that was not from Tobias.")
        XCTAssertTrue(played)
        XCTAssertNil(offer.offer, "the offer goes once the recap is said")
    }

    func testASilentModelStillPlaysTheBook() async throws {
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let offer = MobileRecapOffer()
        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        var played = false
        await offer.hear(sources: [Self.lan], consent: ModelConsent(), executor: { _, _, _ in throw URLError(.timedOut) },
                         speak: { _ in XCTFail("nothing to say"); return false }, thenPlay: { played = true })
        XCTAssertTrue(played)
        XCTAssertEqual(offer.state, .failed("No model on this iPhone or your network wrote a recap, so the book plays as it is."))
    }

    // MARK: - The models the phone can reach

    func testTheMusicFriendsModelAndApplesModelAreTheSources() {
        let onDevice = AppleOnDeviceModel.source()
        let local = MobileRecap.sources(model: "qwen3:8b", baseURL: "http://192.168.1.20:11434/v1", provider: .openAICompatible,
                                        hasKey: false, onDevice: onDevice)
        XCTAssertEqual(local.map(\.name), ["qwen3:8b on your network", "Apple Intelligence on this iPhone"],
                       "a model on the person's network needs no key, and goes first")

        let untouched = MobileRecap.sources(model: "claude-haiku-4-5-20251001", baseURL: "https://api.anthropic.com",
                                            provider: .anthropic, hasKey: false, onDevice: nil)
        XCTAssertTrue(untouched.isEmpty, "the defaults with no key are not a model")
        XCTAssertEqual(MobileRecap.noRecapLine(sources: untouched, consent: ModelConsent()),
                       "No model is set up for recaps on this iPhone, so the book plays as it is.")
    }

    func testACloudModelIsNotSentChaptersWithoutConsent() async throws {
        let cloud = MobileRecap.sources(model: "claude-haiku-4-5-20251001", baseURL: "https://api.anthropic.com",
                                        provider: .anthropic, hasKey: true, onDevice: nil)
        XCTAssertEqual(cloud.map(\.name), ["Anthropic"])
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let offer = MobileRecapOffer()
        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        let box = PromptBox()
        var played = false
        await offer.hear(sources: cloud, consent: ModelConsent(), executor: { _, _, user in await box.set(user); return "Previously, x y z w v." },
                         speak: { _ in true }, thenPlay: { played = true })
        let asked = await box.user
        XCTAssertTrue(asked.isEmpty, "Anthropic was sent chapters without consent")
        XCTAssertTrue(played)
        XCTAssertEqual(offer.state, .failed("No model on this iPhone or your network wrote a recap, and sending chapters to Anthropic is not allowed, so the book plays as it is."))
    }

    // MARK: - Through the home server, and a cloud model only when allowed

    private static let cloud = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com",
                                           model: "claude-haiku-4-5-20251001", contextTokens: 8_192)

    func testTheHomeServerComesAfterTheNetworkAndBeforeTheCloud() {
        let onDevice = AppleOnDeviceModel.source()
        let lan = MobileRecap.sources(model: "qwen3:8b", baseURL: "http://192.168.1.20:11434/v1", provider: .openAICompatible,
                                      hasKey: false, homeServer: "https://home.example.net:8788", onDevice: onDevice)
        XCTAssertEqual(lan.map(\.name), ["qwen3:8b on your network", "your Baton server", "Apple Intelligence on this iPhone"])
        let hosted = MobileRecap.sources(model: "claude-haiku-4-5-20251001", baseURL: "https://api.anthropic.com",
                                         provider: .anthropic, hasKey: true, homeServer: "https://home.example.net:8788", onDevice: onDevice)
        XCTAssertEqual(hosted.map(\.name), ["your Baton server", "Apple Intelligence on this iPhone", "Anthropic"],
                       "everything on the person's own machines is tried before a cloud model")
        XCTAssertEqual(hosted.first?.provider, .homeServer)
    }

    /// A phone whose only model is the home server's gets its recap from there, and says so.
    func testARecapThroughTheHomeServer() async throws {
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let offer = MobileRecapOffer()
        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        let sources = MobileRecap.sources(model: "", baseURL: "", provider: .openAICompatible, hasKey: false,
                                          homeServer: "http://gateway.test:8788", onDevice: nil)
        let box = PromptBox()
        var spokenText: String?
        var writtenWhileSpeaking: String?
        var played = false
        await offer.hear(sources: sources, consent: ModelConsent(), executor: { source, _, user in
            XCTAssertEqual(source.provider, .homeServer)
            await box.set(user)
            return "Previously, Ada wound the clock all winter."
        }, speak: { text in spokenText = text; writtenWhileSpeaking = offer.writtenBy; return true }, thenPlay: { played = true })
        let prompt = await box.user
        XCTAssertTrue(prompt.contains("number 10."))
        XCTAssertFalse(prompt.contains("glass key"), "the spoiler bound holds on this route too")
        XCTAssertEqual(spokenText, "Previously, Ada wound the clock all winter.")
        XCTAssertEqual(writtenWhileSpeaking, "your Baton server")
        XCTAssertTrue(played)
    }

    /// An older home server answers 404: the phone goes on to its own model without a word.
    func testAnOlderHomeServerFallsThroughQuietly() async throws {
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let offer = MobileRecapOffer()
        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        let sources = MobileRecap.sources(model: "", baseURL: "", provider: .openAICompatible, hasKey: false,
                                          homeServer: "http://gateway.test:8788",
                                          // A fixed context: the simulator's own on-device model can report
                                          // less than a recap needs, and this test is about the 404, not that.
                                          onDevice: AppleOnDeviceModel.source(contextTokens: 8_192))
        var said: String?
        await offer.hear(sources: sources, consent: ModelConsent(), executor: { source, _, _ in
            if source.provider == .homeServer { throw HTTPModelClient.Failure.status(404, "unknown route") }
            return "Previously, Ada wound the great clock all winter, and a letter came."
        }, speak: { _ in said = offer.writtenBy; return true }, thenPlay: {})
        XCTAssertEqual(said, "Apple Intelligence on this iPhone")
        XCTAssertNil(offer.offer)
    }

    /// The first time only a cloud model could write the recap, the phone asks in the Mac's
    /// words. "Always" is kept per provider and for chapters, so the next recap does not ask.
    func testTheCloudIsAskedOnceAndAlwaysIsRemembered() async throws {
        let defaults = UserDefaults(suiteName: ThrowawayDefaults.name("phone-recap-consent"))!
        let ledger = ModelConsentLedger(defaults: defaults)
        let sources = [MobileRecap.sources(model: "", baseURL: "", provider: .openAICompatible, hasKey: false,
                                           homeServer: "http://gateway.test:8788", onDevice: nil)[0], Self.cloud]
        let asked = Box()
        let executor: ModelRouter.Executor = { source, _, _ in
            await asked.add(source.name)
            if source.provider == .homeServer { throw HTTPModelClient.Failure.status(403, "cloud model") }
            return "Previously, Ada wound the clock."
        }
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let offer = MobileRecapOffer()
        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        var played = false
        await offer.hear(sources: sources, consent: ledger.consent, isAnswered: { ledger.hasAnswered($0, .chapter) },
                         executor: executor, speak: { _ in true }, thenPlay: { played = true })
        XCTAssertEqual(offer.state, .askingConsent(Self.cloud))
        XCTAssertFalse(played, "the book waits for the answer")
        var names = await asked.names
        XCTAssertEqual(names, ["your Baton server"], "Anthropic is not sent anything before the answer")

        var writer: String?
        await offer.answerConsent(.always, ledger: ledger, executor: executor,
                                  speak: { _ in writer = offer.writtenBy; return true }, thenPlay: { played = true })
        XCTAssertEqual(writer, "Anthropic")
        XCTAssertTrue(played)
        XCTAssertTrue(ledger.allows(Self.cloud, .chapter))
        XCTAssertFalse(ledger.allows(Self.cloud, .excerpt), "chapters only, as on the Mac")

        // The next recap goes straight through: answered, so no question.
        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        await offer.hear(sources: sources, consent: ledger.consent, isAnswered: { ledger.hasAnswered($0, .chapter) },
                         executor: executor, speak: { _ in true }, thenPlay: {})
        names = await asked.names
        XCTAssertEqual(names, ["your Baton server", "Anthropic", "your Baton server", "Anthropic"])
        XCTAssertNil(offer.offer)
    }

    /// "Not now" plays the book, sends nothing and is remembered; "Allow once" is not.
    func testNotNowIsRememberedAndAllowOnceIsNot() async throws {
        let defaults = UserDefaults(suiteName: ThrowawayDefaults.name("phone-recap-consent-no"))!
        let ledger = ModelConsentLedger(defaults: defaults)
        let asked = Box()
        let executor: ModelRouter.Executor = { source, _, _ in await asked.add(source.name); return "Previously, Ada wound the clock." }
        let stale = heardHalfOfChapterTwo(ago: 2 * 86_400)
        let offer = MobileRecapOffer()

        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        await offer.hear(sources: [Self.cloud], consent: ledger.consent, isAnswered: { ledger.hasAnswered($0, .chapter) },
                         executor: executor, speak: { _ in true }, thenPlay: {})
        var said: String?
        await offer.answerConsent(.once, ledger: ledger, executor: executor, speak: { text in said = text; return true }, thenPlay: {})
        XCTAssertNotNil(said, "Allow once writes this recap")
        XCTAssertFalse(ledger.hasAnswered(Self.cloud, .chapter), "and keeps nothing")

        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        await offer.hear(sources: [Self.cloud], consent: ledger.consent, isAnswered: { ledger.hasAnswered($0, .chapter) },
                         executor: executor, speak: { _ in true }, thenPlay: {})
        XCTAssertEqual(offer.state, .askingConsent(Self.cloud), "asked again after Allow once")
        var played = false
        await offer.answerConsent(.notNow, ledger: ledger, executor: executor, speak: { _ in XCTFail("nothing to say"); return true },
                                  thenPlay: { played = true })
        XCTAssertTrue(played)
        XCTAssertTrue(ledger.hasAnswered(Self.cloud, .chapter))
        XCTAssertFalse(ledger.allows(Self.cloud, .chapter))

        offer.consider(stale, prepared: MobileRecap.preparedBook(for: stale, homeServer: library), lastPlayed: lastPlayed)
        await offer.hear(sources: [Self.cloud], consent: ledger.consent, isAnswered: { ledger.hasAnswered($0, .chapter) },
                         executor: executor, speak: { _ in true }, thenPlay: {})
        XCTAssertEqual(offer.state, .failed("No model on this iPhone or your network wrote a recap, and sending chapters to Anthropic is not allowed, so the book plays as it is."),
                       "Not now is not asked again")
        let names = await asked.names
        XCTAssertEqual(names, ["Anthropic"], "only the Allow once recap reached Anthropic")
    }
}

private actor Box {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

private actor PromptBox {
    var user = ""
    func set(_ user: String) { self.user = user }
}
