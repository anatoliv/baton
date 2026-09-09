import XCTest

/// Settles, by running it, whether a UI test can ever observe friend sync.
///
/// ## The claim this exists to test
///
/// TBX-5125's review log carried a caution, marked "read from code and not tested": under
/// XCUITest the app process links XCTest, so `BatonEnvironment.current` is `.testing`;
/// `FriendLedgerStore.defaultDefaults()` then returns a random throwaway suite while
/// `PreferenceSync` still uses `.standard`; the two never meet, the merge never fires, and a UI
/// test would watch the feature do nothing while reporting nothing wrong.
///
/// It was a reasonable reading. It is also the kind of claim that gets believed for a year
/// because nobody can be bothered to check, and it had already cost one live walk its method —
/// TBX-5125 drove the app with `simctl launch` rather than XCUITest partly because of it.
///
/// ## Why the check is shaped like this
///
/// The app reports what it resolved (`StorageReport`, DEBUG only) and this reads it back. The
/// decisive field is `same`, which the app computes by **writing a value through the domain
/// `PreferenceSync` uses and reading it back through the domain the friend stores use**. That is
/// the property the feature actually needs. Comparing two `UserDefaults` objects would not be:
/// two instances over one suite are two objects, so identity answers a different question and
/// would answer it wrongly.
///
/// The other fields are there so a failure says *why*. `xct` reports the two halves of
/// `BatonRuntime.isTest` separately, because in a UI test they need not agree — the runner is a
/// separate process, and whether `XCTestConfigurationFilePath` reaches the app's environment is
/// precisely what was unknown.
///
/// **This test is honest about either outcome.** If the domains diverge it fails and says what
/// the app reported, which is the answer the card wants recorded. If they agree it passes, and
/// the caution is contradicted with evidence rather than with a second opinion.
final class StorageDomainUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testTheAppUnderXCUITestResolvesOneStorageDomainForBothHalvesOfFriendSync() {
        let app = XCUIApplication()
        // TBX-5336: launchEnvironment, not launchArguments — see CLAUDE.md's UI-test section.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launch()

        let report = app.otherElements["debug.storageDomains"].firstMatch
        let text = app.staticTexts["debug.storageDomains"].firstMatch
        let element = text.waitForExistence(timeout: 60) ? text : report
        XCTAssertTrue(element.waitForExistence(timeout: 60),
                      "the app never reported its storage domains — the DEBUG overlay is gone or the app did not launch")

        let line = element.label
        XCTAssertFalse(line.isEmpty, "empty storage report")
        add(XCTAttachment(string: "storage report under XCUITest: \(line)"))

        XCTAssertTrue(line.contains("same=yes"), """
            Under XCUITest the app resolved DIFFERENT UserDefaults domains for PreferenceSync and \
            the friend stores, so friend sync cannot be observed from a UI test. The app reported: \
            \(line). Launch the app with `-baton.defaultsSuite <name>`, which moves both halves \
            together (BatonStorage, TBX-5162), or drive it with `simctl launch` instead.
            """)
    }

    /// The same question with the probe flag on, which is the configuration a future sync UI test
    /// would actually use. It must hold here too — a redirect that moved only one half would be
    /// worse than no redirect, since the run would look clean and test nothing.
    func testAProbeLaunchAlsoKeepsBothHalvesInOneDomain() {
        let app = XCUIApplication()
        // TBX-5336: launchEnvironment, not launchArguments — see CLAUDE.md's UI-test section.
        // `-baton.defaultsSuite`'s environment fallback lives in `BatonStorage.redirect`.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["baton.defaultsSuite"] = "io.tonebox.tests.uiprobe"
        app.launch()

        let text = app.staticTexts["debug.storageDomains"].firstMatch
        let element = text.waitForExistence(timeout: 60)
            ? text : app.otherElements["debug.storageDomains"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 60), "the app never reported its storage domains")

        let line = element.label
        add(XCTAttachment(string: "storage report under a probe launch: \(line)"))
        XCTAssertTrue(line.contains("probe=yes"),
                      "the probe flag did not take effect under XCUITest. The app reported: \(line)")
        XCTAssertTrue(line.contains("same=yes"),
                      "a probe launch moved only one half of the storage. The app reported: \(line)")
    }
}
