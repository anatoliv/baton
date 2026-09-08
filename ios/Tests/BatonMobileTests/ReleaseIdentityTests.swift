import XCTest
@testable import BatonMobile

/// The admission rule for a source identity.
///
/// These are the shapes that actually turn up in a broken build, not invented ones:
/// the build setting that never arrived, the one that arrived unexpanded, the
/// placeholder somebody typed to get a build through, the abbreviated hash, the
/// uppercase spelling. Each is a *false* identity rather than a partial one, and a
/// false identity is the worse failure because it gets believed.
final class ReleaseIdentityTests: XCTestCase {
    private let real = "56134326a1b2c3d4e5f60718293a4b5c6d7e8f90"

    func testAcceptsExactlyFortyLowercaseHex() {
        XCTAssertEqual(MobileReleaseIdentity.validatedCommit(real), real)
    }

    func testAcceptsAllHexDigitsIncludingTheBoundaries() {
        // 'f' and '9' are the top of each accepted ASCII range; 'a' and '0' the bottom.
        let boundaries = String(repeating: "0", count: 10)
            + String(repeating: "9", count: 10)
            + String(repeating: "a", count: 10)
            + String(repeating: "f", count: 10)
        XCTAssertEqual(boundaries.count, 40)
        XCTAssertEqual(MobileReleaseIdentity.validatedCommit(boundaries), boundaries)
    }

    func testTrimsSurroundingWhitespace() {
        // A build setting that picks up a trailing newline is still the same commit.
        XCTAssertEqual(MobileReleaseIdentity.validatedCommit("  \(real)\n"), real)
    }

    func testRejectsNil() {
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(nil))
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        // The state of every build before this change: the key exists, holding nothing.
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(""))
        XCTAssertNil(MobileReleaseIdentity.validatedCommit("   \n "))
    }

    func testRejectsUnexpandedBuildSettingTemplate() {
        // The failure that looks most like success — the key IS populated.
        XCTAssertNil(MobileReleaseIdentity.validatedCommit("$(BATON_SOURCE_COMMIT)"))
        XCTAssertNil(MobileReleaseIdentity.validatedCommit("${BATON_SOURCE_COMMIT}"))
    }

    func testRejectsPlaceholders() {
        for placeholder in ["dev", "unknown", "HEAD", "local", "none", "dirty"] {
            XCTAssertNil(MobileReleaseIdentity.validatedCommit(placeholder), placeholder)
        }
    }

    func testRejectsAbbreviatedHash() {
        // Short hashes collide, and git's abbreviation length grows with the repo, so a
        // prefix that is unique today may not be next year.
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(String(real.prefix(8))))
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(String(real.prefix(39))))
    }

    func testRejectsOverlongHash() {
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(real + "0"))
    }

    func testRejectsUppercase() {
        // Downstream compares these as strings; two spellings of one commit is two
        // commits. git prints lowercase, so lowercase is the canonical form.
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(real.uppercased()))
        XCTAssertNil(MobileReleaseIdentity.validatedCommit("A" + real.dropFirst()))
    }

    func testRejectsNonHexASCII() {
        XCTAssertNil(MobileReleaseIdentity.validatedCommit("g" + real.dropFirst()))
        XCTAssertNil(MobileReleaseIdentity.validatedCommit("not-a-sha"))
    }

    /// The specific reason the rule says ASCII and the implementation compares bytes.
    ///
    /// `Character.isNumber` and `Character.isHexDigit` are Unicode-aware and answer
    /// `true` for these, so the obvious spelling of this validator would admit a
    /// 40-character string git cannot emit and that compares unequal to every real
    /// object id. Forty Arabic-Indic digits are 80 UTF-8 bytes, so they fail on length
    /// before the range test even runs.
    func testRejectsNonASCIIDigits() {
        let arabicIndic = String(repeating: "٠١٢٣٤٥٦٧٨٩", count: 4)
        XCTAssertEqual(arabicIndic.count, 40, "the string under test must be 40 Characters")
        XCTAssertTrue(arabicIndic.allSatisfy(\.isNumber), "these must be digits to Swift")
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(arabicIndic))

        // Fullwidth latin 'ａ'-'ｆ' are hex digits to Unicode for the same reason.
        let fullwidth = String(repeating: "ａｂｃｄｅｆ０１２３", count: 4)
        XCTAssertEqual(fullwidth.count, 40)
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(fullwidth))
    }

    /// The key name and the tag name are the contract with two things outside this
    /// file: `ios/project.yml` declares the Info.plist key, and
    /// `ios/scripts/release-guard.sh` reads it back out of the built bundle. Renaming
    /// either without changing those is a silent break, because a missing key reads
    /// exactly like a build with no identity.
    func testInfoPlistKeyAndTagNameAreTheAgreedStrings() {
        XCTAssertEqual(MobileReleaseIdentity.infoKey, "BatonSourceCommit")
        XCTAssertEqual(MobileReleaseIdentity.tagKey, "source_commit")
    }

    /// This test bundle is not built by testflight.sh, so it carries no stamped
    /// commit. Asserting `nil` here is asserting the honest default: a build that was
    /// not stamped claims nothing rather than claiming a placeholder.
    func testAnUnstampedBundleClaimsNothing() {
        XCTAssertNil(MobileReleaseIdentity.validatedCommit(
            Bundle(for: type(of: self)).object(forInfoDictionaryKey: MobileReleaseIdentity.infoKey) as? String
        ))
    }
}
