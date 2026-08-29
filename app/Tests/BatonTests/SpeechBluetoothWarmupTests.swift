import AVFoundation
import BatonPlaybackKit
import XCTest
@testable import Baton

/// The Bluetooth cold-start fix: a link that has gone to standby takes long enough to wake
/// that it swallows the first word of a summary.
///
/// **What a suite can and cannot prove here.** Whether the first word survived is a fact about
/// a room, like routing before it — the listening test belongs to the ticket. What is testable
/// is the part that is easy to get subtly wrong and impossible to hear afterwards: that the
/// warm-up pad is the right length, that it is *inaudible without being silent*, and that the
/// two settings clamp instead of trusting whatever ends up in `UserDefaults`.
///
/// The lifecycle itself (linger, first-render gating) is deliberately not asserted: it depends
/// on the machine's current output device, so an engineer running the suite with Bluetooth
/// headphones on would get different results from one on the built-in speakers. A test that
/// passes or fails by what is paired is worse than no test.
@MainActor
final class SpeechBluetoothWarmupTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "baton.tests.bluetooth.\(UUID().uuidString)")
        SpeechConfig.defaults = defaults
    }

    override func tearDown() {
        SpeechConfig.defaults = .standard
        defaults = nil
        super.tearDown()
    }

    // MARK: - The pad

    /// −65 dBFS is inaudible; digital silence is *also* inaudible, and that is the trap. Many
    /// Bluetooth speakers decide they are idle by looking for signal, so a pad of exact zeros
    /// can fail to wake one — which looks identical to having no pad at all. This is the only
    /// place that distinction is checked, because nothing downstream can tell the difference.
    func testWarmUpPadIsInaudibleButNotSilent() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pad = try XCTUnwrap(SpeechAudioPlayer.warmUpBuffer(format: format, seconds: 0.5))

        XCTAssertEqual(pad.frameLength, 24_000, "half a second at 48 kHz")

        let samples = try XCTUnwrap(pad.floatChannelData)
        var peak: Float = 0
        var nonZero = 0
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< Int(pad.frameLength) {
                let value = samples[channel][frame]
                peak = max(peak, abs(value))
                if value != 0 { nonZero += 1 }
            }
        }

        XCTAssertGreaterThan(nonZero, 0, "a pad of digital silence can leave the speaker asleep")
        XCTAssertGreaterThan(peak, 0, "the pad must carry signal, not zeros")
        // −60 dBFS ≈ 0.001. Anything at or above that stops being a warm-up and starts being
        // a noise you can hear before every summary.
        XCTAssertLessThan(peak, 0.001, "the pad must stay inaudible")
    }

    func testWarmUpPadLengthFollowsSampleRate() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let pad = try XCTUnwrap(SpeechAudioPlayer.warmUpBuffer(format: format, seconds: 0.7))
        XCTAssertEqual(pad.frameLength, 15_435, "0.7s at 22.05 kHz")
    }

    /// A zero-length pad would be scheduled and complete instantly, which is a confusing way to
    /// express "no warm-up". The caller gates on `seconds > 0`; this proves the buffer maker
    /// never hands back an empty one regardless.
    func testWarmUpPadIsNeverEmpty() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pad = try XCTUnwrap(SpeechAudioPlayer.warmUpBuffer(format: format, seconds: 0))
        XCTAssertGreaterThan(pad.frameLength, 0)
    }

    // MARK: - The settings

    func testWarmupDefaultsToSevenHundredMilliseconds() {
        XCTAssertEqual(SpeechConfig.bluetoothWarmup, 0.7, accuracy: 0.0001)
    }

    /// The floor is a number a person types into Settings, so it has to survive nonsense. A
    /// negative value would schedule nothing; a huge one would sit in silence for a minute
    /// before every summary and read as the feature being broken.
    func testWarmupClampsToASaneRange() {
        SpeechConfig.bluetoothWarmup = -5
        XCTAssertEqual(SpeechConfig.bluetoothWarmup, 0, accuracy: 0.0001)

        SpeechConfig.bluetoothWarmup = 500
        XCTAssertEqual(SpeechConfig.bluetoothWarmup, 5, accuracy: 0.0001)

        SpeechConfig.bluetoothWarmup = 1.25
        XCTAssertEqual(SpeechConfig.bluetoothWarmup, 1.25, accuracy: 0.0001)
    }

    func testLingerDefaultsAndClamps() {
        XCTAssertEqual(SpeechConfig.engineLinger, 25, accuracy: 0.0001)

        SpeechConfig.engineLinger = -1
        XCTAssertEqual(SpeechConfig.engineLinger, 0, accuracy: 0.0001,
                       "zero is the documented way to restore always-teardown")

        SpeechConfig.engineLinger = 10_000
        XCTAssertEqual(SpeechConfig.engineLinger, 300, accuracy: 0.0001)
    }

    // MARK: - Transport

    /// The whole fix hangs off this one query: read it wrong and either every wired summary
    /// gains a needless delay, or no Bluetooth one gets its pad. An unreadable transport must
    /// resolve to "not Bluetooth" — the direction that changes nothing for wired output.
    func testTransportTypeIsReadableForTheDefaultOutput() throws {
        let device = AudioOutputDevices.defaultOutputDeviceID()
        try XCTSkipIf(device == 0, "no output device on this machine")

        let transport = try XCTUnwrap(AudioOutputDevices.transportType(of: device),
                                      "a real output device always reports a transport")
        XCTAssertNotEqual(transport, 0)
        // Consistency, not a fixed answer: what is plugged in is not ours to assume.
        let bluetooth = transport == UInt32(kAudioDeviceTransportTypeBluetooth)
            || transport == UInt32(kAudioDeviceTransportTypeBluetoothLE)
        XCTAssertEqual(AudioOutputDevices.isBluetooth(device), bluetooth)
    }

    func testUnknownDeviceIsNotTreatedAsBluetooth() {
        XCTAssertFalse(AudioOutputDevices.isBluetooth(AudioDeviceID(0xDEAD_BEEF)),
                       "a device we cannot read must not gain a warm-up delay")
    }
}
