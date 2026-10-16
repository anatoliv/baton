import XCTest

/// The phone's book, made on the real home server (M5.2, M5.3): a PDF staged into the app's
/// container opens the import screen, the home server answers so Make Audiobook is offered, the
/// book is sent, and chapter 1 comes down into Clippings as "1 of 3 chapters ready". This is the
/// spec's acceptance line short of the lock screen, which a simulator cannot show.
///
/// Opt-in, like the package's live tests: it skips unless the runner has
/// `BATON_LIVE_GATEWAY_URL`, `BATON_LIVE_GATEWAY_TOKEN` and `BATON_LIVE_IMPORT_FILE`.
/// `ios/scripts/books-live-walk.sh` sets them, relays the gateway through 127.0.0.1 (local
/// network privacy does not apply to loopback) and stages the sample PDF. The runner hands the
/// gateway and the file to the app through its launch environment, never a launch argument
///. The test book is deleted from the home server afterwards.
final class DocumentImportLiveWalkUITests: XCTestCase {
    private var app: XCUIApplication!
    private var gateway: URL?
    private var token = ""
    private var started = Date()

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BATON_LIVE_GATEWAY_URL"].flatMap(URL.init(string:)),
              let secret = env["BATON_LIVE_GATEWAY_TOKEN"], !secret.isEmpty,
              let file = env["BATON_LIVE_IMPORT_FILE"], !file.isEmpty else {
            throw XCTSkip("set BATON_LIVE_GATEWAY_URL, BATON_LIVE_GATEWAY_TOKEN and BATON_LIVE_IMPORT_FILE (ios/scripts/books-live-walk.sh) to walk against a real home server")
        }
        gateway = url
        token = secret
        started = Date()
        app = XCUIApplication()
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["baton.demoMode"] = "YES"
        app.launchEnvironment["uitestBypassBiometrics"] = "1"
        // Never let the test phone's reset state travel into the owner's shared settings.
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        app.launchEnvironment["uitestGatewayURL"] = url.absoluteString
        app.launchEnvironment["uitestGatewayToken"] = secret
        app.launchEnvironment["uitestImportFile"] = file
    }

    override func tearDownWithError() throws {
        deleteTestBooks()
        app = nil
        try super.tearDownWithError()
    }

    func testABookImportedOnThePhoneIsMadeOnTheHomeServerAndChapterOneArrives() throws {
        app.launch()

        let title = app.staticTexts["The Machine Stops"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60), "the import screen did not open with the sample's title")
        XCTAssertTrue(app.staticTexts["The Air-Ship"].firstMatch.waitForExistence(timeout: 10), "chapter 1 is not listed")

        // The home server answered, so the book can be made there. The button is the last row
        // of a list, below the chapters and the narrator, so bring it on screen first: a List
        // row that has never been shown is not in the accessibility tree.
        let make = app.buttons["make-audiobook"].firstMatch
        var tries = 0
        while !make.exists && tries < 6 {
            app.swipeUp()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            tries += 1
        }
        XCTAssertTrue(make.waitForExistence(timeout: 60), "Make Audiobook was not offered: the home server did not answer")
        attach("import-screen-home-server")
        // The notification permission alert appears after the book is sent; answer it so it
        // cannot hold the walk. XCUITest only runs the monitor on the next interaction.
        let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Allow", "Don’t Allow", "Don't Allow"] where alert.buttons[name].exists {
                alert.buttons[name].tap(); return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        make.tap()
        app.tap()
        XCTAssertTrue(waitUntilGone(title, timeout: 60), "the import screen should close once the book is sent")

        // Clippings shows the book at once, then chapter 1 when the home server has made it.
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20), "no Library tab")
        library.tap()
        let entry = app.cells.containing(.staticText, identifier: "Clippings").firstMatch
        if entry.waitForExistence(timeout: 10) { entry.tap() } else {
            let fallback = app.buttons["Clippings"].firstMatch
            XCTAssertTrue(fallback.waitForExistence(timeout: 10), "no route to Clippings")
            fallback.tap()
        }
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'of 3 chapters ready'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the book row did not appear in Clippings")
        attach("book-row-sent")

        let ready = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '1 of 3 chapters ready' OR label BEGINSWITH '2 of 3 chapters ready' OR label BEGINSWITH '3 chapters'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 360), "chapter 1 did not arrive from the home server within six minutes")
        let seconds = Int(Date().timeIntervalSince(started))
        XCTAssertTrue(app.staticTexts["On the Baton server"].firstMatch.exists || app.staticTexts["On this phone"].firstMatch.exists)
        attach("book-row-chapter-1-ready")
        let note = XCTAttachment(string: "chapter 1 ready \(seconds) s after launch")
        note.name = "timing"
        note.lifetime = .keepAlways
        add(note)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return !element.exists
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Every "The Machine Stops" the home server holds that was created during this test.
    private func deleteTestBooks() {
        guard let gateway else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: gateway.appendingPathComponent("v1/books"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let books = json["books"] as? [[String: Any]] else { return }
            let group = DispatchGroup()
            for book in books where (book["title"] as? String) == "The Machine Stops" {
                guard let id = book["id"] as? String else { continue }
                var delete = URLRequest(url: gateway.appendingPathComponent("v1/books/\(id)"))
                delete.httpMethod = "DELETE"
                delete.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
                group.enter()
                URLSession.shared.dataTask(with: delete) { _, _, _ in group.leave() }.resume()
            }
            group.wait()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
    }
}
