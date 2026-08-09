import XCTest
@testable import BatonAgentKit

/// A system that learns can learn the wrong thing, so what it *refuses* to learn matters
/// as much as what it stores.
@MainActor
final class FriendLearningTests: XCTestCase {

    private func makeStore() -> FriendLearningStore {
        FriendLearningStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
    }

    private func down(_ request: String, _ fault: FriendExchange.Fault, note: String? = nil) -> FriendExchange {
        FriendExchange(surface: .phone, request: request, reply: "…",
                       rating: .down, fault: fault, note: note)
    }

    /// Every correction cites the exchange it came from. Without that it is an assertion
    /// about the person that nothing can justify — the exact thing `RemoteMemoryStore`
    /// refuses to hold.
    func testACorrectionCanAlwaysCiteItsSource() {
        let store = makeStore()
        let exchange = down("play my trance", .wrongTrack, note: "I meant Classic Trance")
        let learned = store.learn(from: exchange)

        XCTAssertEqual(learned?.exchangeID, exchange.id)
        XCTAssertEqual(learned?.request, "play my trance",
                       "the person's own words are the quote the correction rests on")
        XCTAssertEqual(learned?.note, "I meant Classic Trance")
    }

    /// A thumbs-up says "that was right", which does not say what to do differently.
    func testItLearnsNothingFromApprovalOrFromAnUnratedExchange() {
        let store = makeStore()
        XCTAssertNil(store.learn(from: FriendExchange(surface: .phone, request: "a", reply: "b", rating: .up)))
        XCTAssertNil(store.learn(from: FriendExchange(surface: .phone, request: "a", reply: "b")))
        XCTAssertTrue(store.corrections.isEmpty)
    }

    /// "Too slow" is not about understanding, and no sentence in a prompt makes a model
    /// faster. Storing it would put noise where corrections belong.
    func testItRefusesToLearnFromSlowness() {
        let store = makeStore()
        XCTAssertNil(store.learn(from: down("play something", .tooSlow)))
        XCTAssertTrue(store.corrections.isEmpty)
    }

    /// One recurring annoyance must not crowd out eleven others.
    func testTheSameRequestIsLearnedOnce() {
        let store = makeStore()
        store.learn(from: down("play my trance", .wrongTrack))
        store.learn(from: down("Play My Trance", .misunderstood))
        XCTAssertEqual(store.corrections.count, 1)
    }

    /// Bounded, newest kept. A prompt that grows without limit crowds out the instructions
    /// that make the agent work at all, and does it silently.
    func testItIsBounded() {
        let store = makeStore()
        for index in 0 ... (FriendLearningStore.maxCorrections + 4) {
            store.learn(from: down("request \(index)", .wrongTrack))
        }
        XCTAssertEqual(store.corrections.count, FriendLearningStore.maxCorrections)
        XCTAssertEqual(store.corrections.first?.request, "request \(FriendLearningStore.maxCorrections + 4)")
    }

    /// Removing one is a tap, and it survives a reopen — a learned rule you cannot correct
    /// is worse than one you never had.
    func testForgettingSticks() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("learned-\(UUID().uuidString).json")
        let store = FriendLearningStore(url: url)
        store.learn(from: down("play my trance", .wrongTrack))
        let id = try! XCTUnwrap(store.corrections.first?.id)
        store.forget(id)

        XCTAssertTrue(FriendLearningStore(url: url).corrections.isEmpty)
    }

    /// The prompt block is evidence, not law. A model handed "never play X" will refuse X
    /// in the situation where X was exactly right.
    func testThePromptBlockReadsAsEvidenceRatherThanRules() throws {
        let store = makeStore()
        store.learn(from: down("play my trance", .wrongTrack, note: "I meant Classic Trance"))
        let block = try XCTUnwrap(store.promptBlock)

        XCTAssertTrue(block.contains("not as rules to obey"))
        XCTAssertTrue(block.contains("I meant Classic Trance"))
        XCTAssertFalse(block.lowercased().contains("never "),
                       "a ban invites over-application; this is meant to be weighed")
    }

    func testNoPromptBlockWhenNothingHasBeenLearned() {
        XCTAssertNil(makeStore().promptBlock)
    }
}

/// The corrections have to actually reach the model, or the whole loop is decoration.
@MainActor
final class FriendLearningPromptTests: XCTestCase {
    private func config() -> RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.apiKey = "k"
        config.model = "m"
        config.baseURL = "http://127.0.0.1:1"
        return config
    }

    func testLearnedCorrectionsReachTheSystemPrompt() throws {
        let learned = """
        THINGS YOU GOT WRONG BEFORE, in this person's judgement.
        - When they asked "play my trance", the answer was wrong.
        """
        let request = try RemoteAgent.buildRequest(
            [RemoteAgentMessage(role: "user", text: "play something")],
            tools: RemoteToolSchemas(json: []), config: config(), playerContext: "Now playing: nothing",
            learned: learned
        )
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("play my trance"),
                      "the corrections never reached the model — the feedback loop ends in a file nobody reads")
        XCTAssertTrue(text.contains("Now playing: nothing"),
                      "the player context was lost when corrections were added")
    }

    /// With nothing learned, the system prompt must be exactly what it was before. A
    /// feature that changes the prompt for everyone who never rated anything is a
    /// regression, not a feature.
    ///
    /// Compares the *prompt*, not the encoded body. The first version of this compared
    /// `httpBody` and failed on two payloads of identical length: JSON object ordering is
    /// not stable, so the bytes differ run to run while the meaning does not. It passed in
    /// isolation by luck, which is the worst way for a test to be wrong.
    func testNothingLearnedChangesTheSystemPrompt() throws {
        func systemPrompt(learned: String?) throws -> String {
            let request = try RemoteAgent.buildRequest(
                [RemoteAgentMessage(role: "user", text: "hello")],
                tools: RemoteToolSchemas(json: []), config: config(),
                playerContext: "ctx", learned: learned
            )
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            // The dialect puts it in `system` or as the first `messages` entry.
            if let system = json["system"] as? String { return system }
            // Anthropic sends `system` as an array of content blocks. Pull the *text* out
            // rather than re-serialising the blocks: JSON object key order is not stable, so
            // serialising turns "identical prompt" into "different bytes" at random. That is
            // the second time this exact mistake has been made in this file, one level
            // deeper each time — compare meaning, never encodings.
            if let blocks = json["system"] as? [[String: Any]] {
                return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            let messages = (json["messages"] as? [[String: Any]]) ?? []
            return messages.first { ($0["role"] as? String) == "system" }?["content"] as? String ?? ""
        }

        XCTAssertEqual(try systemPrompt(learned: nil), try systemPrompt(learned: nil))
        XCTAssertNotEqual(try systemPrompt(learned: "- something learned"),
                          try systemPrompt(learned: nil),
                          "a correction that does not change the prompt is not being applied")
    }
}

/// The gaps a Fable 5 review found, each of which made the feature quietly untrue.
@MainActor
final class FriendLearningReviewFixTests: XCTestCase {
    private func makeStore() -> FriendLearningStore {
        FriendLearningStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("review-\(UUID().uuidString).json"))
    }

    /// A chat bridge has no fault buttons, so its thumbs-down arrives with words instead.
    /// Requiring a fault meant every bridge rating was discarded — the store that reached a
    /// model was permanently empty while the one with contents never reached one.
    func testAThumbsDownWithWordsButNoFaultStillTeaches() {
        let store = makeStore()
        let learned = store.learn(from: FriendExchange(
            surface: .telegram, request: "play my trance", reply: "…",
            rating: .down, fault: nil, note: "I meant Classic Trance"))
        XCTAssertNotNil(learned, "a bridge thumbs-down with words taught nothing")
        XCTAssertEqual(learned?.note, "I meant Classic Trance")
    }

    /// …but a bare thumbs-down with neither a fault nor words teaches nothing, and must not
    /// burn one of twelve slots saying "that was wrong" to no purpose.
    func testABareThumbsDownTeachesNothing() {
        let store = makeStore()
        XCTAssertNil(store.learn(from: FriendExchange(
            surface: .telegram, request: "play something", reply: "…", rating: .down)))
        XCTAssertTrue(store.corrections.isEmpty)
    }

    /// The correction has to say what the friend actually did, or the model has nothing to
    /// update on: same request, same priors, one slot gone.
    func testTheCorrectionCarriesWhatItDid() {
        let store = makeStore()
        let exchange = FriendExchange(
            surface: .phone, request: "play my trance", reply: "…",
            actions: [.init(tool: "music_search", arguments: "query: trance", succeeded: true)],
            played: ["Something Wrong"], rating: .down, fault: .wrongTrack)
        let learned = store.learn(from: exchange)
        XCTAssertTrue(learned?.promptLine.contains("Something Wrong") ?? false,
                      "the correction does not say what was played, so it teaches nothing")
    }

    /// A better-explained complaint about the same request replaces the vague earlier one
    /// instead of being dropped.
    func testANewerCorrectionReplacesTheOlder() {
        let store = makeStore()
        store.learn(from: FriendExchange(surface: .phone, request: "play my trance", reply: "…",
                                         rating: .down, fault: .wrongTrack))
        store.learn(from: FriendExchange(surface: .phone, request: "play my trance", reply: "…",
                                         rating: .down, fault: .misunderstood,
                                         note: "I meant Classic Trance"))
        XCTAssertEqual(store.corrections.count, 1)
        XCTAssertEqual(store.corrections.first?.note, "I meant Classic Trance")
    }

    /// Approval of the same words retires the complaint. Without this nothing ever expires,
    /// and a correction keeps shaping answers after the problem is fixed.
    func testApprovalRetiresAnOlderComplaint() {
        let store = makeStore()
        store.learn(from: FriendExchange(surface: .phone, request: "play my trance", reply: "…",
                                         rating: .down, fault: .wrongTrack))
        XCTAssertEqual(store.corrections.count, 1)

        store.retireIfApproved(FriendExchange(surface: .phone, request: "play my trance",
                                              reply: "…", rating: .up))
        XCTAssertTrue(store.corrections.isEmpty)
    }
}

/// The three improvements the review asked for.
@MainActor
final class FriendReviewSuggestionTests: XCTestCase {
    private func makeLearning() -> FriendLearningStore {
        FriendLearningStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sugg-\(UUID().uuidString).json"))
    }

    private func makeMemory() -> RemoteMemoryStore {
        RemoteMemoryStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mem-\(UUID().uuidString).json"))
    }

    private func makeLog() -> FriendFeedbackLog {
        FriendFeedbackLog(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sugg-log-\(UUID().uuidString).json"))
    }

    // MARK: 1 — words become memory, not a second store

    /// "I meant Classic Trance" is not a complaint, it is a statement of what they mean —
    /// which the memory store already holds, with provenance and a UX people know.
    func testWordsBecomeAMemoryRatherThanACorrection() throws {
        let learning = makeLearning()
        let memory = makeMemory()
        learning.memory = memory

        let stored = learning.learn(from: FriendExchange(
            surface: .phone, request: "play my trance", reply: "…",
            rating: .down, fault: .wrongTrack, note: "I meant Classic Trance"))

        XCTAssertNil(stored, "words should not also be stored as a correction — that is two memory stores")
        let entry = try XCTUnwrap(memory.entries.first)
        XCTAssertEqual(entry.quote, "I meant Classic Trance", "the memory must quote them verbatim")
        XCTAssertTrue(entry.text.contains("play my trance"))
        XCTAssertTrue(memory.rendered()?.contains("Classic Trance") ?? false,
                      "the memory never reaches the model")
    }

    /// A fault with no words has nowhere else to go: memory cannot express "you played X
    /// and that was wrong", so the evidence line stays here.
    func testAFaultWithoutWordsStaysAnEvidenceCorrection() {
        let learning = makeLearning()
        learning.memory = makeMemory()
        let stored = learning.learn(from: FriendExchange(
            surface: .phone, request: "play my trance", reply: "…",
            played: ["Something Wrong"], rating: .down, fault: .wrongTrack))
        XCTAssertNotNil(stored)
        XCTAssertTrue(stored?.promptLine.contains("Something Wrong") ?? false)
    }

    // MARK: 2 — the skip signal, recorded and never learned from

    func testAQuickSkipIsRecordedAgainstWhatTheFriendStarted() {
        let log = makeLog()
        log.record(FriendExchange(surface: .phone, request: "play something", reply: "…",
                                  played: ["A Track"]))
        XCTAssertTrue(log.noteQuickSkip(), "the skip was not attributed to the exchange that started it")
        XCTAssertTrue(log.exchanges[0].skippedQuickly)
        XCTAssertEqual(log.quicklySkipped.count, 1)
    }

    /// Outside the window it is an ordinary track change, not a rejection.
    func testALaterTrackChangeIsNotASkip() {
        let log = makeLog()
        log.record(FriendExchange(date: Date().addingTimeInterval(-600),
                                  surface: .phone, request: "play something", reply: "…",
                                  played: ["A Track"]))
        XCTAssertFalse(log.noteQuickSkip())
        XCTAssertFalse(log.exchanges[0].skippedQuickly)
    }

    /// An exchange that started nothing cannot be skipped — a question is not a track.
    func testAnAnswerThatPlayedNothingIsNeverMarkedSkipped() {
        let log = makeLog()
        log.record(FriendExchange(surface: .phone, request: "what's playing?", reply: "Yello"))
        XCTAssertFalse(log.noteQuickSkip())
    }

    /// The learning store must stay blind to it. Implicit signals are where a recommender
    /// starts inventing a person: a skip can mean "wrong", "heard it yesterday", or "the
    /// phone rang".
    func testTheLearningStoreIgnoresSkipsEntirely() {
        let learning = makeLearning()
        learning.memory = makeMemory()
        let skipped = FriendExchange(surface: .phone, request: "play something", reply: "…",
                                     played: ["A Track"], skippedQuickly: true)
        XCTAssertNil(learning.learn(from: skipped),
                     "a skip taught the friend something — only explicit ratings may")
    }

    // MARK: 3 — what it was looking at

    func testTheCandidatesItSawAreKeptAndBounded() {
        let long = (1 ... 40).map { "Track \($0) — Some Artist" }.joined(separator: "\n")
        let head = RemoteAgent.candidateHead(long)
        XCTAssertTrue(head.contains("Track 1"), "the head is where the candidates are")
        XCTAssertFalse(head.contains("Track 30"), "the tail answers no question and must not be kept")
        XCTAssertLessThanOrEqual(head.count, 401)
    }
}
