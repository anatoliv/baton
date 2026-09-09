import SwiftUI
import XCTest

@testable import BatonMobile

/// Shelf cards have to widen as the text under them does.
///
/// `CardMetrics.shelfCard` was keyed only on the horizontal size class, so at the largest
/// accessibility size Home drew every album title as "Varia…" and every artist as "Kimik…":
/// a row of covers with no words on it. The width is the whole cause, because both the
/// artwork frame and the label frame come from this one number.
///
/// It is a pure function, so the scaling half is answerable offline. The screenshot that
/// goes with it lives in the UI tests, where the layout can actually be looked at.
final class CardMetricsScalingTests: XCTestCase {
    func testShelfCardGrowsWithTheTextSize() {
        let base = CardMetrics.shelfCard(.compact, .large)
        XCTAssertEqual(base, 142, "the phone's default card width changed")

        // Every accessibility step is wider than the default. This is the assertion that
        // fails on the old implementation, which returned 142 whatever the text size.
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            XCTAssertGreaterThan(
                CardMetrics.shelfCard(.compact, size), base,
                "a card at \(size) is no wider than at the default size, so its title still clips"
            )
        }
    }

    func testShelfCardIsCappedSoTheShelfStaysAShelf() {
        // A 393pt phone. A card wider than about two thirds of that stops reading as a row
        // you can scroll, which was the objection to scaling it at all.
        let widest = CardMetrics.shelfCard(.compact, .accessibility5)
        XCTAssertLessThanOrEqual(widest, 220, "the card outgrew the screen it sits on")
        XCTAssertEqual(widest, CardMetrics.shelfCard(.compact, .accessibility3),
                       "growth is capped, so the top three steps share a width")
    }

    func testScalingIsMonotonic() {
        let steps: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
        ]
        var previous = CardMetrics.typeScale(steps[0])
        for size in steps.dropFirst() {
            let current = CardMetrics.typeScale(size)
            XCTAssertGreaterThanOrEqual(current, previous, "the card shrank going from one step to \(size)")
            previous = current
        }
    }

    /// The iPad number has to move with the phone's, or a regular-width canvas keeps the
    /// clipping the compact one just lost.
    func testRegularWidthScalesToo() {
        XCTAssertEqual(CardMetrics.shelfCard(.regular, .large), 200)
        XCTAssertGreaterThan(CardMetrics.shelfCard(.regular, .accessibility5),
                             CardMetrics.shelfCard(.regular, .large))
    }
}
