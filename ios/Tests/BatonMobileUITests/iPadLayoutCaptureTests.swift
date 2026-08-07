import UIKit
import XCTest

/// Captures the phone layout as it actually renders on a 13" iPad.
///
/// The app ships universal (`UIDeviceFamily = [1, 2]`) with no size-class adaptation
/// anywhere in it, so iPad gets the iPhone layout stretched across a canvas four times the
/// width. These captures exist to be looked at, not asserted on.
final class iPadLayoutCaptureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-baton.resetSession", "-uitestBypassBiometrics"]
    }

    /// These walk an iPad-shaped canvas and mean nothing on a phone — where the same taps
    /// land on a different layout and fail for reasons that aren't defects. A capture test
    /// that fails on the wrong device is just noise in the suite.
    private func skipUnlessIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad,
                          "iPad-only capture")
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureEveryTabOnIPad() throws {
        try skipUnlessIPad()
        app.launch()

        let demo = app.buttons["Try the demo"]
        if demo.waitForExistence(timeout: 30) { demo.tap() }

        for tab in ["Home", "Albums", "Library", "Search"] {
            let button = app.buttons[tab].firstMatch
            guard button.waitForExistence(timeout: 20) else { continue }
            button.tap()
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 10)
            usleep(1_500_000)
            capture("ipad-\(tab.lowercased())")
        }
    }

    /// The now-playing bar with something actually playing, which is the only state in
    /// which it can be judged.
    func testCaptureTheNowPlayingBarOnIPad() throws {
        try skipUnlessIPad()
        app.launch()

        let demo = app.buttons["Try the demo"]
        if demo.waitForExistence(timeout: 30) { demo.tap() }

        app.buttons["Albums"].firstMatch.tap()
        let album = app.scrollViews.buttons.firstMatch
        guard album.waitForExistence(timeout: 20) else { return XCTFail("no album to open") }
        album.tap()

        let play = app.buttons["Play"].firstMatch
        guard play.waitForExistence(timeout: 20) else { return XCTFail("no Play button") }
        play.tap()
        usleep(2_500_000)
        capture("ipad-now-playing-bar")
    }
}
