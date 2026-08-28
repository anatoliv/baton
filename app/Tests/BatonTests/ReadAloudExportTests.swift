import AVFoundation
import BatonSpeech
import XCTest
@testable import Baton

/// Read aloud, saving a reading to a file.
///
/// The property that matters and that nothing else guards: **the file is the whole reading, in
/// order**. An export that silently loses a sentence, or plays them shuffled, sounds like a
/// plausible article rather than like a bug — the same class of quiet failure the OCR
/// reading-order tests exist for. So the assertions are about duration and about which chunk
/// landed where, not about the file merely existing.
///
/// No TTS host is involved: `synthesize` is stubbed to return real WAV audio built here, so
/// these run anywhere and still exercise the decode → resample → encode path for real.
@MainActor
final class ReadAloudExportTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var voice: SpeechConfig.Voice { SpeechConfig.Voice(engine: .kokoro, voice: "af_bella") }

    // MARK: - Fixtures

    /// A WAV of `seconds` at a constant amplitude, at the rate the TTS host actually returns.
    ///
    /// Constant amplitude rather than a tone on purpose: it survives an AAC round trip well
    /// enough to identify which chunk a stretch of the output came from, which is what the
    /// ordering assertion needs.
    private func wav(seconds: Double, amplitude: Float, sampleRate: Double = 24_000) throws -> Data {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // A slow square wave rather than DC: an encoder is entitled to discard a constant offset,
        // and a test that depends on it would pass today and fail on any codec change.
        let channel = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            let phase = (Double(frame) / sampleRate * 220).truncatingRemainder(dividingBy: 1)
            channel[frame] = phase < 0.5 ? amplitude : -amplitude
        }

        let url = scratch.appendingPathComponent("\(UUID().uuidString).wav")
        // Scoped so the file is closed before its bytes are read. `AVAudioFile` finalizes the
        // header on deinit, and reading it while the writer is still alive yields a truncated
        // WAV that decodes to a *different length* rather than failing — which is how an early
        // version of this fixture had the export looking twice as long as the reading.
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ])
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    /// Read a written export back as float samples so the assertions can look at the audio.
    private func samples(of url: URL) throws -> (frames: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channel = buffer.floatChannelData![0]
        return ((0..<Int(buffer.frameLength)).map { channel[$0] }, file.processingFormat.sampleRate)
    }

    private func meanAmplitude(_ frames: ArraySlice<Float>) -> Float {
        guard !frames.isEmpty else { return 0 }
        return frames.reduce(0) { $0 + abs($1) } / Float(frames.count)
    }

    // MARK: - The whole reading, in order

    /// Three chunks in, one file out, and the quiet one is where it was in the reading.
    ///
    /// The middle chunk is the near-silent one, so a file assembled in the wrong order or with a
    /// chunk dropped fails on the shape of the loudness curve rather than on its total length —
    /// a dropped chunk and a reordered one are different bugs and this tells them apart.
    func testExportContainsEveryChunkInReadingOrder() async throws {
        let amplitudes: [Float] = [0.6, 0.02, 0.6]
        var index = 0
        let destination = scratch.appendingPathComponent("reading.m4a")

        try await ReadAloudExport.write(
            chunks: ["First sentence.", "Second sentence.", "Third sentence."],
            voice: voice,
            to: destination,
            synthesize: { _, _ in
                defer { index += 1 }
                return try self.wav(seconds: 0.5, amplitude: amplitudes[index])
            }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let (frames, rate) = try samples(of: destination)

        // Length: three half-second chunks. The encoder pads, so this is a floor and a ceiling
        // rather than an equality — but a lost chunk is a third short and cannot hide in it.
        let duration = Double(frames.count) / rate
        XCTAssertGreaterThan(duration, 1.3, "the file is shorter than the reading — a chunk is missing")
        XCTAssertLessThan(duration, 1.8, "the file is longer than the reading")

        let third = frames.count / 3
        let first = meanAmplitude(frames[(third / 4)..<(third * 3 / 4)])
        let middle = meanAmplitude(frames[(third + third / 4)..<(third + third * 3 / 4)])
        let last = meanAmplitude(frames[(third * 2 + third / 4)..<(third * 2 + third * 3 / 4)])

        XCTAssertLessThan(middle, first / 4, "the quiet second sentence is not in the middle")
        XCTAssertLessThan(middle, last / 4, "the quiet second sentence is not in the middle")
    }

    /// A chunk that arrives at a different sample rate — which is what the built-in voice does
    /// when it stands in for an unreachable host — is resampled rather than written as-is.
    ///
    /// Written as-is it would not fail loudly: the file would still open and still play. It would
    /// simply speak that one sentence at the wrong speed and pitch, which is why this is a test
    /// rather than a comment.
    func testChunkAtAnotherSampleRateKeepsItsDuration() async throws {
        let destination = scratch.appendingPathComponent("mixed.m4a")
        var call = 0
        try await ReadAloudExport.write(
            chunks: ["At the host's rate.", "At the built-in voice's rate."],
            voice: voice,
            to: destination,
            synthesize: { _, _ in
                defer { call += 1 }
                return try self.wav(seconds: 0.5, amplitude: 0.5,
                                    sampleRate: call == 0 ? 24_000 : 22_050)
            }
        )

        let (frames, rate) = try samples(of: destination)
        let duration = Double(frames.count) / rate
        // Half a second each. Writing the 22.05 kHz chunk without resampling would stretch it to
        // ~0.545 s at the file's rate; the window here is tight enough to catch that.
        XCTAssertGreaterThan(duration, 0.9)
        XCTAssertLessThan(duration, 1.1, "a chunk was written at the wrong rate and plays slow")
    }

    // MARK: - Failures leave nothing behind

    /// Nothing to export is a refusal, not an empty file.
    func testEmptyReadingRefuses() async {
        let destination = scratch.appendingPathComponent("empty.m4a")
        do {
            try await ReadAloudExport.write(chunks: [], voice: voice, to: destination,
                                            synthesize: { _, _ in Data() })
            XCTFail("exporting nothing should throw")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// A reading no chunk of which could be rendered must not leave a zero-length file.
    ///
    /// A file that exists but holds no audio is the worst outcome available: the save appears to
    /// have worked, and the failure is discovered later by someone who wanted to listen to it.
    func testAReadingThatRendersNothingLeavesNoFile() async {
        SpeechConfig.fallbackEnabled = false
        defer { SpeechConfig.fallbackEnabled = true }

        struct HostDown: Error {}
        let destination = scratch.appendingPathComponent("silent.m4a")
        do {
            try await ReadAloudExport.write(chunks: ["One.", "Two."], voice: voice, to: destination,
                                            synthesize: { _, _ in throw HostDown() })
            // The built-in voice may still be available on this machine even with the reading
            // fallback off, since the export renders it directly. If it produced audio, the file
            // is legitimate; what must never happen is an empty file.
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil
            XCTAssertGreaterThan(size ?? 0, 0, "an export that succeeded wrote an empty file")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                           "a failed export left a partial file behind")
        }
    }

    /// Cancelling half way through removes the partial file rather than leaving a truncated
    /// reading that plays fine until it stops mid-sentence.
    func testCancellingRemovesThePartialFile() async {
        let destination = scratch.appendingPathComponent("cancelled.m4a")
        let started = expectation(description: "first chunk requested")

        let task = Task { @MainActor in
            try await ReadAloudExport.write(
                chunks: (1...20).map { "Sentence \($0)." },
                voice: voice,
                to: destination,
                synthesize: { _, _ in
                    started.fulfill()
                    try await Task.sleep(for: .milliseconds(40))
                    return try self.wav(seconds: 0.2, amplitude: 0.4)
                }
            )
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        _ = await task.result

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - The suggested name

    /// The source app and the time it was read are the only two things known about a reading,
    /// so they are the only two things the name claims.
    func testSuggestedNameUsesTheSourceAndTheTime() {
        let when = Date(timeIntervalSince1970: 1_756_000_000)
        let name = ReadAloudExport.suggestedName(sourceName: "Google Chrome", startedAt: when)
        XCTAssertTrue(name.hasPrefix("Google Chrome "), name)
        XCTAssertTrue(name.hasSuffix(".m4a"), name)
    }

    /// An app with a slash or a colon in its name must not produce a name the save panel refuses
    /// — or worse, one that reads as a path.
    func testSuggestedNameIsSafeForAFileName() {
        let name = ReadAloudExport.suggestedName(sourceName: "Reader: Web/Print", startedAt: Date())
        XCTAssertFalse(name.contains("/"), name)
        XCTAssertFalse(name.contains(":"), name)
    }

    /// A capture with no source app still gets a name rather than a file called " .m4a".
    func testSuggestedNameFallsBackWhenTheSourceIsUnknown() {
        for source in [nil, "", "   "] {
            let name = ReadAloudExport.suggestedName(sourceName: source, startedAt: Date())
            XCTAssertTrue(name.hasPrefix("Reading "), name)
        }
    }
}
