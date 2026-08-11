import XCTest
@testable import BatonMobile

/// Driving the microphone path, to reproduce a crash reported from a device.
///
/// The crash arrived as `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on
/// queue [com.apple.main-thread]` with every frame `<redacted>` — because iOS dSYMs were
/// never being uploaded, so nothing symbolicates. This runs the same path locally, where a
/// crash is a stack trace instead of a mystery.
///
/// **What these no longer cover, and why.** `VoiceInput.start()` now returns early under
/// test, because calling it here raised the speech-permission dialog *inside the test
/// host* — and that dialog is drawn by SpringBoard, so it outlived this suite and blocked
/// every UI test scheduled after it. Diagnosing that cost the better part of an hour and
/// looked like a twenty-one minute hang on an iPad it had nothing to do with.
///
/// So the two tests below no longer reach `SFSpeechRecognizer.requestAuthorization`, which
/// is the call the crash was in. They still prove the state machine cannot end up
/// `.listening` after a stop, and that double-tapping is safe — but the isolation bug
/// itself is now guarded at the source instead, by `testTheAuthorizationCallbackStaysSendable`.
/// That is a weaker guarantee than executing the call, and it is recorded here rather than
/// left to be discovered: a test that passes while exercising nothing is the exact failure
/// mode this codebase keeps being bitten by.
@MainActor
final class VoiceInputCrashTests: XCTestCase {

    /// The `@Sendable` on the authorization callback is what prevents the crash, and it is
    /// one keystroke from being deleted by someone tidying up.
    ///
    /// Without it the closure inherits `VoiceInput`'s main-actor isolation, the runtime
    /// checks the executor when TCC calls back on its own XPC queue, finds the wrong one,
    /// and traps — a hard crash, every time anyone tapped the microphone.
    func testTheAuthorizationCallbackStaysSendable() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/BatonMobile/VoiceInput.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("SFSpeechRecognizer.requestAuthorization { @Sendable status in"),
            """
            the authorization callback lost its @Sendable. It will inherit main-actor \
            isolation, and TCC calls back on its own queue — that is the libdispatch trap \
            that crashed the app for every user who tapped the microphone.
            """
        )
        XCTAssertTrue(
            source.contains("installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable"),
            "the audio tap callback lost its @Sendable — it runs on the audio thread, never the main one"
        )
    }

    func testStartingAndStoppingVoiceInputDoesNotCrash() async {
        let model = MobileModel()

        // Whatever the simulator's permission answer is, neither outcome may crash: an
        // unauthorised mic must land in `.denied`, not take the process with it.
        await model.voice.start()
        _ = model.voice.stop()

        XCTAssertNotEqual(model.voice.state, .listening,
                          "stopping must leave the recogniser idle or denied")
    }

    /// Double-tapping the mic is the easiest thing in the world to do on a phone.
    func testStartingTwiceDoesNotCrash() async {
        let model = MobileModel()

        await model.voice.start()
        await model.voice.start()
        _ = model.voice.stop()
        _ = model.voice.stop()
    }
}
