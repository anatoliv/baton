import XCTest

/// A broken server must not look like an empty library.
///
/// `MusicLibraryStore.lastError` has existed the whole time and `ios/Sources` read it
/// nowhere, so a server returning 500 — or simply not answering — rendered as "No albums".
/// That is the worst possible failure message: it is confident, it is about *your data*,
/// and it is wrong. People delete and re-add servers over it.
///
/// Pointed at a host that cannot resolve, which is the honest version of "kill the test
/// server" and needs no fixture to stay down.
final class ErrorStateUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession",
            // .invalid is reserved by RFC 6761 and can never resolve, so this fails the
            // same way on any network, including none.
            "-uitestServer", "https://baton-unreachable.invalid",
            "-uitestUser", "demo", "-uitestSecret", "demo",
            "-uitestBypassBiometrics",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAlbumsSaysItCouldNotLoadRatherThanClaimingTheLibraryIsEmpty() {
        app.launch()
        app.buttons["Albums"].firstMatch.tap()

        // The shared placeholder's error title. Waiting generously because the failure has
        // to come back from a DNS attempt, not from a fixture.
        let failed = app.staticTexts["Couldn't load"].firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 60),
                      "an unreachable server must report a failure")
        XCTAssertFalse(app.staticTexts["No albums"].exists,
                       "the empty state must stand down when the fetch failed — it says the library is empty, which is a claim about the user's data")
        capture("albums-error-state")
    }

    func testTheRetryAffordanceIsOffered() {
        app.launch()
        app.buttons["Albums"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Couldn't load"].firstMatch.waitForExistence(timeout: 60))
        // An error with no way out is a dead end; the placeholder takes an onRetry and every
        // browse screen now passes one.
        XCTAssertTrue(app.buttons["Try Again"].firstMatch.exists,
                      "a failed load must offer a retry")
    }
}
