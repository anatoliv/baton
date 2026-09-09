import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Baton

/// The Mac half of the check TBX-5314 ran on the phone with XCUITest: when a full-screen
/// overlay covers live content, does the covered content actually leave the accessibility
/// tree, or is it only painted over?
///
/// The phone could ask that of a running app. The Mac's full-screen player needs a signed-in
/// server, a loaded library and a playing track before it appears, which is a live-server UI
/// test and not something a merge gate can hold. So this asks the same question of the
/// modifier that screen is built from, `coveringOverlay`, by hosting it in a real window and
/// reading the tree back through `AXUIElement` - the same client API VoiceOver uses, rather
/// than the app-side `accessibilityChildren()`, which hands back opaque `AccessibilityNode`
/// objects with no titles on them.
///
/// It is a tree assertion and not a screenshot on purpose: an opaque overlay makes the broken
/// screen and the fixed screen look identical, which is how the defect survived to ship.
final class CoveringOverlayAccessibilityTests: XCTestCase {

    /// A stand-in for the browse content and the mini player behind the full-screen player:
    /// two controls a VoiceOver user can reach, with labels that are unmistakable in a tree.
    private struct Harness: View {
        let covered: Bool

        var body: some View {
            VStack {
                Button("Goldberg Variations") {}
                Button("Play") {}
            }
            .frame(width: 400, height: 300)
            .coveringOverlay(covered) {
                Button("Close full screen player") {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
    }

    @MainActor
    func testCoveredControlsLeaveTheAccessibilityTreeWhileTheOverlayIsUp() throws {
        let uncovered = try accessibilityText(of: Harness(covered: false))
        XCTAssertTrue(
            uncovered.contains("Goldberg Variations"),
            "with no overlay up the browse content must be in the accessibility tree; saw \(uncovered)"
        )

        let covered = try accessibilityText(of: Harness(covered: true))
        XCTAssertTrue(
            covered.contains("Close full screen player"),
            "the overlay's own control must stay reachable while it is up; saw \(covered)"
        )
        // The check the card asks for: a walk over the covered screen finds only what is on
        // top of it. Before `accessibilityHidden`, both of these were still in the tree while
        // the player covered the whole window, so a VoiceOver swipe reached a row that was
        // not on the screen.
        XCTAssertFalse(
            covered.contains("Goldberg Variations"),
            "content under the full-screen overlay is still in the accessibility tree, so VoiceOver still walks it; saw \(covered)"
        )
        XCTAssertFalse(
            covered.contains("Play"),
            "a transport control under the full-screen overlay is still in the accessibility tree; saw \(covered)"
        )
    }

    // MARK: - Hosting, and reading the tree back as a client

    /// How the harness window is picked out of an application tree that also holds the test
    /// host's own window and the whole menu bar.
    private static let windowTitle = "Covering overlay accessibility harness"

    /// Host `view` in an off-screen window and return every title, description and value in
    /// the accessibility tree under it.
    @MainActor
    private func accessibilityText(of view: some View) throws -> Set<String> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.contentView = hosting
        // Off the visible desktop, so a gate run does not flash a window over whatever the
        // machine is doing. It still has to be ordered in: SwiftUI builds no accessibility
        // elements for a window that was never brought on screen, and the walk would then
        // come back empty and pass for the wrong reason.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        // The tree is built lazily and the first query is what starts it, so poll rather than
        // sleep for a guessed interval.
        let application = AXUIElementCreateApplication(getpid())
        var found: Set<String> = []
        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            guard let harness = harnessWindow(in: application) else { continue }
            found = []
            collect(from: harness, into: &found, depth: 0)
            if !found.isEmpty { break }
        }

        try XCTSkipIf(
            found.isEmpty,
            "no accessibility tree was readable for this process, so the covered content cannot be checked here"
        )
        return found
    }

    /// The harness window among the application's windows, by title.
    private func harnessWindow(in application: AXUIElement) -> AXUIElement? {
        guard let windows = copy(application, "AXWindows") as? [AXUIElement] else { return nil }
        return windows.first { copy($0, "AXTitle") as? String == Self.windowTitle }
    }

    private func collect(from element: AXUIElement, into found: inout Set<String>, depth: Int) {
        guard depth < 25 else { return }
        for attribute in ["AXTitle", "AXDescription", "AXValue"] {
            if let text = copy(element, attribute) as? String, !text.isEmpty { found.insert(text) }
        }
        guard let children = copy(element, "AXChildren") as? [AXUIElement] else { return }
        for child in children { collect(from: child, into: &found, depth: depth + 1) }
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}
