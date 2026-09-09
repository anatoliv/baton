import XCTest

/// The phone can show what the friend remembers, and forgetting one removes it.
///
/// ## Why this test exists rather than a unit test
///
/// `friendMemory` appeared five times in the whole iPhone app and every one was in
/// `MobileModel`. Memories — preferences and facts about the person, in their own words —
/// were stored, sent to a model to steer its answers, and never shown to the person they were
/// about. Corrections had a list with swipe-to-delete; memories had no surface at all.
///
/// A unit test on `RemoteMemoryStore` would have passed throughout, because the store was never
/// the broken half. What was missing was a screen, and only a screen test can tell a rendered
/// list from an empty one. That is the same lesson this repo keeps re-learning: a grid whose
/// cells all measured the same, a mix card nothing could tap, an equalizer whose coefficients
/// were perfect and never applied.
///
/// ## And why it matters beyond the missing screen
///
/// Memories cross between devices now. A memory that fails to arrive, arrives twice, or comes
/// back after a forget was, on this platform, diagnosable only by pulling a JSON file out of a
/// simulator container. This is the screen that makes those visible — so it is worth a test
/// that fails when the screen goes away.
///
/// Seeded with `-uitestSeedMemories`, a DEBUG-only affordance beside `-uitestServer`: memories
/// are otherwise written only by a live model deciding to remember something mid-conversation,
/// which is not something a test can arrange. `-uitestVerifiedAgent` stands in for the
/// connection test that puts the Friend tab on screen. Both are stand-ins for something a
/// person did, in the same category as `-uitestServer`; whether verification itself works is a
/// different claim, and `FriendVerificationEvidenceTests` proves that one against a real stub.
///
/// It needs `demo.navidrome.org` to reach a tab bar, so it belongs to the network half of this
/// suite.
final class FriendMemoryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // TBX-5336: launchEnvironment, not launchArguments — see CLAUDE.md's UI-test section.
        app.launchEnvironment["baton.resetSession"] = "1"
        app.launchEnvironment["uitestServer"] = "https://demo.navidrome.org"
        app.launchEnvironment["uitestUser"] = "demo"
        app.launchEnvironment["uitestSecret"] = "demo"
        app.launchEnvironment["uitestSeedMemories"] = "YES"
        // Stands in for a connection test the person already passed, so the Friend tab is
        // there. Without it this skipped on every clean simulator, which is a test that
        // reads as coverage and is not.
        app.launchEnvironment["uitestVerifiedAgent"] = "YES"
    }

    override func tearDown() { app = nil; super.tearDown() }

    func testTheFriendLogShowsWhatTheFriendRemembersAndForgettingOneRemovesIt() throws {
        app.launch()

        // The Friend tab only appears once a connection test has passed, which is why the
        // launch arguments stand one in. If it is absent the flag has stopped working, and
        // that is a failure rather than a reason to skip — a test that skips itself out of
        // existence on a clean machine is the thing this suite is being audited for.
        let friendTab = app.tabBars.buttons["Friend"]
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 90), "the app must reach its tab bar")
        XCTAssertTrue(friendTab.waitForExistence(timeout: 20),
                      "the Friend tab is absent — `-uitestVerifiedAgent` no longer reaches markVerified()")
        friendTab.tap()

        // The log is behind the header button on the Music Friend screen — the same place the
        // corrections have always been, which is the point: one answer to "what does it know
        // about me" rather than two screens.
        let log = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'log'")).firstMatch
        if log.waitForExistence(timeout: 5) {
            log.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let header = app.staticTexts["What it remembers"]
        XCTAssertTrue(header.waitForExistence(timeout: 15),
                      "the Friend Log has no memories section — the phone is back to showing corrections only")

        let firstMemory = app.staticTexts["No vocals while they are working"]
        XCTAssertTrue(firstMemory.waitForExistence(timeout: 5), "the seeded memory is not on screen")
        // The quote, not a paraphrase: it is what makes a wrong memory correctable rather than
        // merely deniable, and it is the store's own invariant made visible.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'no vocals while'")).firstMatch.exists,
            "the memory is shown without the words it came from")

        add(screenshot(named: "friend-log-memories"))

        // Forgetting one. Not cosmetic: this is the path that lays a tombstone, which is the
        // only thing that stops another device pushing the memory straight back.
        firstMemory.swipeLeft()
        let delete = app.buttons["Delete"]
        if delete.waitForExistence(timeout: 3) { delete.tap() }

        XCTAssertFalse(firstMemory.waitForExistence(timeout: 5),
                       "the forgotten memory is still on screen — the list is not observing the store")
        XCTAssertTrue(app.staticTexts["The gothic playlists are their partner's"].exists,
                      "forgetting one memory removed the others")

        add(screenshot(named: "friend-log-after-forget"))
    }

    private func screenshot(named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
