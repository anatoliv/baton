import XCTest
@testable import Baton

/// TBX-5101: a crash report is only actionable against a known revision.
///
/// The live 0.17.12 Mac build carries version strings and nothing else, so every
/// event it ever sent is filed under a release id that a dozen different commits
/// could have produced. `BatonSourceCommit` fixes that going forward — but only if
/// the app is strict about what it will accept as an identity. These tests pin the
/// rule, because the dangerous failure here is not a missing commit (visible, and
/// investigated) but a plausible-looking wrong one (invisible, and believed).
///
/// The shell half of the same rule lives in `scripts/release-identity.sh` and is
/// exercised by `scripts/test-release-identity.sh`; the two must agree.
final class CrashReportingReleaseTests: XCTestCase {

    private let realCommit = "83ccbe9d8bb707cf937a6a1f6f9836f1f2bf7b11"

    // MARK: validatedCommit — what counts as an identity

    func testAcceptsFortyCharLowercaseHex() {
        XCTAssertEqual(CrashReporting.validatedCommit(realCommit), realCommit)
    }

    func testTrimsSurroundingWhitespace() {
        // xcconfig and build-setting substitution both leave trailing whitespace behind
        // often enough that a strict comparison would reject a perfectly good commit.
        XCTAssertEqual(CrashReporting.validatedCommit("  \(realCommit)\n"), realCommit)
    }

    func testRejectsMissingAndEmpty() {
        XCTAssertNil(CrashReporting.validatedCommit(nil))
        XCTAssertNil(CrashReporting.validatedCommit(""))
        XCTAssertNil(CrashReporting.validatedCommit("   "))
    }

    /// The failure that looks most like success: the key is present, so a glance at
    /// the Info.plist says "identity: yes", and the value is the template itself.
    func testRejectsUnexpandedBuildSettingTemplate() {
        XCTAssertNil(CrashReporting.validatedCommit("$(BATON_SOURCE_COMMIT)"))
        XCTAssertNil(CrashReporting.validatedCommit("${BATON_SOURCE_COMMIT}"))
    }

    func testRejectsPlaceholders() {
        for placeholder in ["unknown", "none", "HEAD", "dev", "local", "dirty"] {
            XCTAssertNil(CrashReporting.validatedCommit(placeholder), placeholder)
        }
    }

    /// Short hashes collide, and git's default abbreviation length grows with the
    /// repository, so a prefix that is unique today need not stay unique.
    func testRejectsAbbreviatedHash() {
        XCTAssertNil(CrashReporting.validatedCommit("83ccbe9d"))
        XCTAssertNil(CrashReporting.validatedCommit(String(realCommit.prefix(39))))
        XCTAssertNil(CrashReporting.validatedCommit(realCommit + "a"))
    }

    /// Two spellings of one commit is two commits to everything downstream that
    /// compares release ids as strings.
    func testRejectsUppercaseHex() {
        XCTAssertNil(CrashReporting.validatedCommit(realCommit.uppercased()))
        XCTAssertNil(CrashReporting.validatedCommit("83CCbe9d8bb707cf937a6a1f6f9836f1f2bf7b11"))
        // Deliberately contains no "F". The shell half of this rule used a `[a-f]`
        // bracket range, and shell bracket ranges are collation-driven: under
        // en_US.UTF-8 the collation interleaves the cases, so the range spanned A-E and
        // uppercase hashes were ACCEPTED unless they happened to contain an F, which
        // sorts outside it. Both fixtures above contain an F, so both passed for the
        // wrong reason. This implementation tests explicit set membership and was never
        // exposed, but the fixture gap was identical and is worth closing here too.
        XCTAssertNil(CrashReporting.validatedCommit("83CCBE9D8BB707C0937A6A1E6E9836E1E2BE7B11"))
    }

    func testRejectsNonHex() {
        XCTAssertNil(CrashReporting.validatedCommit(String(repeating: "z", count: 40)))
        XCTAssertNil(CrashReporting.validatedCommit("83ccbe9d-8bb7-07cf-937a-6a1f6f9836f1f2bf"))
        // Non-ASCII digits satisfy Swift's own "is a number" test, so the obvious
        // implementation — `allSatisfy(\.isHexDigit)` or a `.isNumber` check — admits
        // strings git cannot emit. `validatedCommit` tests membership of an explicit
        // ASCII set instead, which is why these are refused.
        //
        // ASSERT THE TRAP IS ARMED FIRST. Without these two lines the cases below pass
        // whether or not the hazard still exists: if Swift's classification ever changed
        // so that these were not numbers, the rejections would keep passing for a
        // completely different reason and the test would silently stop documenting
        // anything. Same failure as an assertion that is true for the wrong reason.
        XCTAssertTrue(Character("８").isNumber, "fullwidth digit should still be .isNumber")
        XCTAssertTrue(Character("٤").isNumber, "Arabic-Indic digit should still be .isNumber")

        // Same length as a real hash, so only the character set can reject them.
        let fullwidthLeadingDigit = "８" + realCommit.dropFirst()
        XCTAssertEqual(fullwidthLeadingDigit.count, 40)
        XCTAssertNil(CrashReporting.validatedCommit(fullwidthLeadingDigit))

        let arabicIndic = String(repeating: "٤", count: 40)
        XCTAssertEqual(arabicIndic.count, 40)
        XCTAssertTrue(arabicIndic.allSatisfy(\.isNumber))
        XCTAssertNil(CrashReporting.validatedCommit(arabicIndic))
    }

    // MARK: releaseName — what Sentry keys on

    func testReleaseNameCarriesTheCommitWhenThereIsOne() {
        XCTAssertEqual(
            CrashReporting.releaseName(version: "0.17.12", build: "97", commit: realCommit),
            "io.tonebox.baton@0.17.12+97.\(realCommit)"
        )
    }

    /// Builds with no stamp — every macOS release up to and including 0.17.12, and the
    /// iPhone app, which shares this file but does not stamp — must keep the id they
    /// have, or their existing Sentry releases get split in two.
    func testReleaseNameIsUnchangedWithoutACommit() {
        XCTAssertEqual(
            CrashReporting.releaseName(version: "0.17.12", build: "97", commit: nil),
            "io.tonebox.baton@0.17.12+97"
        )
        XCTAssertEqual(
            CrashReporting.releaseName(version: "1.1", build: "1", commit: nil),
            "io.tonebox.baton@1.1+1"
        )
    }

    /// A Sentry release id may not contain a newline or a forward slash, and may not
    /// be "." or ".."; the composed string must stay safe for every input we accept.
    func testReleaseNameStaysASingleSafeToken() {
        let name = CrashReporting.releaseName(version: "0.17.12", build: "97", commit: realCommit)
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(" "))
    }

    /// The identity is only worth stamping if it distinguishes builds that the version
    /// pair cannot — which is the entire 0.17.12 problem in one assertion.
    func testTwoCommitsAtTheSameVersionGetDifferentReleaseIds() {
        let a = CrashReporting.releaseName(version: "0.17.12", build: "97", commit: realCommit)
        let b = CrashReporting.releaseName(version: "0.17.12", build: "97",
                                           commit: "0000000000000000000000000000000000000001")
        XCTAssertNotEqual(a, b)
    }
}
