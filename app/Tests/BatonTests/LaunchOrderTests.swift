import AppKit
import XCTest

/// TBX-7352: with crash reporting on, Baton 0.19.6 froze the moment its menu bar menu opened.
///
/// `BatonApp.init` starts the crash-reporting SDK on a background queue. When that queue reached
/// `NSApplication.shared` before the main thread did, AppKit initialised on the background thread
/// and registered its event-tracking and modal-panel run loop modes as common modes there. The
/// main run loop kept only the default mode, so while a menu tracked, the main queue never ran:
/// SwiftUI never filled the menu, it opened empty and invisible, and the app stopped answering.
///
/// The fix is one line, `_ = NSApplication.shared` on the main thread before reporting starts.
/// Nothing else would notice it going missing: tests never start the SDK, so the race cannot
/// happen in this host. The source-order test is the guard; `scripts/probe-menubar-freeze.sh`
/// is the mechanism check against a real probe build with reporting on.
final class LaunchOrderTests: XCTestCase {
    private var batonAppSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BatonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .appendingPathComponent("Sources/Baton/BatonApp.swift")
    }

    /// The code lines of `BatonApp.init()`, comments and blank lines dropped.
    private func initCodeLines() throws -> [String] {
        let source = try String(contentsOf: batonAppSource, encoding: .utf8)
        guard let app = source.range(of: "struct BatonApp: App {") else {
            XCTFail("BatonApp.swift no longer declares `struct BatonApp: App`; update this test")
            return []
        }
        let afterApp = source[app.upperBound...]
        guard let initStart = afterApp.range(of: "\n    init() {") else {
            XCTFail("BatonApp no longer has an `init()`; update this test")
            return []
        }
        return afterApp[initStart.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
    }

    func testNSApplicationIsCreatedBeforeCrashReportingStarts() throws {
        let lines = try initCodeLines()
        let appLine = lines.firstIndex(of: "_ = NSApplication.shared")
        let reportingLine = lines.firstIndex { $0.hasPrefix("CrashReporting.startIfEnabled(") }

        XCTAssertNotNil(reportingLine, "BatonApp.init no longer starts crash reporting; revisit TBX-7352's guard")
        guard let reportingLine else { return }
        guard let appLine else {
            return XCTFail("""
                TBX-7352: BatonApp.init must run `_ = NSApplication.shared` before \
                `CrashReporting.startIfEnabled()`. Without it the SDK's background queue can create \
                NSApplication first, and the menu bar menu then freezes the whole app.
                """)
        }
        XCTAssertLessThan(appLine, reportingLine, """
            TBX-7352: `_ = NSApplication.shared` must come before `CrashReporting.startIfEnabled()` \
            in BatonApp.init, or the SDK's background queue can create NSApplication first.
            """)
    }

    /// The invariant the bug broke, checked in this process: the main run loop's common modes
    /// include event tracking (a menu is open) and modal panel. A block scheduled for the common
    /// modes runs only in a mode that is one of them, which is exactly the property TBX-7352 lost.
    /// `CFRunLoopPerformBlock` rather than `DispatchQueue.main` so the answer does not depend on
    /// whether this test method itself is running inside a main-queue callout.
    ///
    /// It cannot reproduce TBX-7352's race here, but it fails if anything else ever leaves those
    /// modes out of the main run loop's common modes.
    @MainActor
    func testTrackingAndModalModesAreCommonModesOfTheMainRunLoop() {
        let main = CFRunLoopGetMain()
        for mode in [RunLoop.Mode.eventTracking, .modalPanel] {
            var ran = false
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { ran = true }
            CFRunLoopWakeUp(main)
            let deadline = Date().addingTimeInterval(1)
            while !ran, Date() < deadline {
                _ = CFRunLoopRunInMode(CFRunLoopMode(mode.rawValue as CFString), 0.05, true)
            }
            XCTAssertTrue(ran, "\(mode.rawValue) is not a common mode of the main run loop")
        }
    }
}
