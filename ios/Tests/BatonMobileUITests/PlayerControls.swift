import XCTest

/// What the phone's player calls its controls, written down once.
///
/// This file exists because the last rename went unnoticed for a month. On 2026-08-10
/// (f406fea9) the full player's dismiss control stopped being a trailing "Done" and became
/// a leading `chevron.down` labelled "Minimize player" — a deliberate change and the right
/// one, since nothing is committed when the player closes and "Done" was the wrong word.
/// Four UI tests across three files were still waiting on "Done" to prove the player had
/// opened. None of them was ever executed, so nobody found out (TBX-5173, TBX-5174).
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
    /// buttons and images, so a `firstMatch` on it can be the artwork rather than the
    /// container — which is harmless, because the whole bar carries the tap gesture.
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
        mini.tap()
        let opened = app.buttons[PlayerControls.dismissFullPlayer].waitForExistence(timeout: timeout)
        XCTAssertTrue(opened, "tapping the mini player must open the full player")
        return opened
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
