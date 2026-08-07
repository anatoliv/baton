import XCTest
@testable import BatonMobile

/// Driving the microphone path, to reproduce a crash reported from a device.
///
/// The crash arrived as `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on
/// queue [com.apple.main-thread]` with every frame `<redacted>` — because iOS dSYMs were
/// never being uploaded, so nothing symbolicates. This runs the same path locally, where a
/// crash is a stack trace instead of a mystery.
@MainActor
final class VoiceInputCrashTests: XCTestCase {
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
