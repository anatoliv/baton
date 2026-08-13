import XCTest
@testable import BatonPlaybackKit

/// The source-text helper, tested over synthetic source.
///
/// Worth its own suite for one reason: a bug in `SourceInvariant` produces a red gate that
/// *names the code under test*. That is precisely the failure mode it was written to
/// abolish — an anchor firing on something it does not guard, mid-refactor, with a message
/// asserting a behavioural claim it cannot support. If the parsing is wrong, this file goes
/// red and says so in its own name.
///
/// Each case here is a real refactor that broke a real anchor in this target on 2026-08-12,
/// or a way the old anchors could have passed while guarding nothing.
final class SourceInvariantTests: XCTestCase {

    // MARK: The decorations that must not matter

    /// The exact refactor that broke `testMeteringIsTiedToTheOwnershipTransition`: the
    /// property became `public private(set)` so the UI could observe ownership, and an
    /// anchor that included the visibility called it a metering regression.
    func testAPropertyIsFoundThroughAnyVisibilityOrAttribute() throws {
        for declaration in [
            "private var engineOwnsPlayback = false {",
            "public private(set) var engineOwnsPlayback = false {",
            "@ObservationIgnored public private(set) var engineOwnsPlayback: Bool = false {",
            "    var engineOwnsPlayback = false {",
        ] {
            let source = """
            final class C {
            \(declaration)
                    didSet { suspendMetering() }
                }
            }
            """
            let block = try SourceInvariant.observerBlock(of: "engineOwnsPlayback", in: source)
            XCTAssertTrue(block.contains("suspendMetering()"),
                          "the observer block was not found through `\(declaration)`")
        }
    }

    /// The same for functions: `private` is not part of the rule, and neither is `@MainActor`
    /// or a `throws`.
    func testAFunctionIsFoundThroughAnyVisibilityOrAttribute() throws {
        for declaration in [
            "private func beginSkipBlend(to index: Int) -> Bool {",
            "func beginSkipBlend(to index: Int) -> Bool {",
            "@MainActor public func beginSkipBlend(to index: Int) async throws -> Bool {",
        ] {
            let source = """
            final class C {
                \(declaration)
                    guard !engineOwnsPlayback else { return false }
                    return true
                }
            }
            """
            let body = try SourceInvariant.functionBody(of: "beginSkipBlend", in: source)
            XCTAssertTrue(body.contains("!engineOwnsPlayback"),
                          "the body was not found through `\(declaration)`")
        }
    }

    /// A signature that wraps — which this codebase does constantly — must not truncate the
    /// body, and a brace inside the parameter list must not be mistaken for its start.
    func testAMultiLineSignatureIsNotMistakenForTheBody() throws {
        let source = """
        final class C {
            private func load(
                track: Track,
                startingAt offset: Double = 0,
                onDone: @escaping () -> Void = {}
            ) {
                abandonOwedPause()
            }
        }
        """
        let body = try SourceInvariant.functionBody(of: "load", in: source)
        XCTAssertTrue(body.contains("abandonOwedPause()"))
        XCTAssertFalse(body.contains("startingAt"), "the parameter list leaked into the body")
    }

    // MARK: The bound

    /// The false pass the `prefix(1800)` windows allowed: a match that came from the *next*
    /// function entirely, so the invariant quietly stopped being guarded.
    func testABodyStopsAtItsOwnClosingBrace() throws {
        let source = """
        final class C {
            private func maybeStartCrossfade() {
                let x = 1
            }

            private func beginSkipBlend() {
                guard !engineOwnsPlayback else { return }
            }
        }
        """
        let body = try SourceInvariant.functionBody(of: "maybeStartCrossfade", in: source)
        XCTAssertTrue(body.contains("let x = 1"))
        XCTAssertFalse(
            body.contains("!engineOwnsPlayback"),
            "the body ran past its closing brace into the next function — an invariant asserted this way is satisfied by a line that has nothing to do with it"
        )
    }

    /// The failure that three tests hit in one afternoon: a growing comment pushed the guard
    /// past a hand-sized window. Braces make the length irrelevant.
    func testAGrowingCommentDoesNotPushTheGuardOutOfView() throws {
        let padding = String(repeating: "    // explanation that keeps growing, as they do\n", count: 200)
        let source = """
        final class C {
            private func beginSkipBlend() {
        \(padding)
                guard !engineOwnsPlayback else { return }
            }
        }
        """
        let body = try SourceInvariant.functionBody(of: "beginSkipBlend", in: source)
        XCTAssertTrue(body.contains("!engineOwnsPlayback"))
    }

    /// A stored property with no observer must **fail**, not adopt the braces of whatever is
    /// declared beneath it. Losing the `didSet` is the drift the metering test exists for,
    /// and it is the one case where a wrong answer is silent.
    func testAPropertyWithNoObserverFailsRatherThanBorrowingTheNextBody() {
        let source = """
        final class C {
            private var engineOwnsPlayback = false

            private func suspendMeteringSomewhereElse() {
                suspendMetering()
            }
        }
        """
        XCTAssertThrowsError(try SourceInvariant.observerBlock(of: "engineOwnsPlayback", in: source)) { error in
            let failure = error as? SourceInvariant.Failure
            XCTAssertNotNil(failure, "expected a SourceInvariant.Failure, got \(error)")
            XCTAssertTrue(failure?.message.contains("no observer block") == true,
                          "the message does not explain the likeliest cause")
        }
    }

    // MARK: What can hide a brace

    /// Braces in comments and string literals are text. Counting them lands the matcher in
    /// the middle of the next declaration.
    func testBracesInsideCommentsAndStringsAreNotStructure() throws {
        let source = #"""
        final class C {
            private func beginSkipBlend() {
                // a stray } in a line comment
                /* and a nested /* block } comment */ too */
                let template = "a } inside a string"
                let multi = """
                    and a } inside a multiline one
                    """
                let escaped = "an escaped \" and then }"
                guard !engineOwnsPlayback else { return }
            }

            private func next() {
                let unreachable = 1
            }
        }
        """#
        let body = try SourceInvariant.functionBody(of: "beginSkipBlend", in: source)
        XCTAssertTrue(body.contains("!engineOwnsPlayback"), "the body ended early on a brace that was text")
        XCTAssertFalse(body.contains("unreachable"), "the body ran into the next function")
    }

    // MARK: Identifiers

    /// `func next` must not match `func nextTrack`, and `var engineDeck` must not match
    /// `var engineDeckBridge` — otherwise the anchor guards a neighbour.
    func testAnAnchorDoesNotMatchALongerIdentifier() throws {
        let source = """
        final class C {
            private func nextTrack() {
                let wrong = 1
            }

            private func next() {
                let right = 1
            }
        }
        """
        let body = try SourceInvariant.functionBody(of: "next", in: source)
        XCTAssertTrue(body.contains("let right = 1"))
        XCTAssertFalse(body.contains("let wrong = 1"))
    }

    /// A name that is genuinely absent must throw a `Failure`, not return an empty body that
    /// then fails a `contains` check with a message about behaviour.
    func testAMissingDeclarationThrowsRatherThanReturningNothing() {
        XCTAssertThrowsError(try SourceInvariant.functionBody(of: "neverExisted", in: "final class C {}")) { error in
            XCTAssertTrue((error as? SourceInvariant.Failure)?.message.contains("neverExisted") == true)
        }
    }

    // MARK: The message

    /// The point of the whole exercise: a source-text failure must not assert a behavioural
    /// claim it is in no position to make.
    func testTheFailureMessageStatesWhatItCheckedAndWhatItCannotKnow() {
        let message = SourceInvariant.Failure(
            rule: "the metering switch lives on the engineOwnsPlayback observer",
            searched: "`suspendMetering()` in the observer block",
            file: #filePath, line: #line
        ).message

        XCTAssertTrue(message.contains("the metering switch lives on"), "the rule is not stated")
        XCTAssertTrue(message.contains("Searched for"), "the search is not stated")
        XCTAssertTrue(message.contains("reads the source as text"),
                      "the message does not admit that it cannot see behaviour — which is how these tests cried wolf")
        XCTAssertTrue(message.contains("move the anchor with it"),
                      "the message does not tell the reader what to do when the rule moved on purpose")
    }
}
