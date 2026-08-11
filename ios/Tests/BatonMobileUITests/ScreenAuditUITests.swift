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
        // Reset first: one UI test signs in to a real server to prove the connection
        // badge, and without this every later test inherited that connection — the demo
        // library was gone and five unrelated screens failed for a reason that was not
        // theirs.
        app.launchArguments += ["-baton.resetSession", "-baton.demoMode", "YES"]
        app.launch()
        dismissWhatsNewIfPresented()
    }

    /// Dismiss the What's New sheet if the app presented it on launch.
    ///
    /// It shows itself once after a version bump — correct behaviour, and invisible to
    /// these tests until a run happened to follow one. Every tap then landed on the
    /// sheet's backdrop, and a screen dump showed Home behind a stray "Done" while the
    /// test insisted a Settings row was missing.
    private func dismissWhatsNewIfPresented() {
        // Generous, and retried: the sheet appears once after a version bump, and on a
        // cold simulator it can take several seconds to draw. Missing it means every
        // later tap lands on its backdrop and the failure reads as a missing control.
        let sheet = app.navigationBars["What's New"]
        for _ in 0 ..< 3 {
            guard sheet.waitForExistence(timeout: 8) else { break }
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            if !sheet.exists { break }
        }
    }

    /// Opens Settings from Home's header.
    ///
    /// It used to be a tab. Six tabs don't fit on a phone, so with the Friend tab enabled
    /// iOS folded both Search *and* Settings behind "More" — and Search is the one people
    /// use constantly.
    private func openSettings() {
        app.tabBars.buttons["Home"].tap()
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "Home's header must offer Settings")
        gear.tap()
        // "Server" rather than "Settings": the gear's accessibility label is also
        // "Settings", so waiting on that text can match the button that was just tapped
        // instead of the screen it opened. The Server section only exists once Settings
        // is actually on screen.
        XCTAssertTrue(app.staticTexts["Server"].waitForExistence(timeout: 20),
                      "Settings must open")
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

        // Something only the destination shows, so the audit can't capture the screen it
        // just left. The old wait was `app.staticTexts.firstMatch`, which already exists on
        // the *outgoing* screen and so returned instantly — two of these screenshots came
        // out byte-identical, and one sent me looking at Settings believing it was Albums.
        let landmark = [
            "Home": "You're exploring the demo library.",
            "Albums": "Albums",
            "Library": "Library",
            "Search": "Search",
        ]

        for tab in ["Home", "Albums", "Library", "Search"] {
            let button = app.tabBars.buttons[tab]
            guard button.waitForExistence(timeout: 10) else {
                XCTFail("tab '\(tab)' is missing from the tab bar")
                continue
            }
            button.tap()
            if let text = landmark[tab] {
                XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10),
                              "\(tab) never showed its header — it did not finish opening")
            }
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

    // MARK: - Home's header

    /// Home replaces the navigation bar with its greeting rather than showing both.
    ///
    /// It used to show a large-title bar reading "Baton" *above* the greeting and its
    /// subtitle — the app's own name, then a greeting, then a caption, plus the band a
    /// large title reserves. Roughly the top quarter of the phone before any music.
    func testHomeShowsItsGreetingInsteadOfANavigationBar() {
        app.tabBars.buttons["Home"].tap()

        XCTAssertTrue(app.staticTexts["You're exploring the demo library."].waitForExistence(timeout: 15),
                      "the greeting header must be on screen — it is Home's title now")
        XCTAssertEqual(app.navigationBars.count, 0,
                       "a navigation bar on Home is the redundant second header this removed")
    }

    /// Every root tab wears the same header, and none of them wears a navigation bar.
    ///
    /// The app had two header treatments at once: Home opened at 74pt with a pinned
    /// greeting, the other four at 128pt with system large titles. Consistency is the
    /// kind of thing that decays one screen at a time, so it is asserted rather than
    /// looked at — a tab that quietly regains a navigation bar fails here.
    func testEveryRootTabUsesTheSameHeader() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))

        for tab in ["Home", "Albums", "Library", "Search"] {
            app.tabBars.buttons[tab].tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
            XCTAssertEqual(app.navigationBars.count, 0,
                           "\(tab) has a navigation bar — root tabs use the pinned header instead")
        }
    }

    /// What's New is the one screen whose whole job is to feel like good news.
    func testWhatsNewOpens() {
        openSettings()
        let row = app.buttons["What's New"]
        // Scroll the list itself. `app.swipeUp()` swipes the whole window, which on a
        // screen whose header is a pinned safe-area inset can land on chrome that does
        // not scroll — the rows below never moved and the row never appeared.
        let list = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        for _ in 0 ..< 18 where !row.exists { list.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        audit("whats-new")
    }

    // MARK: - Getting a Mac's setup onto the phone

    /// Both transports are reachable from Settings, and both say what they need.
    ///
    /// The bug this replaces was a routing one, not a missing feature. Settings offered
    /// "Import settings from Mac…", which opened the iOS Files picker — the *worse* of
    /// the two routes — while scanning the Mac's code, which sends the identical payload
    /// with nothing to type, was reachable only from first-run onboarding. Settings
    /// presents onboarding solely in demo mode, so a phone that was already connected
    /// could not get to the scanner at all.
    func testSettingsOffersBothWaysToSetUpFromAMac() {
        openSettings()

        let entry = app.buttons["Set up from a Mac…"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15),
                      "Settings must offer a way to bring a Mac's setup across")
        entry.tap()

        XCTAssertTrue(app.buttons["Scan a code from your Mac"].waitForExistence(timeout: 10),
                      "the pairing scanner must be reachable from Settings, not just onboarding")
        audit("mac-transfer")
        XCTAssertTrue(app.buttons["Choose an exported file"].exists,
                      "the file route must survive — it is the only one that works off-LAN")

        // Each route has a requirement, and picking blind is how you end up in an empty
        // Files browser wondering what you were supposed to have made.
        let text = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " ")
        XCTAssertTrue(text.contains("same network"),
                      "the scan route must say both devices need to be on one network")
        XCTAssertTrue(text.lowercased().contains("export"),
                      "the file route must say the Mac has to export the file first")
    }

    /// "Connect to Navidrome…" from Settings must be escapable.
    ///
    /// It presents the first-run screen, which is deliberately a dead end — the app can do
    /// nothing without a server, so it disables interactive dismissal and offers the demo
    /// rather than an exit. Reused from Settings by someone who already has a working app,
    /// that same screen became a trap: no Cancel, no back button, and swipe-to-dismiss
    /// switched off. The only way out was to kill the app.
    func testConnectFromSettingsCanBeBackedOutOf() {
        openSettings()

        let connect = app.buttons["Connect to Navidrome…"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "a screen opened from Settings must offer a way back")
        cancel.tap()

        XCTAssertTrue(app.staticTexts["Demo library"].waitForExistence(timeout: 10),
                      "cancelling must return to Settings, unchanged")
    }

    // MARK: - Help

    /// Help is a contents list you can search, and topics you can open.
    ///
    /// It used to be all 1,559 lines of HELP.md in one ScrollView, whose Contents entries
    /// were real Markdown anchors that resolved to nothing when tapped. Finding anything
    /// meant scrolling past everything.
    func testHelpIsABrowsableContentsRatherThanOneLongPage() {
        openSettings()
        let help = app.buttons["Help & FAQ"]
        // Settings is longer than a screen, and SwiftUI's List doesn't realise rows it
        // hasn't shown — so the row genuinely does not exist until it is scrolled to.
        // The count is generous on purpose: this screen keeps growing, and a fixed 8
        // stopped reaching the bottom the moment two more sections were added.
        for _ in 0 ..< 18 where !help.exists { app.swipeUp() }
        XCTAssertTrue(help.waitForExistence(timeout: 10))
        help.tap()

        XCTAssertTrue(app.buttons["Welcome to Baton"].waitForExistence(timeout: 10),
                      "the contents must list topics, not render one undivided document")
        audit("help-contents")

        // Searching is how you reach a topic 30 rows down without scrolling — the thing
        // the single-document version made impossible.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the contents must be searchable")
        field.tap()
        field.typeText("equalizer")

        let topic = app.buttons["The equalizer"]
        XCTAssertTrue(topic.waitForExistence(timeout: 10), "search must surface the matching topic")
        topic.tap()

        XCTAssertTrue(app.navigationBars["The equalizer"].waitForExistence(timeout: 10),
                      "tapping a topic must open that topic")
        audit("help-topic")

        // The back button is the "return to contents" — no custom control needed.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10),
                      "back must return to the contents list")
    }

    /// Settings copy is short because the long version is one tap away. If that tap opens
    /// Help at nothing, the short copy is just missing information.
    func testASettingsLearnMoreOpensHelpAtItsTopic() {
        openSettings()

        let learnMore = app.buttons["Learn more"].firstMatch
        XCTAssertTrue(learnMore.waitForExistence(timeout: 15),
                      "Settings sections must explain themselves and link to the guide")
        learnMore.tap()

        // The first "Learn more" belongs to the Equalizer section.
        XCTAssertTrue(app.navigationBars["The equalizer"].waitForExistence(timeout: 10),
                      "a Learn more must deep-link to its own topic, not dump you at the contents")
        audit("help-deep-link")
    }

    /// The two routes that need no typing must be visible without scrolling.
    ///
    /// They existed and were unreachable in practice: both sat *below* a sign-in form that
    /// already fills the screen, so the only person who would ever find them was someone
    /// who had scrolled past a form they couldn't fill in. Existing is not the same as
    /// being findable, which is why this asserts `isHittable` on a fresh screen rather
    /// than `exists` after a search.
    func testConnectOffersTheNoTypingRoutesWithoutScrolling() {
        openSettings()
        let connect = app.buttons["Connect to Navidrome…"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()

        let demo = app.buttons["Use Navidrome's public demo server"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10),
                      "the public demo server must be offered here")
        XCTAssertTrue(demo.isHittable,
                      "it must be on the first screenful — below the form it is effectively absent")

        let fromMac = app.buttons["Set up from a Mac"]
        XCTAssertTrue(fromMac.exists && fromMac.isHittable,
                      "so must the Mac route — it fills the same fields")
        audit("connect-screen")

        // And it must actually do something, not just sit there. What it does is now
        // *connect* rather than fill the fields — `ServerStatusUITests` covers both
        // outcomes of that; this test's job is only that the two routes are findable.
        demo.tap()
        XCTAssertTrue(app.staticTexts["Checking the demo server…"].waitForExistence(timeout: 5)
                        || app.tabBars.buttons["Home"].waitForExistence(timeout: 45),
                      "choosing the demo server must start connecting")
    }

    /// Search's field has to be found, not assumed: `.searchable` renders into the
    /// navigation bar, so hiding the bar removed it entirely. Without a replacement the
    /// Search tab would still open, still look right, and be unable to search.
    func testSearchCanStillSearchWithoutANavigationBar() {
        app.tabBars.buttons["Search"].tap()

        let field = app.textFields["SearchField"].exists
            ? app.textFields["SearchField"]
            : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the Search tab must offer a search field")
        field.tap()
        field.typeText(DemoFixtures.searchTerm)

        XCTAssertTrue(app.staticTexts[DemoFixtures.firstTrack].waitForExistence(timeout: 15),
                      "typing in the header field must actually run a search")
    }

    /// The risk in hiding that bar: `.toolbar(.hidden, for: .navigationBar)` applies to
    /// the view it is attached to, so pushed screens are supposed to get their own bar
    /// back. If it leaked to the whole stack, an album would open with no way out — a
    /// dead end that no unit test can see.
    func testPushingFromHomeStillGivesAWayBack() {
        app.tabBars.buttons["Home"].tap()
        let album = app.scrollViews.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", DemoFixtures.album)).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20), "Home must offer the demo album to push into")
        album.tap()

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "a screen pushed from Home must have a back button")
        back.tap()

        XCTAssertTrue(app.staticTexts["You're exploring the demo library."].waitForExistence(timeout: 10),
                      "back must return to Home, header and all")
    }
}
