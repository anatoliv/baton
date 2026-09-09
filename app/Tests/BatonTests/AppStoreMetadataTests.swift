import XCTest

/// The App Store listing, checked like code.
///
/// Before `ios/metadata/en-US.json` existed, this metadata lived only in a web form: typed
/// once at submission and never read back. Nobody noticed that a third of the keyword field
/// was spent on words already in the name and subtitle until it was pulled through the API
/// two weeks after launch, and nobody would have noticed if it drifted.
///
/// This half is static: it reads the file and asserts over its contents, so it runs offline
/// in the ordinary suite. The half that talks to Apple — is the repo still what is actually
/// published? — is `ios/scripts/app-store-metadata.py check`, which `scripts/test.sh` runs
/// separately because it needs credentials and a network. Neither substitutes for the other:
/// this one catches a bad value before it ships, that one catches a value changed behind the
/// repo's back.
///
/// The failure it guards against bit twice. First as that waste. Then again while proposing
/// a fix: a replacement keyword string included `ampache` and `airsonic`, neither of which
/// Baton supports — both trace to one doc comment about which servers implement the podcast
/// API. Shipping that is an App Review 2.3.7 rejection. It was caught by a person asking a
/// question, which is exactly the kind of catch that should not depend on one.
final class AppStoreMetadataTests: XCTestCase {

    // MARK: - Apple's limits

    private let nameLimit = 30
    private let subtitleLimit = 30
    private let keywordsLimit = 100

    /// How many times a keyword must appear in the product sources and user docs before it
    /// counts as a claim the app can support.
    ///
    /// Measured 2026-09-07 by the same `git grep` this test runs. The gap is what makes this
    /// a discriminator rather than a round number: the lowest-scoring keyword actually in the
    /// field is `flac` at 27 (`self-hosted` 33, `airplay` 52, `radio` 451), while every term
    /// that had to be rejected scores 7 or less: `ampache` 2, `airsonic` 3, `nas` 2, `opus` 7,
    /// `sonos` 7. Fifteen sits in open space between 7 and 27. (`opensubsonic`, 35, was in the
    /// keyword field when those numbers were taken. It has since moved into the subtitle,
    /// where `testNoKeywordRepeatsTheNameOrSubtitle` would now reject it as a keyword.)
    ///
    /// **Two corrections, both of which had made an earlier version of this check weaker than
    /// it looked.** The first draft counted substrings, so `ogg` scored 650 on `toggle` and
    /// `Logger` and would have sailed past any threshold; it counts whole words now. And it
    /// counted the whole tree including this file, so the comments above — which name the
    /// rejected keywords in order to explain them — were inflating the score of the exact
    /// terms the check exists to reject. `ampache` had climbed from 2 to 5 that way within
    /// hours of the guard being written. Test sources are excluded, so a keyword has to be
    /// backed by product code or documentation a user reads.
    ///
    /// This is a backstop, not a proof: a grep cannot tell support from a mention. Its job is
    /// to make an unsupported claim fail loudly rather than ship quietly.
    private let minimumMentions = 15

    /// Keywords below the mention threshold that are legitimate anyway, each with the reason.
    ///
    /// Empty today, and an entry here should be rare and argued. A keyword nobody can justify
    /// is a keyword that should not be in the field.
    private static let justifiedBelowThreshold: [String: String] = [:]

    /// Keywords that repeat a word already in the name or subtitle, with the reason each is
    /// staying for now.
    ///
    /// **Empty, because the debt is paid.** It held `navidrome`, `subsonic`, `music` and
    /// `player`: 28 characters plus separators, about a third of a hard 100-byte field,
    /// bought twice, since Apple pools the three fields and recombines terms across them.
    /// They are gone from the desired keywords, and since the 2026-09-07 push they
    /// are gone from `_live` too, so the live listing no longer carries them either.
    ///
    /// Leave it empty unless a repeat genuinely has to stay. An entry here is visible debt,
    /// and the test fails both when an unrecorded repeat appears and when an entry outlives
    /// the repeat it describes.
    private static let knownDuplicateKeywords: [String: String] = [:]

    // MARK: - The listing

    private struct Metadata: Decodable {
        let name: String
        let subtitle: String
        let keywords: String
        let promotionalText: String
        let marketingUrl: String
        let supportUrl: String
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BatonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
    }

    /// The `desired` half of the file: what we intend to ship.
    ///
    /// Not `_live`, deliberately. `_live` is whatever Apple currently holds, which is by
    /// definition something App Review already accepted and which this repo cannot change
    /// without a release. Asserting over it would make the test a description of the past.
    /// The half worth guarding is the one a person edits and a release pushes.
    private func metadata() throws -> Metadata {
        let url = repoRoot().appendingPathComponent("ios/metadata/en-US.json")
        struct Document: Decodable { let desired: Metadata }
        return try JSONDecoder().decode(Document.self, from: try Data(contentsOf: url)).desired
    }

    private func keywords(_ m: Metadata) -> [String] {
        m.keywords.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    // MARK: - Apple will reject these outright

    func testFieldsAreWithinApplesLimits() throws {
        let m = try metadata()
        XCTAssertLessThanOrEqual(m.name.count, nameLimit,
                                 "name is \(m.name.count) characters, limit \(nameLimit)")
        XCTAssertLessThanOrEqual(m.subtitle.count, subtitleLimit,
                                 "subtitle is \(m.subtitle.count) characters, limit \(subtitleLimit)")
        XCTAssertLessThanOrEqual(m.keywords.count, keywordsLimit,
                                 "keywords field is \(m.keywords.count) characters, limit \(keywordsLimit)")
    }

    func testKeywordsAreNotEmptyOrDuplicated() throws {
        let m = try metadata()
        let words = keywords(m)
        XCTAssertFalse(words.isEmpty, "no keywords at all")
        XCTAssertEqual(Set(words).count, words.count,
                       "the same keyword appears twice: \(words.filter { w in words.filter { $0 == w }.count > 1 })")

        // Split again keeping the empties. `keywords(_:)` drops them, which is the right
        // behaviour everywhere else and the wrong one here: written the obvious way, an
        // assertion that no keyword is blank could never have fired, because the stray comma
        // producing the blank is exactly what the default split throws away. Apple ignores
        // the empty term too, so this costs a byte rather than a rejection, but a check that
        // cannot fail is worse than no check.
        let raw = m.keywords.split(separator: ",", omittingEmptySubsequences: false)
        let blanks = raw.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue(blanks.isEmpty,
                      "\(blanks.count) empty keyword(s) in '\(m.keywords)' — a stray or doubled comma")
    }

    // MARK: - The defect this file exists for

    /// A keyword repeating a word from the name or subtitle earns nothing and costs budget.
    /// Every one that does must be written down as known debt; a new one fails.
    func testNoKeywordRepeatsTheNameOrSubtitle() throws {
        let m = try metadata()
        let owned = Set((m.name + " " + m.subtitle)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))

        let repeated = keywords(m).filter { owned.contains($0) }
        let undeclared = repeated.filter { Self.knownDuplicateKeywords[$0] == nil }
        XCTAssertTrue(undeclared.isEmpty, """
            These keywords repeat a word already in the name or subtitle, and are not \
            recorded as known debt: \(undeclared.sorted()).
            Apple pools the three fields, so a repeat buys nothing and spends characters \
            from a hard 100-byte budget. Either drop the keyword, or add it to \
            knownDuplicateKeywords with the reason it is staying for now.
            """)

        // A stale entry is as misleading as a missing one: it describes debt that is paid.
        let stale = Self.knownDuplicateKeywords.keys.filter { !repeated.contains($0) }
        XCTAssertTrue(stale.isEmpty, """
            knownDuplicateKeywords still lists \(stale.sorted()), which no longer repeat the \
            name or subtitle. Remove them — a table that describes a world that no longer \
            exists reads as settled and is worse than no table.
            """)
    }

    /// Every keyword must be a claim the codebase can back.
    ///
    /// This is the check that would have stopped `ampache` and `airsonic`. Both appear in the
    /// tree — in one doc comment about which servers implement the podcast API — so any test
    /// asking merely "does this word exist somewhere" would have passed them.
    func testEveryKeywordIsAClaimTheAppCanSupport() throws {
        let words = keywords(try metadata())
        var unsupported: [String] = []

        for word in words where Self.justifiedBelowThreshold[word] == nil {
            let n = mentions(of: word)
            if n < minimumMentions { unsupported.append("\(word) (\(n) mentions)") }
        }

        XCTAssertTrue(unsupported.isEmpty, """
            These keywords are not backed by the codebase: \(unsupported.sorted()).
            Fewer than \(minimumMentions) mentions across the sources and docs means the app \
            probably does not do this, and an inaccurate listing is an App Review 2.3.7 \
            rejection. Either drop the keyword, or add it to justifiedBelowThreshold with the \
            reason it is true anyway.
            """)

        let stale = Self.justifiedBelowThreshold.keys.filter { !words.contains($0) }
        XCTAssertTrue(stale.isEmpty,
                      "justifiedBelowThreshold lists \(stale.sorted()), which are no longer keywords")
    }

    /// Whole-word, case-insensitive occurrences across the product sources and the two root
    /// documents, excluding test code.
    ///
    /// `git grep` rather than a file walk: it already honours .gitignore, so the derived data
    /// and `.build` trees that dwarf the real sources never enter the count. `-w` rather than
    /// a bare substring, and the two exclusions, for the reasons on `minimumMentions` — both
    /// were holes that let a term score without being supported.
    private func mentions(of term: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = repoRoot()
        p.arguments = ["grep", "-oihw", "--", term,
                       "--", "*.swift", "README.md", "HELP.md",
                       ":(exclude)*Tests*", ":(exclude)*/Tests/*"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).count
    }
}
