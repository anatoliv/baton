import Foundation
import XCTest
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
