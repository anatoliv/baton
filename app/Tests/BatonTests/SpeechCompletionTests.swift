import AVFoundation
import XCTest
@testable import Baton

/// The end of an utterance must be reported, or the speaking session never ends.
///
/// **Written after a real failure, found by listening.** The routing rewrite moved speech onto
/// its own `AVAudioEngine`, and the whole existing speech suite (27 tests) stayed green — none
/// of it plays audio, so none of it could see that the completion callback stopped arriving.
/// The HUD sat at `0:00` with a Play button after a summary had been heard, and because
/// `endSession()` never ran, the **ducked music volume was never restored**: the library sat at
/// 20% indefinitely. That is a worse bug than the routing gap it was fixing.
///
/// This drives real audio through the real graph, because that is the only thing that would
/// have caught it.
@MainActor
final class SpeechCompletionTests: XCTestCase {

    private func toneWAV(seconds: Double, sampleRate: Double = 22_050) throws -> Data {
        let frames = Int(seconds * sampleRate)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0 ..< frames {
            samples[i] = Int16(8_000 * sin(2 * .pi * 440 * Double(i) / sampleRate))
        }
        var data = Data()
        func le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(frames * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le(16); le16(1); le16(1)
        le(UInt32(sampleRate)); le(UInt32(sampleRate) * 2); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le(payload)
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }
        return data
    }

    /// A clip that plays out must call `onFinish`.
    ///
    /// Skips when there is no usable output device — an engine with nowhere to render cannot
    /// play a buffer to its end, and that is not measurable rather than broken. It does *not*
    /// skip on a missed callback: that is the regression.
    func testAClipThatPlaysOutReportsFinished() async throws {
        try XCTSkipIf(AudioOutputDevices.defaultOutputDeviceID() == 0,
                      "no output device — a clip cannot play out here")

        let player = SpeechAudioPlayer()
        var finished = 0
        player.onFinish = { finished += 1 }

        try player.load(data: try toneWAV(seconds: 0.4))
        player.play()

        let deadline = Date().addingTimeInterval(8)
        while finished == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        player.unload()

        XCTAssertEqual(finished, 1,
                       "the clip never reported finishing — the speaking session would never end, and a ducked music volume would never be restored")
    }

    /// The playhead has to advance while a clip plays, or the HUD sits at 0:00 forever.
    func testThePlayheadAdvancesWhilePlaying() async throws {
        try XCTSkipIf(AudioOutputDevices.defaultOutputDeviceID() == 0,
                      "no output device — nothing will render here")

        let player = SpeechAudioPlayer()
        try player.load(data: try toneWAV(seconds: 2.0))
        player.play()

        var moved = false
        let deadline = Date().addingTimeInterval(5)
        while !moved, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            moved = player.currentTime > 0.05
        }
        player.unload()

        XCTAssertTrue(moved, "the playhead never advanced — the HUD progress bar and the word highlight both read this")
    }

    /// The whole session, through the engine the app actually uses: speaking ends by itself.
    ///
    /// `isSpeaking` staying true is what holds the audio-focus duck open, so this is the
    /// assertion that corresponds to the symptom actually observed — music stuck quiet.
    func testTheSpeakingSessionEndsOnItsOwn() async throws {
        try XCTSkipIf(AudioOutputDevices.defaultOutputDeviceID() == 0,
                      "no output device — a clip cannot play out here")

        let engine = SpeechPlaybackEngine()
        engine.play(data: try toneWAV(seconds: 0.4))
        XCTAssertTrue(engine.isSpeaking, "playing a clip should start a speaking session")

        let deadline = Date().addingTimeInterval(8)
        while engine.isSpeaking, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { engine.cancel() }

        XCTAssertFalse(engine.isSpeaking,
                       "the speaking session never ended by itself — the music duck is released by endSession(), so the library would stay at the ducked volume indefinitely")
    }
}
