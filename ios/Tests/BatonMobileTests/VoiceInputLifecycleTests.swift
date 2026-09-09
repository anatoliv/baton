import SwiftUI
import XCTest
@testable import BatonMobile

/// TBX-5350: `VoiceInput` had no `onDisappear` on the friend view and no `deinit`, so
/// switching tabs mid-recording left the microphone, the audio session and the audio-focus
/// token live — the orange mic dot stayed on and music stayed ducked with nothing on
/// screen explaining why. A `.denied` state, once entered, never cleared on its own either.
///
/// These tests host the real `MusicFriendView` in the app's own window (this target is
/// hosted inside `Baton.app`, so a real `UIWindow` is available) and remove it, which is
/// the only way to prove `.onDisappear` is actually wired rather than merely present in the
/// source. `stopCallCountForTesting` stands in for "the fake engine" the card describes:
/// `start()` always denies under test (`VoiceInput.isUnderTest`), so there is no real
/// `.listening` state to drive here, and the count is what lets a no-op `stop()` still be
/// observed as called.
@MainActor
final class VoiceInputLifecycleTests: XCTestCase {

    private func keyWindow() throws -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        guard let scene else { throw XCTSkip("no window scene available in this test host") }
        let window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        return window
    }

    func testStopIsCalledWhenTheFriendViewDisappears() throws {
        let model = MobileModel()
        let window = try keyWindow()
        let hosting = UIHostingController(rootView: MusicFriendView(model: model))
        window.rootViewController = hosting
        // Let the run loop actually attach and render the hierarchy before tearing it down —
        // `onAppear`/`onDisappear` are driven by SwiftUI's own render pass, not by this call
        // returning.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(model.voice.stopCallCountForTesting, 0,
                       "nothing should have called stop() before the view went away")

        // Swap the root view controller out — the same teardown a tab switch causes.
        window.rootViewController = UIViewController()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(model.voice.stopCallCountForTesting, 1,
                       "the friend view's onDisappear must stop voice input, or the mic and " +
                       "the audio session stay live after switching away")
    }

    func testDeniedStateClearsWhenAuthorizationIsGrantedOnRefresh() async {
        let model = MobileModel()

        // Drive into `.denied` the same way a real denial does: a failed `start()`.
        // `isUnderTest` makes every `start()` deny under XCTest, which is exactly the state
        // this test needs to begin from.
        await model.voice.start()
        guard case .denied = model.voice.state else {
            XCTFail("expected start() to deny under test, got \(model.voice.state)")
            return
        }

        let granted = VoiceInput(
            controller: model.music,
            speechAuthorizationStatus: { .authorized },
            microphonePermission: { .granted }
        )
        await granted.start()
        guard case .denied = granted.state else {
            XCTFail("expected start() to deny under test, got \(granted.state)")
            return
        }

        granted.refreshAuthorization()
        XCTAssertEqual(granted.state, .idle,
                       "a re-check that finds both permissions granted must clear a stale " +
                       ".denied banner, the way returning to the tab after " +
                       "granting access in Settings should")
    }

    func testDeniedStateStaysDeniedWhenRefreshFindsPermissionStillMissing() async {
        let stillDenied = VoiceInput(
            controller: MobileModel().music,
            speechAuthorizationStatus: { .authorized },
            microphonePermission: { .denied }
        )
        await stillDenied.start()
        guard case .denied = stillDenied.state else {
            XCTFail("expected start() to deny under test, got \(stillDenied.state)")
            return
        }

        stillDenied.refreshAuthorization()
        guard case .denied = stillDenied.state else {
            XCTFail("a re-check must not clear .denied while a permission is still missing, " +
                    "got \(stillDenied.state)")
            return
        }
    }
}
