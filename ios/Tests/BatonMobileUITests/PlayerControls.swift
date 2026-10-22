import XCTest

/// What the phone's player calls its controls, written down once.
///
/// This file exists because the last rename went unnoticed for a month. On 2026-08-10
/// (f406fea9) the full player's dismiss control stopped being a trailing "Done" and became
/// a leading `chevron.down` labelled "Minimize player" — a deliberate change and the right
/// one, since nothing is committed when the player closes and "Done" was the wrong word.
/// Four UI tests across three files were still waiting on "Done" to prove the player had
/// opened. None of them was ever executed, so nobody found out.
///
/// The version of that failure worth remembering: `DurationVisualUITests` also used "Done"
/// to *close* the player. When the tap found nothing the sheet stayed up, and every later
/// gesture — the Library tab, History, the Search field — landed on its backdrop. One stale
/// label, three screens reported as missing controls they have always had.
///
/// So the label lives here rather than in three files, and the next rename is one line.
enum PlayerControls {
    /// Collapses the full player back into the mini bar. Also the proof that the full
    /// player is on screen: no other screen offers it.
    static let dismissFullPlayer = "Minimize player"

    /// The mini bar's accessibility identifier. Note that it propagates to the bar's own
    /// artwork, title and buttons, so a `firstMatch` on it is whichever of those the tree
    /// lists first. Never tap that match: it is the artwork only while a cover is drawn, and
    /// otherwise the bar's Play/Pause button, which pauses instead of opening the player.
    /// That is how three tests failed on 2026-10-16 while book chapters had no cover, and
    /// passed again once an internal task gave them one. Use `tapMiniBar` instead,
    /// which taps the middle of the bar as a person would. That tap paused the music too,
    /// until the title was given the room up to the controls.
    static let miniBar = "NowPlayingBar"
}

extension XCTestCase {
    /// Taps the mini player and waits for the full player to be on screen.
    ///
    /// Asserts on the dismiss control rather than on the artwork or the title, because it
    /// is the one element only the full player has *and* it is the way out — a player that
    /// opens without it is a trap rather than a screen.
    @discardableResult
    func openFullPlayer(in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let mini = app.descendants(matching: .any).matching(identifier: PlayerControls.miniBar).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: timeout),
                      "the mini player must appear once something is playing")
        tapMiniBar(in: app)
        let opened = app.buttons[PlayerControls.dismissFullPlayer].waitForExistence(timeout: timeout)
        XCTAssertTrue(opened, "tapping the mini player must open the full player")
        return opened
    }

    /// Taps the mini bar where a person would: the middle of what it draws, away from its
    /// buttons. The bar's elements are all named `PlayerControls.miniBar`, so their frames
    /// together are the bar; its middle is the title or the space beside it, which open the
    /// player. If a narrow bar puts a button there, the title is tapped instead.
    func tapMiniBar(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let parts = app.descendants(matching: .any).matching(identifier: PlayerControls.miniBar)
            .allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
        let buttons = parts.filter { $0.elementType == .button }.map { $0.frame }
        let bar = parts.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
        XCTAssertFalse(bar.isNull, "the mini bar has nothing on screen to tap", file: file, line: line)
        var point = CGPoint(x: bar.midX, y: bar.midY)
        if buttons.contains(where: { $0.contains(point) }),
           let title = parts.first(where: { $0.elementType == .staticText }) {
            point = CGPoint(x: title.frame.midX, y: title.frame.midY)
        }
        XCTAssertFalse(buttons.contains { $0.contains(point) }, "no part of the mini bar to tap that is not a button",
                       file: file, line: line)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    /// Collapses the full player, and says so if it was not open to begin with.
    ///
    /// Failing rather than shrugging: a silent no-op here is exactly what left the sheet up
    /// and turned one stale label into three unrelated-looking failures.
    func dismissFullPlayer(in app: XCUIApplication) {
        let dismiss = app.buttons[PlayerControls.dismissFullPlayer]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10),
                      "the full player must offer a way back to the mini bar")
        dismiss.tap()
    }
}
