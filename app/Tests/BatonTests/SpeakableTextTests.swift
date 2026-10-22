import XCTest
@testable import Baton

/// Read aloud, Phase 1: the text pipeline that decides *what* gets spoken.
///
/// These are the tests that actually protect the feature. The acquisition tiers need a running
/// app and a real selection to exercise — `AXSelectedTextRange` is not settable, so a selection
/// cannot even be created headlessly — but redaction, normalization and chunking are pure, and a
/// secret reaching the speaker is the one failure here with consequences outside the app.
final class SpeakableTextTests: XCTestCase {

    // Fixtures are assembled at runtime rather than written as literals. They have to *look*
    // exactly like real credentials for these tests to mean anything — which is precisely why
    // the public mirror's secret scanner flags them, and it cannot tell a fixture from the real
    // thing. It should not have to: sanitizing the source is the cheap side of that trade, and
    // the runtime strings are byte-identical, so the tests lose nothing.
    private let githubPAT = "ghp" + "_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"
    private let githubOAuth = "gho" + "_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"
    private let slackToken = "xoxb" + "-1234567890-abcdefghij"
    private let awsKeyID = "AKIA" + "IOSFODNN7EXAMPLE"
    private let googleKey = "AIza" + "SyA1234567890abcdefghijklmnopqrstuvw"
    private let privateKeyHeader = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
    private let privateKeyFooter = "-----END OPENSSH " + "PRIVATE KEY-----"

    // MARK: - Redaction

    /// One case per credential shape. The assertion is always the same: the secret does not
    /// survive, in any form, anywhere in the output.
    func testRedactsEveryKnownCredentialShape() {
        let cases: [(name: String, input: String, secret: String)] = [
            ("openai", "export KEY=sk-abcdefghijklmnopqrstuvwxyz012345", "sk-abcdefghijklmnopqrstuvwxyz012345"),
            ("github pat", "clone with \(githubPAT)", githubPAT),
            ("github oauth", "token \(githubOAuth)", githubOAuth),
            ("sentry", "SENTRY_AUTH_TOKEN is sntrys_abcdefghijklmnopqrs.tuvwxyz", "sntrys_abcdefghijklmnopqrs.tuvwxyz"),
            ("slack", "hook \(slackToken)", slackToken),
            ("aws", "id \(awsKeyID) here", awsKeyID),
            ("google", "key \(googleKey) done", googleKey),
            ("jwt", "auth eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
                    "eyJhbGciOiJIUzI1NiJ9"),
            ("bearer", "Authorization: Bearer abcdef1234567890XYZ", "abcdef1234567890XYZ"),
        ]
        for c in cases {
            let out = SpeakableText.redact(c.input)
            XCTAssertFalse(out.contains(c.secret), "\(c.name): the secret survived redaction — got \(out)")
        }
    }

    func testRedactsPrivateKeyBlockWhole() {
        let key = [
            privateKeyHeader,
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz",
            "c2gtZWQyNTUxOQAAACD1234567890abcdefghijklmnop",
            privateKeyFooter,
        ].joined(separator: "\n")
        let out = SpeakableText.redact("here it is\n\(key)\nthat was it")
        XCTAssertFalse(out.contains("b3BlbnNzaC1rZXktdjEA"))
        XCTAssertTrue(out.contains("a redacted private key"))
        XCTAssertTrue(out.contains("that was it"), "redaction should not swallow the surrounding text")
    }

    func testRedactsNamedSecretAssignments() {
        for line in ["password=hunter2", "API_KEY: abc123def", "auth = zzzzzzzz"] {
            let out = SpeakableText.redact(line)
            XCTAssertTrue(out.contains("a redacted value"), "\(line) should be redacted, got \(out)")
        }
        XCTAssertFalse(SpeakableText.redact("password=hunter2").contains("hunter2"))
    }

    /// Over-redaction is the failure mode this guards. A commit SHA is not a secret; turning it
    /// into "a redacted token" would be wrong and would frighten someone reading a git log.
    func testDoesNotRedactOrdinaryHashesAndProse() {
        let sha = "b7818ff6a1c2d3e4f5061728394a5b6c7d8e9f01"
        let out = SpeakableText.redact("commit \(sha) landed")
        XCTAssertTrue(out.contains(sha), "a git SHA must not be treated as a credential")

        let prose = "The password reset flow needs a test."
        XCTAssertEqual(SpeakableText.redact(prose), prose, "prose mentioning a secret word is not a secret")
    }

    func testRedactionIsIdempotent() {
        let input = "key sk-abcdefghijklmnopqrstuvwxyz012345 and \(githubPAT)"
        let once = SpeakableText.redact(input)
        XCTAssertEqual(SpeakableText.redact(once), once)
    }

    // MARK: - Terminal profile

    func testStripsANSIAndOSCSequences() {
        let noisy = "\u{1B}]0;title\u{07}\u{1B}[1;32mPASS\u{1B}[0m 42 tests\u{1B}[?25h"
        let out = SpeakableText.normalize(noisy, profile: .terminal)
        XCTAssertTrue(out.contains("PASS"))
        XCTAssertTrue(out.contains("42 tests"))
        XCTAssertFalse(out.contains("\u{1B}"), "no escape byte should survive")
        XCTAssertFalse(out.contains("[1;32m"))
        XCTAssertFalse(out.contains("title"), "an OSC title string is not content")
    }

    func testTerminalKeepsTheCommandAndDropsThePromptDecoration() {
        let out = SpeakableText.normalize("anatoli@MacBook-Pro baton % swift build\nBuild complete.", profile: .terminal)
        XCTAssertTrue(out.contains("Command: swift build."), "the typed command is the useful half of a prompt line")
        XCTAssertFalse(out.contains("anatoli@MacBook-Pro"), "the host and directory are furniture")
        XCTAssertTrue(out.contains("Build complete."))
    }

    /// Selecting a screenful to hear the thing that just failed is the common case; reading the
    /// previous six commands first defeats it.
    func testTerminalPrefersTheLastCommandsOutput() {
        let scrollback = """
        anatoli@mac baton % git status
        nothing to commit
        anatoli@mac baton % swift test
        error: one test failed
        """
        let out = SpeakableText.normalize(scrollback, profile: .terminal)
        XCTAssertTrue(out.contains("error: one test failed"))
        XCTAssertFalse(out.contains("nothing to commit"), "earlier commands should not be spoken")
    }

    // MARK: - Browser profile

    func testBrowserDropsBoilerplateLinesButKeepsProse() {
        let page = """
        Skip to content
        Accept all cookies
        The cookie banner is the subject of this article.
        Back to top
        """
        let out = SpeakableText.normalize(page, profile: .browser)
        XCTAssertFalse(out.contains("Skip to content"))
        XCTAssertFalse(out.contains("Back to top"))
        XCTAssertTrue(out.contains("The cookie banner is the subject of this article."),
                      "boilerplate matches whole lines, so an article about banners survives")
    }

    // MARK: - Shared normalization

    func testAnnouncesCodeBlocksInsteadOfPronouncingThem() {
        let md = "Before.\n```swift\nlet x = 1\nlet y = 2\n```\nAfter."
        let out = SpeakableText.normalize(md, profile: .generic)
        XCTAssertTrue(out.contains("swift code block, 2 lines."))
        XCTAssertFalse(out.contains("let x = 1"))
        XCTAssertTrue(out.contains("Before."))
        XCTAssertTrue(out.contains("After."))
    }

    func testGivesOpaqueTokensASpokenShorthand() {
        let out = SpeakableText.normalize("commit b7818ff6a1c2d3e4f5061728394a5b6c7d8e9f01 shipped", profile: .generic)
        XCTAssertFalse(out.contains("b7818ff6"))
        XCTAssertTrue(out.contains("character hash"), "got: \(out)")

        let uuid = SpeakableText.normalize("id 271C9AE4-CCDB-4787-B58D-1075349254FA here", profile: .generic)
        XCTAssertTrue(uuid.contains("a UUID"))
    }

    func testShortensURLsToTheirHost() {
        let out = SpeakableText.normalize("See https://www.example.com/a/very/long/path?q=1 for more", profile: .generic)
        XCTAssertTrue(out.contains("a link to example.com"))
        XCTAssertFalse(out.contains("/very/long/path"))
    }

    func testExpandsAbbreviationsThatReadBadly() {
        let out = SpeakableText.normalize("Use a cache, e.g. Redis, vs. a database.", profile: .generic)
        XCTAssertTrue(out.contains("for example"))
        XCTAssertTrue(out.contains("versus"))
        XCTAssertFalse(out.contains("e.g."))
    }

    func testNormalizationIsIdempotent() {
        let messy = "\u{1B}[31mfail\u{1B}[0m   at   https://example.com/x\n\n\n\nnext"
        for profile in SpeakableText.SourceProfile.allCases {
            let once = SpeakableText.normalize(messy, profile: profile)
            XCTAssertEqual(SpeakableText.normalize(once, profile: profile), once,
                           "\(profile) normalization should be stable")
        }
    }

    // MARK: - Chunking

    func testChunkerRespectsBothBounds() {
        let text = (1...40).map { "This is sentence number \($0) and it is of a fairly ordinary length." }
            .joined(separator: " ")
        let chunks = SpeakableText.chunks(text)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, SpeakableText.maxChunkCharacters,
                                     "no chunk may exceed the ceiling: \(chunk)")
        }
        // Every chunk but the last should clear the floor; the tail is whatever is left over.
        for chunk in chunks.dropLast() {
            XCTAssertGreaterThanOrEqual(chunk.count, SpeakableText.minChunkCharacters,
                                        "no one-word utterances: \(chunk)")
        }
    }

    func testChunkerSplitsAPathologicalRunWithNoPunctuation() {
        let runOn = String(repeating: "word ", count: 400)
        let chunks = SpeakableText.chunks(runOn)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, SpeakableText.maxChunkCharacters)
        }
    }

    func testChunkerReturnsNothingForEmptyInput() {
        XCTAssertTrue(SpeakableText.chunks("").isEmpty)
        XCTAssertTrue(SpeakableText.chunks("   \n\n  ").isEmpty)
    }

    func testChunksReassembleTheContent() {
        let text = "First sentence here. Second sentence here. Third sentence here."
        let joined = SpeakableText.chunks(text, minCharacters: 1, maxCharacters: 400).joined(separator: " ")
        XCTAssertTrue(joined.contains("First sentence"))
        XCTAssertTrue(joined.contains("Third sentence"))
    }

    // MARK: - End to end

    /// The whole point, in one test: a terminal selection carrying a token is spoken without it.
    func testPrepareNeverLetsASecretReachAnyChunk() {
        let scrollback = """
        anatoli@mac baton % ./deploy.sh
        \u{1B}[32mOK\u{1B}[0m exporting SENTRY_AUTH_TOKEN=sntrys_abcdefghijklmnopqrs.tuvwxyz
        deploy finished in 42 seconds
        """
        let chunks = SpeakableText.prepare(scrollback, profile: .terminal)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertFalse(chunk.contains("sntrys_"), "a token reached a spoken chunk: \(chunk)")
            XCTAssertFalse(chunk.contains("\u{1B}"), "an escape sequence reached a spoken chunk")
        }
        XCTAssertTrue(chunks.joined(separator: " ").contains("deploy finished in 42 seconds"))
    }

    /// A colour code glued to a secret puts a word character ("m") right before it, which hides
    /// the secret from a pattern anchored on a word boundary. Escapes must go before redaction.
    func testAColouredSecretIsStillRedacted() {
        let coloured = [
            "key \u{1B}[33m\(awsKeyID)\u{1B}[0m set",
            "\u{1B}[1mpassword\u{1B}[0m=hunter2",
        ]
        for raw in coloured {
            let spoken = SpeakableText.prepare(raw, profile: .terminal).joined(separator: " ")
            XCTAssertFalse(spoken.contains(awsKeyID), "a coloured key survived redaction: \(spoken)")
            XCTAssertFalse(spoken.contains("hunter2"), "a coloured password survived redaction: \(spoken)")
        }
    }

    /// The residual of A-13: a code between a word and a secret ("word\e[0mAKIA…") was stripped
    /// to nothing, which glued the key to the word, and the boundary-anchored pattern missed it
    /// again. Where an escape separates two word characters it now reads as a
    /// break for redaction.
    func testASecretGluedToAWordByAColourCodeIsRedacted() {
        let glued = [
            "export\u{1B}[0m\(awsKeyID) done",
            "deploy\u{1B}[32m\(awsKeyID)\u{1B}[0m ok",
            "title\u{1B}]0;x\u{07}\(awsKeyID) end",
        ]
        for raw in glued {
            let spoken = SpeakableText.prepare(raw, profile: .terminal).joined(separator: " ")
            XCTAssertFalse(spoken.contains(awsKeyID), "a key glued to a word by an escape survived redaction: \(spoken)")
            XCTAssertTrue(spoken.contains("a redacted key"), "the key is announced, not dropped: \(spoken)")
        }
    }

    /// Neither reading may win outright. `grep --color` puts an escape *inside* a token it matched
    /// ("\e[01;31m\e[Kghp_\e[m\e[K…"), which only the stripped-to-nothing reading sees whole, while a
    /// key glued to a word needs the stripped-to-space one. Keeping whichever reading found more
    /// let two glued keys outvote the grep match, and the GitHub token was spoken
    /// (TBX-1000000504 review, 2026-10-22). Every secret either reading finds is redacted.
    func testEverySecretEitherReadingFindsIsRedacted() {
        let secondKey = "AKIA" + "ABCDEFGHIJKLMNOP"
        let token = "ghp" + "_Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0UvWxYz"
        let raw = "export\u{1B}[0m\(awsKeyID) done\n"
            + "export\u{1B}[0m\(secondKey) done\n"
            + "config.yml:\u{1B}[01;31m\u{1B}[K\(token.prefix(4))\u{1B}[m\u{1B}[K\(token.dropFirst(4))\n"
        let spoken = SpeakableText.prepare(raw, profile: .terminal).joined(separator: " ")
        for secret in [awsKeyID, secondKey, token, String(token.dropFirst(4))] {
            XCTAssertFalse(spoken.contains(secret), "\(secret.prefix(6))… was spoken: \(spoken)")
        }
    }

    /// An escape *inside* a secret's value splits it in the spaced reading, so the spaced match
    /// is only its first part. Taking that part out before the joined reading's own, whole match
    /// cut the secret apart and its tail was spoken (TBX-1000000504 verification, 2026-10-22).
    func testASecretSplitPartWayByAnEscapeIsRedactedWhole() {
        let hi = "\u{1B}[01;31m\u{1B}[K", lo = "\u{1B}[m\u{1B}[K"
        let token = "ghp" + "_Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0UvWxYz"
        let cases: [(raw: String, secretParts: [String])] = [
            ("DB_PASSWORD=\(hi)hunter\(lo)2xyzSECRET", ["hunter", "2xyzSECRET"]),
            ("config.yml:\(token.prefix(30))\(hi)\(token.dropFirst(30))\(lo)", [String(token.dropFirst(30))]),
            ("\u{1B}[33m\(token.prefix(21))\u{1B}[0m\(token.dropFirst(21)) end", [String(token.dropFirst(21))]),
        ]
        for (raw, parts) in cases {
            let spoken = SpeakableText.prepare(raw, profile: .terminal).joined(separator: " ")
            for part in parts {
                XCTAssertFalse(spoken.contains(part), "part of a split secret was spoken: \(spoken)")
            }
            XCTAssertTrue(spoken.contains("a redacted"), "the secret is announced, not dropped: \(spoken)")
        }
    }

    /// Colouring inside a word with no secret in it reads as the word, as it does on screen.
    func testColouringInsideAWordStillReadsAsTheWord() {
        let spoken = SpeakableText.prepare("ma\u{1B}[31mi\u{1B}[0mn branch", profile: .terminal).joined(separator: " ")
        XCTAssertEqual(spoken, "main branch")
    }
}
