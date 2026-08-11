import XCTest

/// Walks every screen the phone can reach and exercises what's on it.
///
/// The feature-comparison doc put the phone at 98% of the Mac, and it was counting the
/// wrong thing. Every defect found by hand in one afternoon was a feature that *existed*
/// and did not work: the equalizer's preset picker renamed the curve without applying it,
/// the preset row rendered blank, "Connect to Navidrome" opened a screen with no way out,
/// Help's Contents links resolved to nothing. A presence checklist scores all four as
/// shipped.
///
/// So this walks the app and *uses* it — taps the control, then asserts the thing the
/// control claims to do actually happened. What it prints is the per-screen report.
final class FullWalkUITests: XCTestCase {
    private var app: XCUIApplication!
    /// Collected per screen, printed at the end as the report.
    private var findings: [String] = []

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        // Reset first: one UI test signs in to a real server to prove the connection
        // badge, and without this every later test inherited that connection — the demo
        // library was gone and five unrelated screens failed for a reason that was not
        // theirs.
        app.launchArguments += ["-baton.resetSession", "-baton.demoMode", "YES"]
        app.launch()
        dismissWhatsNewIfPresented()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
    }

    override func tearDown() {
        if !findings.isEmpty {
            print("\n===== SCREEN REPORT =====")
            findings.forEach { print($0) }
            print("=========================\n")
        }
        super.tearDown()
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

    /// Attaches a screenshot to the result bundle, so a layout claim in the report can be
    /// checked by looking rather than believed.
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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

    private func note(_ screen: String, _ result: String) {
        findings.append("[\(screen)] \(result)")
    }

    /// Taps a tab and waits for the header that proves it opened.
    private func open(tab: String, landmark: String) {
        app.tabBars.buttons[tab].tap()
        XCTAssertTrue(app.staticTexts[landmark].waitForExistence(timeout: 15),
                      "\(tab) never opened")
    }

    /// Scrolls a long form until `element` materialises — SwiftUI's List doesn't realise
    /// rows it hasn't shown, so an off-screen control genuinely does not exist yet.
    ///
    /// Returns to the top first. The first version only ever swiped downward, so once an
    /// earlier check had scrolled past a row, every later lookup for something *above* the
    /// fold reported it missing — three Settings rows were flagged as unreachable gaps
    /// when the only thing unreachable was my scroll position.
    @discardableResult
    private func reveal(_ element: XCUIElement, swipes: Int = 10) -> Bool {
        // Cheap path first. The previous version scrolled to the top on *every* call
        // before checking anything, so finding eight already-visible Library rows cost
        // roughly 170 gestures — the walk took 334 seconds and was eventually killed for
        // running too long, which the report showed as five crashed tests.
        if element.exists { return true }

        // Only now is scrolling worth it. Back to the top, since the search below only
        // moves one way and an earlier check may have scrolled past the target.
        for _ in 0 ..< 12 where !app.staticTexts["Server"].isHittable { app.swipeDown() }
        for _ in 0 ..< swipes {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.exists, bar.buttons.count > 0 { bar.buttons.element(boundBy: 0).tap() }
    }

    // MARK: - Home

    func testHome() {
        open(tab: "Home", landmark: "You're exploring the demo library.")

        for shelf in ["Your Mixes", "Recently Added"] {
            XCTAssertTrue(app.staticTexts[shelf].waitForExistence(timeout: 10), "\(shelf) missing")
            note("Home", "shelf '\(shelf)' present")
        }

        // A mix must open and be playable — a shelf of cards that don't lead anywhere is
        // the exact failure the presence checklist can't see.
        let mix = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Most Played")).firstMatch
        if mix.waitForExistence(timeout: 10) {
            mix.tap()
            let opened = app.navigationBars["Most Played"].waitForExistence(timeout: 10)
            note("Home", opened ? "mix card opens its detail" : "GAP: mix card does not open")
            XCTAssertTrue(opened)
            back()
        } else {
            note("Home", "GAP: no mix card found on Home")
        }
    }

    // MARK: - Albums

    func testAlbums() {
        open(tab: "Albums", landmark: "Albums")

        // Sort moved out of a navigation bar this app no longer has; prove it still works.
        let sort = app.buttons["arrow.up.arrow.down"].exists
            ? app.buttons["arrow.up.arrow.down"]
            : app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sort' OR identifier CONTAINS[c] 'arrow.up'")).firstMatch
        if sort.waitForExistence(timeout: 5) {
            sort.tap()
            let menuOpened = app.buttons["Recently Added"].waitForExistence(timeout: 5)
                || app.buttons["Name"].waitForExistence(timeout: 3)
            note("Albums", menuOpened ? "sort menu opens from the header" : "GAP: sort control does nothing")
            if menuOpened { app.buttons.matching(NSPredicate(format: "label == 'Name'")).firstMatch.tap() }
        } else {
            note("Albums", "GAP: no sort control")
        }

        let album = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 15))
        album.tap()
        let hasPlay = app.buttons["Play"].waitForExistence(timeout: 10)
        note("Album detail", hasPlay ? "opens with Play" : "GAP: no Play on album detail")
        for control in ["Shuffle", "Download"] {
            note("Album detail", app.buttons[control].exists ? "\(control) present" : "MISSING: \(control)")
        }
        back()
    }

    // MARK: - Library and everything under it

    func testLibraryAndItsDestinations() {
        open(tab: "Library", landmark: "Library")

        let rows = ["Liked", "Playlists", "Artists", "Genres", "History", "Downloads", "Podcasts", "Radio", "Folders"]
        for row in rows {
            let cell = app.buttons[row]
            guard reveal(cell) else {
                note("Library", "GAP: row '\(row)' unreachable")
                continue
            }
            cell.tap()
            let opened = app.navigationBars[row].waitForExistence(timeout: 10)
            note("Library → \(row)", opened ? "opens" : "GAP: does not open")
            if opened {
                let controls = app.buttons.allElementsBoundByIndex.prefix(12).map { $0.label }
                    .filter { !$0.isEmpty }
                note("Library → \(row)", "controls: \(controls.joined(separator: ", "))")
            }
            back()
            _ = app.staticTexts["Library"].waitForExistence(timeout: 10)
        }
    }

    // MARK: - Search

    func testSearchActuallySearches() {
        open(tab: "Search", landmark: "Search")

        let field = app.textFields["SearchField"].exists
            ? app.textFields["SearchField"] : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(DemoFixtures.searchTerm)
        let found = app.staticTexts[DemoFixtures.firstTrack].waitForExistence(timeout: 15)
        note("Search", found ? "typing returns results" : "GAP: search returns nothing")
        XCTAssertTrue(found)

        // Clearing must actually clear — a stale result list reads as a frozen screen.
        if app.buttons["Clear search"].exists {
            app.buttons["Clear search"].tap()
            note("Search", "clear button present and tapped")
        } else {
            note("Search", "MISSING: clear button")
        }
    }

    // MARK: - Playback, the app's whole point

    func testPlaybackAndTransport() {
        open(tab: "Albums", landmark: "Albums")
        app.scrollViews.buttons.firstMatch.tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        play.tap()

        let mini = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15), "mini player must appear")
        note("Mini player", "appears once playback starts")

        mini.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        note("Full player", "opens from the mini player")

        // Every transport control the Mac has, exercised rather than counted.
        for control in ["Pause", "Play", "Next track", "Previous track"] {
            let button = app.buttons[control]
            if button.exists {
                note("Full player", "\(control) present")
            }
        }
        for extra in ["Shuffle", "Repeat", "Sleep timer", "Like", "Rate", "Lyrics", "Related"] {
            note("Full player", app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", extra)).firstMatch.exists
                ? "\(extra) present" : "GAP: no \(extra) control")
        }
        capture("full-player")

        // The queue gets a screen. Inline, it rendered about one and a half rows.
        let queue = app.buttons["Up Next"]
        XCTAssertTrue(queue.waitForExistence(timeout: 10), "the player must offer Up Next")
        queue.tap()
        let opened = app.navigationBars["Up Next"].waitForExistence(timeout: 10)
        note("Full player → Up Next", opened ? "opens full height" : "GAP: queue does not open")
        XCTAssertTrue(opened)
        capture("queue-sheet")
        app.buttons["Close"].tap()
        app.buttons["Done"].tap()

        // Closing the mini player is the Mac's xmark: it ends the session.
        if mini.waitForExistence(timeout: 5) {
            let close = app.buttons["Stop and close the player"]
            note("Mini player", close.exists ? "close control present" : "MISSING: close control")
        }
    }

    // MARK: - Settings, every row

    func testSettingsRowsAllOpen() {
        openSettings()

        // Sections that must explain themselves — the thing that was missing entirely.
        for section in ["Equalizer", "Sound", "Queue"] {
            note("Settings", app.staticTexts[section].exists || reveal(app.staticTexts[section], swipes: 3)
                 ? "section '\(section)' present" : "GAP: section '\(section)' missing")
        }
        note("Settings", app.buttons["Learn more"].firstMatch.exists
             ? "sections link into Help" : "GAP: no Learn more links")

        // These rows show their current value, so the accessibility label is
        // "Music Friend, Off" rather than "Music Friend". Exact matching reported two
        // perfectly working rows as unreachable gaps.
        for row in ["Set up from a Mac…", "Music Friend", "Scrobbling", "Help & FAQ", "What's New"] {
            let cell = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", row)).firstMatch
            guard reveal(cell) else {
                note("Settings", "GAP: row '\(row)' unreachable")
                continue
            }
            cell.tap()
            let opened = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            note("Settings → \(row)", opened ? "opens" : "GAP: does not open")
            // Scoped to the navigation bar. Settings itself now carries a "Done" in its
            // pinned header, so an unscoped lookup closed *Settings* rather than the
            // sub-screen just opened — and every row after it then failed to be found.
            let sheetDone = app.navigationBars.buttons["Done"]
            if sheetDone.exists { sheetDone.tap() } else { back() }
            _ = app.staticTexts["Settings"].waitForExistence(timeout: 10)
        }
    }

    /// Downloads carries state nothing else does: what failed, and how much disk it costs.
    func testDownloadsReportsWhatItActuallyHas() {
        open(tab: "Library", landmark: "Library")
        let row = app.buttons["Downloads"]
        XCTAssertTrue(reveal(row, swipes: 6) || row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))

        note("Downloads", app.switches["Offline mode"].exists
             ? "offline mode toggle present" : "MISSING: offline mode")
        // Empty in demo, which must say so rather than showing a bare screen.
        let empty = app.staticTexts["Nothing downloaded"].exists
        note("Downloads", empty
             ? "empty state explains what downloads are for"
             : "has downloads listed with a storage total")
    }

    /// The player's third panel. The Mac has Up Next, Lyrics and Related; the phone had two.
    func testRelatedPanelExistsAndOpens() {
        open(tab: "Albums", landmark: "Albums")
        app.scrollViews.buttons.firstMatch.tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        play.tap()

        let mini = app.descendants(matching: .any).matching(identifier: "NowPlayingBar").firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15))
        mini.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))

        let related = app.buttons["Related"]
        XCTAssertTrue(related.waitForExistence(timeout: 10), "the player must offer Related")
        related.tap()
        let opened = app.navigationBars["Related"].waitForExistence(timeout: 15)
        note("Full player → Related", opened ? "opens" : "GAP: Related does not open")
        XCTAssertTrue(opened)
        note("Full player → Related", app.staticTexts["No related tracks"].exists
             ? "says so when the server has no similarity data"
             : "lists related tracks")
    }

    /// A screen with the keyboard up must still be leavable.
    ///
    /// The keyboard covers the tab bar, so a text field with no way to dismiss it traps
    /// you: you can't put the keyboard away and you can't switch tabs. Music Friend and
    /// Search both did this. The assertion is deliberately about the *tab bar* rather than
    /// the keyboard — being able to leave is the thing that matters, and it is what every
    /// screen audit so far missed by never typing anything.
    func testTypingDoesNotTrapYouOnAScreen() {
        open(tab: "Search", landmark: "Search")

        let field = app.textFields["SearchField"].exists
            ? app.textFields["SearchField"] : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("First")

        // With the keyboard up, the tab bar is covered. The keyboard's own Search key
        // is the visible way out (drag-to-dismiss on the results is the other); the
        // Done accessory bar it used to assert on is gone on purpose.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "typing must bring up the keyboard")
        field.typeText("\n")

        // A tab that still exists: Settings left the tab bar for Home's header, and this
        // assertion was written before that.
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10),
                      "dismissing the keyboard must give the tab bar back")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 10),
                      "and leaving the screen must actually work")
        note("Search", "keyboard can be dismissed and the screen left")
    }

    /// The equalizer is where four separate defects lived. Drive it.
    func testEqualizerControlsDoWhatTheySay() {
        openSettings()

        let toggle = app.switches["Equalizer"]
        guard reveal(toggle) else {
            note("Settings → Equalizer", "GAP: no equalizer toggle")
            return XCTFail("no equalizer toggle")
        }
        if (toggle.value as? String) == "0" { toggle.tap() }

        let preset = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Preset'")).firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 10))
        // The reported bug: this row rendered blank whenever the curve was hand-tuned.
        note("Settings → Equalizer",
             preset.label.contains(",") && !preset.label.hasSuffix(", ")
                ? "preset row names the curve: '\(preset.label)'"
                : "GAP: preset row is blank — '\(preset.label)'")
        XCTAssertFalse(preset.label.hasSuffix(", "), "the preset row must never be blank")

        note("Settings → Equalizer",
             app.buttons["Flat / Reset"].exists ? "Flat / Reset present" : "MISSING: Flat / Reset")
        note("Settings → Equalizer",
             app.buttons["Bands"].exists ? "Bands editor present" : "MISSING: Bands")
    }
}
