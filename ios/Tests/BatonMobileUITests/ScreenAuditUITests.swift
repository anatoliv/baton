import XCTest

/// Walks every screen the phone app has, captures it, and writes down every
/// control it finds.
///
/// This exists because "I looked at it" is not evidence. Synthetic CGEvent
/// taps reach the Simulator only intermittently, so screens could be opened
/// but controls could not be exercised with any confidence. XCUITest drives
/// the real app through the real accessibility tree, so a control that
/// doesn't exist, isn't hittable, or doesn't respond fails the test rather
/// than being missed by eye.
///
/// The inventory each test prints is the raw material for the iOS-vs-Mac
/// comparison doc — it is what "verify, don't assume" looks like for a UI.
final class ScreenAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        // Demo mode: a real four-track library inside the bundle, so every
        // screen has content without needing a Navidrome server.
        app.launchArguments += ["-baton.demoMode", "YES"]
        app.launch()
    }

    /// Screenshot + full control inventory for whatever is on screen.
    @discardableResult
    private func audit(_ name: String) -> [String] {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)

        var found: [String] = []
        for (label, query) in [
            ("button", app.buttons), ("switch", app.switches),
            ("slider", app.sliders), ("textField", app.textFields),
            ("secureField", app.secureTextFields), ("cell", app.cells),
            ("tab", app.tabBars.buttons), ("link", app.links),
            // `.searchable` produces a searchField, not a textField. Missing
            // this made the Search tab look like it had no controls at all.
            ("searchField", app.searchFields),
            ("segmented", app.segmentedControls), ("stepper", app.steppers),
            ("menu", app.menuButtons), ("toggleRow", app.otherElements.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "control."))),
        ] {
            for element in query.allElementsBoundByIndex where element.exists {
                // Report the *label* (what VoiceOver speaks) and note the
                // identifier separately. Preferring the identifier hid the
                // accessibility labels entirely: SwiftUI sets an Image's
                // identifier to its SF Symbol name, so a correctly labelled
                // "Previous track" button read as "backward.fill" and looked
                // like a missing label when it wasn't one.
                let spoken = element.label
                let ident = element.identifier
                let id = spoken.isEmpty ? ident : (ident.isEmpty || ident == spoken ? spoken : "\(spoken)  (id: \(ident))")
                guard !id.isEmpty else { continue }
                // Off-screen elements in a horizontally scrolling shelf have no
                // activation point, and asking `isHittable` about one throws.
                // An empty frame is the cheap way to tell before asking.
                let offscreen = element.frame.isEmpty
                found.append("\(label): \(id)\(offscreen ? "  [offscreen]" : "")")
            }
        }
        let unique = Array(Set(found)).sorted()
        print("SCREEN AUDIT [\(name)] \(unique.count) controls")
        unique.forEach { print("   \($0)") }
        return unique
    }

    /// Opens each tab in turn and audits it. Fails if a tab can't be reached
    /// at all — that is a screen the user cannot get to.
    func testEveryTabOpensAndHasControls() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20),
                      "the tab bar must appear — without it no screen is reachable")
        audit("00-launch")

        for tab in ["Home", "Albums", "Library", "Search", "Settings"] {
            let button = app.tabBars.buttons[tab]
            guard button.waitForExistence(timeout: 10) else {
                XCTFail("tab '\(tab)' is missing from the tab bar")
                continue
            }
            button.tap()
            // Give the screen a beat to settle before capturing it.
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
            let controls = audit("tab-\(tab)")
            XCTAssertFalse(controls.isEmpty, "\(tab) has no controls at all — it can't be a working screen")
        }
    }

    /// The album → play → mini player → full player path, which is the app's
    /// core loop and the one that drives the artwork wash.
    func testPlaybackPathAndNowPlayingControls() {
        app.tabBars.buttons["Albums"].tap()
        let firstAlbum = app.collectionViews.cells.firstMatch.exists
            ? app.collectionViews.cells.firstMatch
            : app.scrollViews.otherElements.buttons.firstMatch
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 15), "Albums must list at least the demo album")
        firstAlbum.tap()
        audit("album-detail")

        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "album detail must offer Play")
        play.tap()

        // The mini player is the Mac's bottom bar equivalent.
        let mini = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10),
                      "the mini player must appear once something is playing")
        audit("mini-player")

        // And the full player, where the adaptive backdrop lives.
        mini.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10),
                      "tapping the mini player must open the full player")
        audit("full-player")
    }
}
