import XCTest
@testable import BatonAgentKit

@MainActor
final class FriendEvalExportTests: XCTestCase {
    private func down(_ request: String, _ fault: FriendExchange.Fault, note: String? = nil) -> FriendExchange {
        FriendExchange(surface: .phone, request: request, reply: "…", rating: .down, fault: fault, note: note)
    }

    func testItExportsOnlyFaultsAnAssertionCanHold() {
        let exported = FriendEvalExport.swiftCases(from: [
            down("play my trance", .wrongTrack),
            down("something for cooking", .misunderstood),
            down("play something", .tooChatty),
            down("play something else", .tooSlow),
            FriendExchange(surface: .phone, request: "good one", reply: "…", rating: .up),
        ])
        XCTAssertTrue(exported.contains("play my trance"))
        XCTAssertTrue(exported.contains("something for cooking"))
        XCTAssertFalse(exported.contains("tooChatty"),
                       "style is not something a test can assert without inventing a threshold")
        XCTAssertFalse(exported.contains("play something else"))
        XCTAssertFalse(exported.contains("good one"))
    }

    /// Verbatim, quotes and all — a case whose text has been tidied is no longer the failure
    /// that happened.
    func testItEscapesRatherThanRewrites() {
        let exported = FriendEvalExport.swiftCases(from: [down("play \"Blue\" by Yello", .wrongTrack)])
        XCTAssertTrue(exported.contains("\\\"Blue\\\""), "quotes must be escaped, not stripped")
    }

    func testTheSameComplaintIsExportedOnce() {
        let exported = FriendEvalExport.swiftCases(from: [
            down("play my trance", .wrongTrack),
            down("Play My Trance", .misunderstood),
        ])
        XCTAssertEqual(exported.components(separatedBy: "Case(message:").count - 1, 1)
    }

    func testNothingRatedProducesNothing() {
        XCTAssertTrue(FriendEvalExport.swiftCases(from: []).isEmpty)
    }
}

extension FriendEvalExportTests {
    /// The fault cannot decide the expectation, and guessing enshrines the bug.
    ///
    /// The archetypal "misunderstood" failure here is starting music in answer to a
    /// *question*. Exporting that as `expect: .plays` would make the release gate assert
    /// the very behaviour that was complained about.
    func testMisunderstoodIsNotExportedAsAnExpectationToPlay() {
        let exported = FriendEvalExport.swiftCases(from: [
            FriendExchange(surface: .phone, request: "do I have any Coltrane?", reply: "…",
                           rating: .down, fault: .misunderstood),
        ])
        XCTAssertTrue(exported.contains("TODO"),
                      "a misunderstanding was exported as a live expectation to play")
        XCTAssertFalse(exported.contains("\n        Case(message: \"do I have any Coltrane?\""),
                       "it must not be an active case until a human picks the expectation")
    }

    /// The rating prompt and the exporter must agree about which faults carry a "should have".
    ///
    /// They disagreed once by construction: the rule lived only in `swiftCases`, so the phone
    /// never asked for a note, and the first two real ratings both exported as TODOs nobody
    /// could resolve without guessing. Asserted against `allCases` so a fifth fault fails here
    /// rather than silently joining one side.
    func testOnlyFaultsWithAnExpectationExport() {
        for fault in FriendExchange.Fault.allCases {
            let exported = FriendEvalExport.swiftCases(from: [down("play my trance", fault)])
            XCTAssertEqual(!exported.isEmpty, fault.hasObservableExpectation,
                           "\(fault.rawValue) exports but does not carry an expectation, or vice versa")
        }
    }

    /// The note is the whole point of asking, so it has to survive into the artifact — and
    /// be readable as a quote rather than as something the exporter made up.
    func testTheirOwnWordsReachTheExportedCase() {
        let exported = FriendEvalExport.swiftCases(from: [
            FriendExchange(surface: .phone, request: "Show tracks", reply: "…",
                           rating: .down, fault: .misunderstood,
                           note: "list them, don't play them"),
        ])
        XCTAssertTrue(exported.contains("they said: list them, don't play them"),
                      "the note never reached the case a human has to decide")
        XCTAssertFalse(exported.contains("rated misunderstood on"),
                       "a real note was replaced by the fallback remark")
    }

    /// A multi-line request would otherwise emit Swift that does not compile.
    func testNewlinesInARequestDoNotBreakTheOutput() {
        let exported = FriendEvalExport.swiftCases(from: [
            FriendExchange(surface: .phone, request: "play something\nquiet", reply: "…",
                           rating: .down, fault: .wrongTrack),
        ])
        XCTAssertTrue(exported.contains("play something quiet"))
        XCTAssertFalse(exported.contains("play something\nquiet"))
    }
}
