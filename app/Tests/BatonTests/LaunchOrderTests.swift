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
        // Only the body of `init()`: code lines up to the brace that closes it. Comment lines
        // are dropped first so a brace in prose cannot shift the count.
        var lines: [String] = []
        var depth = 1
        for raw in afterApp[initStart.upperBound...].split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            for ch in line {
                if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
            }
            if depth <= 0 { break }
            lines.append(line)
        }
        return lines
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

    /// TBX-7371: `@State private var music = MusicModel()` plus `appDelegate.music = music` in
    /// `init()` built **two** models. SwiftUI's `@State` evaluates an initial-value expression
    /// lazily: the read inside `init()` forced it into a temporary (which the delegate kept), and
    /// installing the state ran it again for the scene. The MCP server, control socket, chat
    /// bridges and Shortcuts then drove a player nobody could hear.
    ///
    /// The rule this checks: no `@State` property of `BatonApp` that has an initial-value
    /// expression is read inside `init()`. A value `init()` needs goes through
    /// `_name = State(initialValue: value)`, the way `BatonMobileApp` has always done it.
    func testNoLazilyInitialisedStateIsReadInsideInit() throws {
        let source = try String(contentsOf: batonAppSource, encoding: .utf8)
        let lazyStates = source.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("@State "), t.contains(" = "),
                  let name = t.split(separator: " ").first(where: { $0 != "@State" && $0 != "private" && $0 != "var" && $0 != "fileprivate" })
            else { return nil }
            return String(name.split(separator: ":").first ?? name)
        }
        XCTAssertFalse(lazyStates.isEmpty, "found no @State properties with an initializer; update this test")

        let body = try initCodeLines()
        for name in lazyStates {
            let pattern = "(?<![_A-Za-z0-9.])\\b\(name)\\b"
            let readers = body.filter { $0.range(of: pattern, options: .regularExpression) != nil }
            XCTAssertTrue(readers.isEmpty, """
                TBX-7371: `@State private var \(name) = …` is read inside BatonApp.init (\(readers.joined(separator: " | "))). \
                SwiftUI evaluates that initializer lazily, so the read builds one instance and installing the \
                state builds another. Declare it without an initializer and assign `_\(name) = State(initialValue:)` \
                in init instead.
                """)
        }
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
