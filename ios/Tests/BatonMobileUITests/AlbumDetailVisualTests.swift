import XCTest

/// The album page, captured against the demo server so the metadata line has something to
/// print — a bundled demo album has no year and no genre, which is exactly the case the
/// line is meant to fill in.
final class AlbumDetailVisualTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-baton.resetSession",
            "-uitestServer", "https://demo.navidrome.org",
            "-uitestUser", "demo", "-uitestSecret", "demo",
            "-uitestBypassBiometrics",
        ]
    }

    override func tearDown() { app = nil; super.tearDown() }

    private nonisolated static func skipUnlessDemoServerIsUp() throws {
        var request = URLRequest(url: URL(string: "https://demo.navidrome.org/ping")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = response != nil; done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        try XCTSkipIf(!reachable, "demo.navidrome.org isn't answering")
    }

    func testCaptureTheAlbumPage() throws {
        try Self.skipUnlessDemoServerIsUp()
        app.launch()

        app.buttons["Albums"].firstMatch.tap()
        let album = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 40), "expected an album")
        // Existing is not the same as tappable. A cell can be laid out while its artwork
        // is still arriving, or sit under the header, and `tap()` on a non-hittable
        // element fails outright — which is how this test failed on a page that was
        // perfectly fine.
        let deadline = Date().addingTimeInterval(20)
        while !album.isHittable, Date() < deadline { usleep(300_000) }
        XCTAssertTrue(album.isHittable, "the album cell never became tappable")
        album.tap()

        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 30),
                      "expected the album page")
        // The actions that moved off the hero must still be reachable.
        XCTAssertTrue(app.buttons["More actions"].firstMatch.exists,
                      "Download and Like moved into this menu — losing it would lose them")
        usleep(2_500_000)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "album-detail"; shot.lifetime = .keepAlways
        add(shot)
    }
}
