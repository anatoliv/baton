import Foundation
import XCTest
@testable import Baton
#if canImport(AppKit)
import AppKit
#endif

/// The test bundle's `NSPrincipalClass` (see `app/project.yml`). XCTest instantiates it
/// when it loads the bundle, which is how the diagnostic below arms *before* the first
/// test rather than partway through the run.
///
/// Separate from `RunnerExitDiagnostic` on purpose: arming from that type's own `init`
/// would re-enter its lazy static initializer from inside itself, and a `swift_once` that
/// waits on itself hangs the process at bundle load.
@objc(BatonRunnerExitDiagnostic)
final class RunnerExitDiagnosticBootstrap: NSObject {
    override init() {
        super.init()
        RunnerExitDiagnostic.arm()
        Self.hideTheTestHostFromTheDockAndMenuBar()
        // And silence it. The host is Baton, so a speech suite otherwise talks through the
        // speakers of whoever is using this machine, over the top of the real app — which is
        // indistinguishable, by ear, from the app itself misbehaving.
        SpeechAudioPlayer.isMuted = true
    }

    /// Take the test host out of the Dock and the menu bar for the duration of the run.
    ///
    /// **This is the fix for the runner deaths the diagnostic above kept catching.** The host
    /// *is* Baton, a menu-bar app, so a gate run put a second Baton icon in the menu bar and a
    /// second entry in the Dock, right next to the real one. Quitting "the extra Baton" is an
    /// entirely reasonable thing for a person to do at their own machine, and it killed the run.
    /// The diagnostic named the caller four times over: a menu-bar click three times and an
    /// Apple Event quit once, each blaming whichever test happened to be in flight. Every one of
    /// those tests passed in isolation, which is exactly how a gate teaches people to distrust it.
    ///
    /// `.accessory` hides the icon and the menu bar without hiding windows, so tests that build
    /// UI still work. It applies only to the unit-test bundle: `BatonUITests` is a separate
    /// scheme that launches the app as its own process and never loads this bundle, so the
    /// UI-tested app still looks like the real thing.
    ///
    /// A gate that a passer-by can end by an ordinary action is not a gate.
    private static func hideTheTestHostFromTheDockAndMenuBar() {
        #if canImport(AppKit)
        let hide: () -> Void = {
            // Not `NSApp`: at bundle-load time the shared application may not be assigned yet,
            // and `NSApplication.shared` creates it if needed rather than returning nil.
            // The Bool result is whether the policy changed; nothing useful to do with it here.
            _ = NSApplication.shared.setActivationPolicy(.accessory)
        }
        if Thread.isMainThread { hide() } else { DispatchQueue.main.async(execute: hide) }
        #endif
    }
}

/// Catches the test host exiting out from under the suite, and names what did it.
///
/// On 2026-08-12 a gate run died with "The test runner exited with code 0 before finishing
/// running tests" — attributed to whichever test happened to be in progress
/// (`RemoteAgentConversationEval`), which passes cleanly in isolation. By the time anyone
/// looked, the result bundle and the run's log had both been reaped out of `$TMPDIR`, so
/// the process death left no evidence at all and the cause is still unknown.
///
/// A clean exit is the useful clue: something *called* `exit` (or `-[NSApplication
/// terminate:]`, which ends there too), and an `atexit` handler runs inside that call, so
/// its backtrace names the caller. Nothing is printed on a normal end-of-run exit — only
/// when the process leaves while a test is still running, which is the case that has no
/// other witness.
final class RunnerExitDiagnostic: NSObject, XCTestObservation {
    /// Idempotent. Also called from `RemoteAgentConversationEval`, so the instrumentation
    /// survives the principal class not being instantiated.
    static func arm() {
        _ = installed
    }

    private static let installed: Bool = {
        let observer = RunnerExitDiagnostic()
        XCTestObservationCenter.shared.addTestObserver(observer)
        retained = observer

        atexit {
            guard let test = RunnerExitDiagnostic.testInProgress() else { return }
            var report = "\n*** BATON-DIAG: the test host is exiting while \(test) is still running.\n"
            report += "*** This is the TBX-2848 runner death. What called exit:\n"
            for frame in Thread.callStackSymbols { report += "***   \(frame)\n" }
            FileHandle.standardError.write(Data(report.utf8))
        }
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            let test = RunnerExitDiagnostic.testInProgress() ?? "no test"
            let report = "\n*** BATON-DIAG: NSApplication is terminating (\(test) running). Who asked:\n"
                + Thread.callStackSymbols.map { "***   \($0)\n" }.joined()
            FileHandle.standardError.write(Data(report.utf8))
        }
        #endif
        FileHandle.standardError.write(Data("*** BATON-DIAG armed\n".utf8))
        return true
    }()

    /// Held for the process's lifetime — `XCTestObservationCenter` does not retain observers.
    private nonisolated(unsafe) static var retained: RunnerExitDiagnostic?

    private nonisolated(unsafe) static var running: String?
    private static let lock = NSLock()

    static func testInProgress() -> String? {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        Self.lock.lock(); Self.running = testCase.name; Self.lock.unlock()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        Self.lock.lock(); Self.running = nil; Self.lock.unlock()
    }
}
