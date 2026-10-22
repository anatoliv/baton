import XCTest

/// Spends the first launch of Baton after `xcodebuild` installs it, before any real test does
/// Named to sort first: XCTest runs classes in name order, and
/// `ios/scripts/ui-tests.sh` adds it to every `-only` run.
///
/// On the iOS 27.0 simulator that first launch sometimes goes wrong. SpringBoard logs "Retry
/// attempt failed for io.tonebox.baton with reason LaunchServicesDataMismatch", and then either
/// XCTest gets no process ("did not return a process handle nor launch error") or Baton comes up
/// without the test's launch environment and arguments: Home at the default text size, no import
/// screen, so "the import screen did not open". In the logs of 163 runs from 2026-10-15
/// to 17, 17 failed this way, in eight suites, and every one was the first test of its run to
/// launch the app. No later launch in any run did. `BookScreenFunctionsUITests` looked like it
/// failed "in full-class runs" only because its own first test was the run's first launch.
///
/// A failed launch here is that simulator fault, so it is an expected failure, and the tests
/// after it launch normally. It measures nothing about Baton, so it never counts as a pass: it
/// ends skipped (or "Expected Failure" when the launch failed), and a run where every real test
/// skipped still fails `ui-tests.sh`'s nothing-measured check.
final class AAAFirstLaunchPrimer: XCTestCase {
    func testTheFirstLaunchAfterInstall() throws {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("the first launch after install on the iOS 27 simulator (TBX-1000000045)", options: options) {
            let app = XCUIApplication.batonUnderTest()
            app.launch()
            app.terminate()
        }
        throw XCTSkip("primed the first launch after install; not a test of Baton (TBX-1000000045)")
    }
}
