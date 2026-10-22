import Foundation

/// A playable 16-bit mono WAV of a 440 Hz tone, for tests that need a clip which takes real time
/// to play. The test host's speech graph is muted (`RunnerExitDiagnostic`), so nothing is heard.
enum SpeechTestClip {
    static func toneWAV(seconds: Double, sampleRate: Double = 22_050) -> Data {
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
}
