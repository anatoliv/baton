import XCTest
@testable import BatonPlaybackKit

/// One question, asked one way: *does the engine own playback right now?*
///
/// It used to be asked three ways. `engineOwnsPlayback` at the transport, `engineDeck == nil`
/// in the skip-blend path, and `model.engineBridge != nil` in the UI — and two of the three
/// were wrong, because attachment is not ownership: a deck exists from the moment one is
/// installed, while it owns playback only for the tracks it actually took. Each drift shipped.
/// Stage 3 narrowed all three to ownership; this keeps them narrowed.
///
/// A source-text test, deliberately, and the reasoning is `SourceInvariant`'s: the failure
/// being guarded is a rule spread across call sites and missed at one of them, which no
/// behavioural test catches without standing up two players and a deck. So it reads the file
/// and says exactly what it searched for.
final class EngineRoutingPredicateTests: XCTestCase {

    /// Comments talk about the retired predicates on purpose — that is how the history stays
    /// legible — so only executable lines are searched.
    private func code(of fileName: String) throws -> [(line: Int, text: String)] {
        try SourceInvariant.source(fileName)
            .components(separatedBy: .newlines)
            .enumerated()
            .map { (line: $0.offset + 1, text: $0.element) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    func testRoutingAsksAboutOwnershipAndNotAboutAttachment() throws {
        let lines = try code(of: "StreamingPlaybackController.swift")

        // `engineDeck != nil` is deliberately absent from this list, and the first version of
        // this test failed because of it — on correct code, which is the failure mode
        // `SourceInvariant`'s own doc warns about. Asking whether a deck exists is a
        // legitimate question about the **incoming** track (`beginSkipBlend` must not blend
        // into an AVPlayer item for a track that would route to the deck; ownership is
        // decided at load, and that blend loads its own item). What shipped wrong twice was
        // attachment standing in for ownership of the track playing *now* — these two.
        for retired in ["engineDeck == nil", "engineBridge != nil"] {
            let offenders = lines.filter { $0.text.contains(retired) }
            XCTAssertTrue(offenders.isEmpty, """
                `\(retired)` is back as a live predicate at line(s) \(offenders.map(\.line)).
                That asks whether a deck is *attached*, which is not whether it is *playing* — \
                the distinction that shipped wrong twice. Use `engineOwnsPlayback`. \
                (Searched executable lines of StreamingPlaybackController.swift for the literal.)
                """)
        }
    }

    /// The positive half: the predicate that replaced them is still the one in use, so this
    /// cannot pass by everything having been renamed out from under it.
    func testOwnershipIsStillTheQuestionBeingAsked() throws {
        let lines = try code(of: "StreamingPlaybackController.swift")
        let uses = lines.filter { $0.text.contains("engineOwnsPlayback") }

        XCTAssertGreaterThan(uses.count, 10, """
            `engineOwnsPlayback` has nearly vanished from StreamingPlaybackController \
            (\(uses.count) executable lines mention it). Either routing moved somewhere this \
            test cannot see, or it is being asked another way again.
            """)
    }
}
