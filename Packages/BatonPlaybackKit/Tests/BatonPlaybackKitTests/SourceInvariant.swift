import XCTest

/// Reading the source as text to pin a structural rule — done so it stops crying wolf.
///
/// Several tests in this target assert that a guard or an observer block is *present* in
/// `StreamingPlaybackController.swift` rather than driving the behaviour. That is a good
/// idea and it has earned its place: this codebase has shipped drift that no behavioural
/// test could have caught, because the drift was a rule spread across call sites and missed
/// at one of them, and constructing two live AVPlayers plus an engine deck to prove it
/// would break far more often than it would catch anything.
///
/// What was not a good idea was the anchors. They pinned syntax that carries none of the
/// meaning, and twice in one day (2026-08-12) they failed on correct code:
///
/// - `"private var engineOwnsPlayback = false {"` broke when the property became
///   `public private(set)` so the UI could observe ownership — while the rule it guards,
///   that the metering switch lives on the observer rather than at the five assignment
///   sites, had not moved by a line. The failure message read *"metering will run forever
///   again"*, which was false, and it read that way mid-refactor, when a red gate is at its
///   most expensive to interpret.
/// - `"engineDeck == nil"` was a legitimate catch, but the test still had to be edited as
///   part of the fix, so a reviewer had to decide from scratch whether red meant drift or
///   churn.
///
/// Three rules follow, and this type exists to make them the path of least resistance:
///
/// **Anchor on the identifier and the structural token, never on the decoration.**
/// `func <name>`, `var <name> … {`. Visibility, `@MainActor`, `static`, `let` vs `var`, an
/// initial value — none of it carries the rule, and every one of them is a live refactor
/// that would fire a false alarm.
///
/// **Bound a body by its braces, not by a character count or by the next `private func`.**
/// A `prefix(1800)` window tests the guess: too short and a growing comment pushes the
/// guard out of view (three tests failed that way in one afternoon), too long and an
/// invariant silently stops being guarded because the match came from the *next* function.
///
/// **Say what was checked and what was not.** A source-text test knows one thing: whether
/// a string is present. It does not know whether the behaviour works. So every failure
/// message here names the search, and says so — see `Failure.message`. "The metering switch
/// is no longer on the `engineOwnsPlayback` observer (searched the observer block for
/// `suspendMetering()`)" is honest. "Metering will run forever again" is not, when the
/// observer is sitting right there.
///
/// The parsing is deliberately tested — `SourceInvariantTests` drives it over synthetic
/// source — because a bug *in here* would produce exactly the false red this type exists to
/// abolish, and it would be blamed on the code under test.
enum SourceInvariant {

    // MARK: Loading

    /// A file under `Sources/BatonPlaybackKit/`, by name.
    ///
    /// The four chained `deletingLastPathComponent()` calls were copy-pasted into five
    /// tests, each with its own comment explaining the same three hops. One copy.
    static func source(
        _ fileName: String,
        testFile: StaticString = #filePath
    ) throws -> String {
        let url = URL(fileURLWithPath: "\(testFile)")
            .deletingLastPathComponent()   // BatonPlaybackKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BatonPlaybackKit
            .appendingPathComponent("Sources/BatonPlaybackKit/\(fileName)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Finding declarations

    /// The body of a function, bounded by its own braces.
    ///
    /// Matched on `func <name>` alone: any visibility, any attribute, any generic clause or
    /// parameter list. The returned string starts after the opening brace and ends before
    /// the matching close.
    static func functionBody(
        of name: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try body(after: try declaration(keyword: "func", name: name, in: source, kind: "function",
                                        file: file, line: line),
                 in: source, of: "func \(name)", file: file, line: line)
    }

    /// The observer block (`didSet` / `willSet`) of a stored property.
    ///
    /// Matched on `var <name>` followed by an opening brace on the same declaration, so an
    /// initial value, a type annotation, a `public private(set)`, or a `@ObservationIgnored`
    /// may all come and go without touching this. The trailing brace is the load-bearing
    /// part: it is what says the property observes its own transitions at all.
    static func observerBlock(
        of name: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try body(after: try declaration(keyword: "var", name: name, in: source, kind: "property",
                                        file: file, line: line),
                 in: source, of: "var \(name)", sameLine: true, file: file, line: line)
    }

    /// The body of the closure that follows an expression — a trailing closure at a call
    /// site, where there is no declaration to anchor on.
    ///
    /// `addPeriodicTimeObserver` is the case in this target: the rule is about the order of
    /// two lines *inside* the observer, and the observer is an argument, not a function. The
    /// braces still bound it exactly, which is the whole point — the previous version of
    /// that test used `prefix(3000)` and failed the moment the guard above it grew a comment.
    static func closureBody(
        after anchor: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        guard let found = source.range(of: anchor) else {
            throw Failure(
                rule: "the call site `\(anchor)` exists",
                searched: "`\(anchor)`",
                file: file, line: line
            )
        }
        return try body(after: found.upperBound, in: source, of: anchor, file: file, line: line)
    }

    /// The offset just past `<keyword> <name>`, ignoring everything in front of it.
    ///
    /// Requires a non-identifier character before the keyword so `func loadCurrent` does not
    /// match `preloadCurrent`, and after the name so `var engineDeck` does not match
    /// `engineDeckBridge`.
    private static func declaration(
        keyword: String,
        name: String,
        in source: String,
        kind: String,
        file: StaticString,
        line: UInt
    ) throws -> String.Index {
        let needle = "\(keyword) \(name)"
        var search = source.startIndex
        while let found = source.range(of: needle, range: search ..< source.endIndex) {
            let beforeOK = found.lowerBound == source.startIndex
                || !isIdentifierCharacter(source[source.index(before: found.lowerBound)])
            let afterOK = found.upperBound == source.endIndex
                || !isIdentifierCharacter(source[found.upperBound])
            if beforeOK && afterOK { return found.upperBound }
            search = found.upperBound
        }
        throw Failure(
            rule: "the \(kind) `\(name)` exists",
            searched: "`\(needle)` (any visibility, attributes or modifiers)",
            file: file, line: line
        )
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// From a declaration, the text between its next opening brace and the matching close.
    ///
    /// `sameLine` is what stops a property with **no** observer silently borrowing the body
    /// of whatever is declared beneath it — which would be a false *pass*, the worst outcome
    /// available to a test like this: the invariant stops being guarded and nothing goes
    /// red. A `didSet` opens on the declaration line; the next `func` does not.
    private static func body(
        after start: String.Index,
        in source: String,
        of declaration: String,
        sameLine: Bool = false,
        file: StaticString,
        line: UInt
    ) throws -> String {
        guard let open = firstBrace(in: source, from: start, stoppingAtNewline: sameLine) else {
            throw Failure(
                rule: "`\(declaration)` has a body",
                searched: sameLine
                    ? "an opening brace on the declaration line — a property with no observer block looks exactly like this"
                    : "an opening brace after the declaration",
                file: file, line: line
            )
        }
        guard let close = matchingBrace(in: source, openingAt: open) else {
            throw Failure(
                rule: "`\(declaration)`'s body is balanced",
                searched: "the brace matching the one that opens it",
                file: file, line: line
            )
        }
        return String(source[source.index(after: open) ..< close])
    }

    // MARK: Brace matching

    /// The first `{` at nesting depth zero for parentheses and brackets — so a default
    /// argument or a return type may contain whatever it likes.
    ///
    /// A function signature may wrap across lines, so it scans on; a property observer may
    /// not, so `stoppingAtNewline` gives up at the end of the declaration rather than
    /// adopting the next declaration's braces.
    private static func firstBrace(
        in source: String,
        from start: String.Index,
        stoppingAtNewline: Bool
    ) -> String.Index? {
        var scanner = Scanner(source: source, from: start)
        var parens = 0
        var brackets = 0
        while let (index, character) = scanner.next() {
            switch character {
            case "(": parens += 1
            case ")": parens -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            case "{" where parens == 0 && brackets == 0: return index
            case "\n" where stoppingAtNewline && parens == 0 && brackets == 0: return nil
            default: continue
            }
        }
        return nil
    }

    /// The `}` matching an opening `{`, skipping comments and string literals.
    ///
    /// Braces inside a `"…"`, a `"""…"""`, a `//` comment or a `/* … */` (which nests in
    /// Swift) are text, not structure. Counting them is how a matcher lands in the middle of
    /// the next function and reports an invariant as satisfied by a line that has nothing to
    /// do with it.
    private static func matchingBrace(in source: String, openingAt open: String.Index) -> String.Index? {
        var scanner = Scanner(source: source, from: source.index(after: open))
        var depth = 1
        while let (index, character) = scanner.next() {
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// Walks Swift source, yielding only the characters that are *code*.
    ///
    /// Not a lexer — it understands exactly the four things that can hide a brace.
    private struct Scanner {
        private let source: String
        private var index: String.Index

        init(source: String, from start: String.Index) {
            self.source = source
            self.index = start
        }

        mutating func next() -> (String.Index, Character)? {
            while index < source.endIndex {
                let current = source[index]
                let following = peek(1)

                if current == "/" && following == "/" { skipLineComment(); continue }
                if current == "/" && following == "*" { skipBlockComment(); continue }
                if current == "\"" && following == "\"" && peek(2) == "\"" { skipMultilineString(); continue }
                if current == "\"" { skipString(); continue }

                let here = index
                index = source.index(after: index)
                return (here, current)
            }
            return nil
        }

        private func peek(_ offset: Int) -> Character? {
            guard let ahead = source.index(index, offsetBy: offset, limitedBy: source.endIndex),
                  ahead < source.endIndex
            else { return nil }
            return source[ahead]
        }

        private mutating func skipLineComment() {
            while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
        }

        /// Block comments nest in Swift, so this counts rather than searching for the first
        /// `*/`.
        private mutating func skipBlockComment() {
            var depth = 0
            while index < source.endIndex {
                if source[index] == "/" && peek(1) == "*" {
                    depth += 1
                    advance(2)
                    continue
                }
                if source[index] == "*" && peek(1) == "/" {
                    depth -= 1
                    advance(2)
                    if depth == 0 { return }
                    continue
                }
                index = source.index(after: index)
            }
        }

        private mutating func skipString() {
            advance(1)   // the opening quote
            while index < source.endIndex {
                if source[index] == "\\" { advance(2); continue }
                if source[index] == "\"" { advance(1); return }
                if source[index] == "\n" { return }   // unterminated; do not run off the file
                index = source.index(after: index)
            }
        }

        private mutating func skipMultilineString() {
            advance(3)   // the opening delimiter
            while index < source.endIndex {
                if source[index] == "\\" { advance(2); continue }
                if source[index] == "\"" && peek(1) == "\"" && peek(2) == "\"" { advance(3); return }
                index = source.index(after: index)
            }
        }

        private mutating func advance(_ count: Int) {
            index = source.index(index, offsetBy: count, limitedBy: source.endIndex) ?? source.endIndex
        }
    }

    // MARK: Asserting

    /// A source-text expectation, phrased so that failing says what it actually knows.
    ///
    /// `rule` is the invariant in the author's words. `contains` is the string this test
    /// looked for. The message joins them and then states the limit out loud, because the
    /// whole complaint against these tests is that a false positive asserted a behavioural
    /// claim it was in no position to make.
    static func assert(
        _ haystack: String,
        contains needle: String,
        rule: String,
        within: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            haystack.contains(needle),
            Failure(rule: rule, searched: "`\(needle)` in \(within)", file: file, line: line).message,
            file: file, line: line
        )
    }

    /// Two strings, in order. The usual shape here is "the guard stands before the write".
    static func assert(
        _ haystack: String,
        has first: String,
        before second: String,
        rule: String,
        within: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let firstRange = try XCTUnwrap(
            haystack.range(of: first),
            Failure(rule: rule, searched: "`\(first)` in \(within)", file: file, line: line).message,
            file: file, line: line
        )
        let secondRange = try XCTUnwrap(
            haystack.range(of: second),
            Failure(rule: rule, searched: "`\(second)` in \(within)", file: file, line: line).message,
            file: file, line: line
        )
        XCTAssertTrue(
            firstRange.upperBound <= secondRange.lowerBound,
            Failure(rule: rule,
                    searched: "`\(first)` before `\(second)` in \(within), and found it after",
                    file: file, line: line).message,
            file: file, line: line
        )
    }

    /// The failure text. One shape for every source-text assertion in the target.
    struct Failure: Error, CustomStringConvertible {
        let rule: String
        let searched: String
        let file: StaticString
        let line: UInt

        var message: String {
            """
            Source invariant not satisfied: \(rule).
            Searched for \(searched).
            This test reads the source as text. It can tell you the code no longer has the \
            shape this rule is written in; it cannot tell you the behaviour is broken. If \
            the rule moved deliberately, move the anchor with it.
            """
        }

        var description: String { message }
    }
}
