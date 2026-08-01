import XCTest
@testable import Baton

/// Guards the What's New panel against silent drift.
///
/// This happened here: the newest entry sat at 0.8.1 while 0.9.1 shipped — three releases
/// of user-visible change (the MCP honesty fixes, playlist read-back, exact-track
/// addressing, the crossfade readiness gate) that never reached the one surface built to
/// announce them. Nothing enforced it, so nobody noticed. Docs rot exactly like code, just
/// without a compiler to complain.
///
/// Ported from Tonebox's `WhatsNewFreshnessTests`, where the same failure ran to ~145
/// releases before anyone spotted it. Baton's allowance is tighter because its release
/// cadence is far slower — 24 builds to reach 0.9.1, against Tonebox's 184.
final class WhatsNewFreshnessTests: XCTestCase {
    /// How many patch releases the newest entry may trail the shipping build by before this
    /// counts as neglect rather than normal cadence. Not every patch deserves an entry.
    private let allowedPatchDrift = 3

    private struct SemVer: Comparable, CustomStringConvertible {
        let major: Int, minor: Int, patch: Int
        static func < (a: Self, b: Self) -> Bool {
            (a.major, a.minor) == (b.major, b.minor)
                ? a.patch < b.patch
                : (a.major, a.minor) < (b.major, b.minor)
        }
        var description: String { "\(major).\(minor).\(patch)" }
    }

    private func semver(_ version: String) -> SemVer? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return SemVer(major: parts[0], minor: parts[1], patch: parts[2])
    }

    /// The shipping marketing version. Read from the bundle under test.
    private var shippingVersion: String? {
        Bundle(for: type(of: self)).infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func testListIsNonEmptyAndOrderedNewestFirst() {
        let releases = HelpWhatsNewRelease.all
        XCTAssertFalse(releases.isEmpty)
        let parsed = releases.compactMap { semver($0.version) }
        XCTAssertEqual(parsed.count, releases.count, "every entry needs a three-part version")
        for (newer, older) in zip(parsed, parsed.dropFirst()) {
            XCTAssertGreaterThan(newer, older, "entries must be ordered newest first")
        }
    }

    func testEveryEntryIsSubstantive() {
        for release in HelpWhatsNewRelease.all {
            XCTAssertFalse(
                release.highlight.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(release.version) needs a highlight"
            )
            XCTAssertFalse(
                release.date.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(release.version) needs a date"
            )
            XCTAssertFalse(release.changes.isEmpty, "\(release.version) needs at least one change")
            for change in release.changes {
                XCTAssertFalse(
                    change.text.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(release.version) has an empty change line"
                )
            }
        }
    }

    func testVersionsAreUnique() {
        let versions = HelpWhatsNewRelease.all.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count, "duplicate release entry")
    }

    /// The one that would have caught the 0.8.1-vs-0.9.1 drift.
    func testNewestEntryHasNotFallenBehindTheShippingVersion() throws {
        guard let shipping = shippingVersion, let current = semver(shipping) else {
            throw XCTSkip("no marketing version in this bundle")
        }
        let newest = try XCTUnwrap(HelpWhatsNewRelease.all.compactMap { semver($0.version) }.first)

        // A whole minor line behind is never normal cadence — that is the failure this exists for.
        guard newest.major == current.major, newest.minor == current.minor else {
            XCTAssertFalse(
                (newest.major, newest.minor) < (current.major, current.minor),
                "What's New is a whole minor line behind the shipping build "
                    + "(newest entry \(newest), shipping \(shipping)) — add an entry"
            )
            return
        }
        let drift = current.patch - newest.patch
        XCTAssertLessThanOrEqual(
            drift, allowedPatchDrift,
            "What's New newest entry is \(newest) but the app ships \(shipping) — "
                + "\(drift) patch releases of user-visible change with nothing announced"
        )
    }
}
