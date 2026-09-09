import Foundation
import Testing
@testable import Baton

/// TBX-5350: `VoiceInput` had no `deinit` and nothing stopped it when the friend view
/// disappeared. Switching away mid-recording left the microphone, the `.playAndRecord`
/// audio session and the audio-focus token live. A `.denied` state, once entered, never
/// cleared after the user granted the permission back in System Settings.
///
/// `VoiceInput` is a `Shared/` file, so these run against the same type the iPhone's
/// `VoiceInputLifecycleTests` exercises. The iPhone suite also hosts the real friend view
/// in a window and removes it to prove `.onDisappear` is wired, not merely present in the
/// source; `MacMusicFriendView.toggleMic()` is `private` and is what constructs `voice`, so
/// there is no way to reach a non-nil `voice` here without simulating a real button click.
/// That is left to `MacMusicFriendView`'s source-text guard below, in the same style
/// `VoiceInputCrashTests.testTheAuthorizationCallbackStaysSendable` already uses in this
/// codebase for exactly this shape of constraint.
@Suite("Voice input lifecycle")
@MainActor
struct VoiceInputLifecycleTests {

    @Test("A re-check that finds both permissions granted clears a stale denial")
    func deniedClearsOnRefreshWhenGranted() async {
        let music = MusicModel(environment: .testing)
        let denied = VoiceInput(
            controller: music.music,
            speechAuthorizationStatus: { .authorized },
            microphonePermission: { .granted }
        )
        // isUnderTest forces every start() to deny, which is exactly the state this test
        // needs to begin from.
        await denied.start()
        guard case .denied = denied.state else {
            Issue.record("expected start() to deny under test, got \(denied.state)")
            return
        }

        denied.refreshAuthorization()
        #expect(denied.state == .idle)
    }

    @Test("A re-check leaves the denial in place while a permission is still missing")
    func deniedStaysDeniedWhenRefreshFindsPermissionStillMissing() async {
        let music = MusicModel(environment: .testing)
        let stillDenied = VoiceInput(
            controller: music.music,
            speechAuthorizationStatus: { .authorized },
            microphonePermission: { .denied }
        )
        await stillDenied.start()
        guard case .denied = stillDenied.state else {
            Issue.record("expected start() to deny under test, got \(stillDenied.state)")
            return
        }

        stillDenied.refreshAuthorization()
        guard case .denied = stillDenied.state else {
            Issue.record("a re-check must not clear .denied while a permission is still missing, got \(stillDenied.state)")
            return
        }
    }

    @Test("stop() is a safe no-op with nothing to release, and is still counted")
    func stopIsSafeWithNothingListening() {
        let music = MusicModel(environment: .testing)
        let voice = VoiceInput(controller: music.music)
        #expect(voice.stopCallCountForTesting == 0)
        _ = voice.stop()
        #expect(voice.stopCallCountForTesting == 1)
        #expect(voice.state != .listening)
    }

    /// `MacMusicFriendView.toggleMic()` is `private`, so this guards the wiring by source
    /// rather than by driving the view: the window closing (or a tab switch on the phone)
    /// must call `voice?.stop()`, or the mic, the session and the focus token stay live with
    /// nothing on screen explaining why.
    @Test("MacMusicFriendView stops voice input on disappear and re-checks authorization on appear")
    func macFriendViewCallsIntoVoiceInputOnLifecycleEvents() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Baton/Shell/Music/MacMusicFriendView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("voice?.stop()"),
               "MacMusicFriendView must stop voice input on disappear")
        #expect(source.contains("voice?.refreshAuthorization()"),
               "MacMusicFriendView must re-check authorization on appear")
    }
}
