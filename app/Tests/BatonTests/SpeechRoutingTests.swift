import AVFoundation
import XCTest
@testable import Baton

/// §3.5 — spoken summaries follow the output device the user picked.
///
/// **What these can and cannot prove.** Routing itself is not testable from a suite: whether
/// sound came out of the kitchen speaker is a fact about a room. What *is* testable, and what
/// actually blocked this feature for so long, is the layer underneath — that speech is played
/// through a graph Baton owns at all. `AVAudioPlayer` and `AVSpeechSynthesizer` have no
/// output-device API, so while either of them was doing the playing there was nothing to
/// route; no test could have failed to say so, and none did. These assert the property that
/// makes routing possible, and the ticket carries the listening test that finishes the job.
@MainActor
final class SpeechRoutingTests: XCTestCase {

    /// A short WAV, built rather than fixtured so the expected duration is exact.
    private func toneWAV(seconds: Double, sampleRate: Double = 22_050) throws -> Data {
        let frames = Int(seconds * sampleRate)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0 ..< frames {
            samples[i] = Int16(12_000 * sin(2 * .pi * 440 * Double(i) / sampleRate))
        }
        var data = Data()
        func le(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(frames * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le(16); le16(1); le16(1)
        le(UInt32(sampleRate)); le(UInt32(sampleRate) * 2); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le(payload)
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }
        return data
    }

    // MARK: The player

    /// A server clip decodes into the graph and reports the duration the audio actually has.
    ///
    /// The duration is not cosmetic: it is what `canSeek` and the HUD scrubber are gated on,
    /// and under `AVAudioPlayer` it came free. Decoding by hand means it has to be right.
    func testAServerClipDecodesWithItsRealDuration() throws {
        let player = SpeechAudioPlayer()
        try player.load(data: try toneWAV(seconds: 1.5))
        XCTAssertEqual(player.duration, 1.5, accuracy: 0.05,
                       "the decoded clip's duration does not match the audio — the HUD and the seek gate both read this")
    }

    /// Seeking moves the playhead and stays inside the clip.
    ///
    /// Asserted without starting the engine: the playhead is `startFrame` plus the node's
    /// elapsed time, and with nothing rendering the second term is zero — so this pins the
    /// seek arithmetic on its own, rather than measuring how fast the machine schedules audio.
    /// (The suite has been bitten before by tests that timed the machine and reported the code.)
    func testSeekMovesThePlayheadAndClampsToTheClip() throws {
        let player = SpeechAudioPlayer()
        try player.load(data: try toneWAV(seconds: 2.0))

        player.seek(to: 1.0)
        XCTAssertEqual(player.currentTime, 1.0, accuracy: 0.05)

        player.seek(to: 99)
        XCTAssertEqual(player.currentTime, player.duration, accuracy: 0.05,
                       "a seek past the end must land at the end, not beyond it")

        player.seek(to: -5)
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.05,
                       "a seek before the start must land at zero")
    }

    /// Unloading drops the clip, so nothing can be resumed from a cancelled summary.
    func testUnloadClearsTheClip() throws {
        let player = SpeechAudioPlayer()
        try player.load(data: try toneWAV(seconds: 1.0))
        XCTAssertGreaterThan(player.duration, 0)
        player.unload()
        XCTAssertEqual(player.duration, 0, "a cancelled summary left its clip loaded")
    }

    /// Garbage in is an error, not a crash or a silent zero-length clip.
    func testUndecodableAudioThrows() {
        let player = SpeechAudioPlayer()
        XCTAssertThrowsError(try player.load(data: Data("not audio at all".utf8)),
                             "undecodable audio must surface as an error so the utterance queue advances")
    }

    // MARK: The native voice

    /// The built-in voice synthesizes to buffers, which is what lets it be routed at all.
    ///
    /// **This is the half of §3.5 that no `AVPlayer` swap could have fixed**, and the half that
    /// matters most: the native voice is the *fallback*, the one that speaks when the TTS
    /// server is unreachable. Routing that worked only while the server was up would fail
    /// exactly when things had already gone wrong.
    ///
    /// Skips rather than fails when the system has no usable voice — an environment that
    /// cannot synthesize is not measurable, which is the same judgement the conversation eval
    /// makes about an unreachable model host.
    func testTheNativeVoiceRendersToBuffersWithAWordTimeline() async throws {
        let voice = AVSpeechSynthesisVoice(language: "en-US")
        try XCTSkipIf(voice == nil, "no en-US voice installed — synthesis is not measurable here")

        let render = await NativeSpeechRenderer.render(
            "The kitchen speaker is playing your summary.", voice: voice
        )
        let result = try XCTUnwrap(
            render, "the built-in voice produced no audio — it would fall back to speaking unrouted"
        )

        XCTAssertGreaterThan(result.pcm.frameLength, 0, "synthesis returned an empty buffer")
        let seconds = Double(result.pcm.frameLength) / result.pcm.format.sampleRate
        XCTAssertGreaterThan(seconds, 0.4, "that sentence cannot be spoken in \(seconds)s — the buffers were truncated")

        // The word timeline is what keeps the HUD highlight honest. Ranges arrive during
        // synthesis, which runs far faster than realtime, so each one is stamped with the
        // audio produced so far; without that the highlight races to the end of the sentence
        // before a word has been heard.
        XCTAssertFalse(result.words.isEmpty, "no word boundaries were captured — the HUD highlight has nothing to follow")
        XCTAssertEqual(result.words.map(\.time), result.words.map(\.time).sorted(),
                       "word times are not monotonic, so the highlight would jump backwards")
        for word in result.words {
            XCTAssertLessThanOrEqual(word.time, seconds + 0.01,
                                     "a word is timed past the end of the audio")
        }
    }

    // MARK: The engine's contract

    /// A rendered native utterance is seekable, where it never used to be.
    ///
    /// This is the behavioural consequence worth pinning: `canSeek` used to read
    /// `!currentIsNative`, because `AVSpeechSynthesizer` had no playhead. Now that the voice is
    /// PCM in our own graph it has a duration and a position like any clip, and the predicate
    /// is "is this rendering through our graph" instead.
    func testARenderedNativeUtteranceBecomesSeekable() async throws {
        let voice = AVSpeechSynthesisVoice(language: "en-US")
        try XCTSkipIf(voice == nil, "no en-US voice installed — synthesis is not measurable here")

        let engine = SpeechPlaybackEngine()
        engine.speakNative("Routing the built-in voice through our own graph.")

        // Synthesis is async; wait for the engine to report a duration, which only a rendered
        // clip can have.
        let deadline = Date().addingTimeInterval(20)
        while engine.duration == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { engine.cancel() }

        // Asserted, not skipped. A skip here would swallow the precise regression this test
        // exists for: if the native voice stopped rendering through the graph and went back to
        // speaking for itself, `duration` would be nil and the test would quietly report
        // "not measurable" while the feature was gone. The environment was already ruled out
        // above — a voice is installed — so nothing arriving now is a finding, not a fact
        // about the machine. (Caught by mutation-testing this very test: forcing the fallback
        // path made it skip rather than fail.)
        XCTAssertNotNil(engine.duration,
                        "the built-in voice never produced a routable clip — it has fallen back to speaking unrouted, which is the bug §3.5 is about")
        XCTAssertTrue(engine.canSeek,
                      "a native utterance rendered through the graph should be seekable — it has a duration and a playhead now")
    }
}
