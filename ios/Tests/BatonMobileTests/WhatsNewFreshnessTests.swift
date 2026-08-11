import BatonPlaybackKit
import XCTest
@testable import BatonMobile

/// What's New must describe the version it is running in.
///
/// The phone had no guard on this and it rotted exactly as predicted: the screen read
/// "Baton 0.3.5" over a list of 0.3.0's changes, so five releases of user-visible work —
/// the whole point of the screen — never reached the one surface built to announce it.
/// The Mac has had `WhatsNewFreshnessTests` and a release-script gate for this since its
/// notes sat at 0.8.1 while 0.9.1 shipped. This is the phone's copy.
@MainActor
final class WhatsNewFreshnessTests: XCTestCase {
    func testTheNewestEntryIsTheShippingVersion() {
        let newest = WhatsNewView.releases.first?.version
        XCTAssertEqual(newest, WhatsNewView.currentVersion,
                       "What's New leads with \(newest ?? "nothing") but this build is "
                       + "\(WhatsNewView.currentVersion) — add an entry before releasing")
    }

    func testEveryReleaseSaysSomething() {
        for release in WhatsNewView.releases {
            XCTAssertFalse(release.highlight.isEmpty, "\(release.version) has no headline")
            XCTAssertFalse(release.changes.isEmpty, "\(release.version) lists no changes")
            for change in release.changes {
                XCTAssertGreaterThan(change.text.count, 20,
                                     "\(release.version): '\(change.text)' is too terse to be useful")
            }
        }
    }

    /// Newest first, because the card at the top is labelled LATEST and a mis-sorted list
    /// would put that badge on the wrong release.
    func testReleasesAreNewestFirst() {
        let versions = WhatsNewView.releases.map(\.version)
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        XCTAssertEqual(versions, sorted, "release notes must run newest first")
    }

    func testVersionsAreNotDuplicated() {
        let versions = WhatsNewView.releases.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count)
    }
}

/// The public Navidrome demo is a real host with real credentials, offered to people who
/// have no server. If any of it is wrong the offer is worse than absent — it fails at the
/// exact moment someone is deciding whether the app works.
final class PublicDemoServerTests: XCTestCase {
    func testTheDemoDetailsAreWhatNavidromePublishes() {
        XCTAssertEqual(NavidromePublicDemo.url, "https://demo.navidrome.org")
        XCTAssertEqual(NavidromePublicDemo.username, "demo")
        XCTAssertEqual(NavidromePublicDemo.password, "demo")
    }

    func testTheURLIsUsableAsOne() throws {
        let url = try XCTUnwrap(URL(string: NavidromePublicDemo.url))
        XCTAssertEqual(url.scheme, "https", "credentials must not travel in the clear")
        XCTAssertNotNil(url.host)
    }

    /// It is someone else's server. Saying so is the difference between "the demo is
    /// offline" and "Baton is broken".
    func testTheOfferAdmitsItIsNotOurServer() {
        let caveat = NavidromePublicDemo.caveat.lowercased()
        XCTAssertTrue(caveat.contains("not ours") || caveat.contains("offline"),
                      "the copy must warn that this server can be unavailable")
    }
}
