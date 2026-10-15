import AVFoundation
import Foundation

@MainActor
enum InterpreterVoiceStream {
    private struct NativePacket: Sendable {
        let samples: [Float]
        let sampleRate: Double
    }

    static func kokoro(text: String, language: String, baseURL: String, route: any InterpreterRoute) async throws {
        guard let base = URL(string: baseURL), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              ["en", "es"].contains(language)
        else {
            throw InterpreterRouteError.unavailable("Choose a valid voice service and an English or Spanish voice.")
        }
        let voice = language == "es" ? "ef_dora" : "af_heart"
        var request = URLRequest(url: base.appendingPathComponent("v1/audio/speech"), timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "kokoro", "input": text, "voice": voice, "response_format": "pcm", "stream": true,
        ])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200 ... 299).contains(response.statusCode) else {
            throw InterpreterRouteError.unavailable("The voice service failed. Check Baton's Speech settings before resuming.")
        }
        var chunk = Data()
        var count = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            count += 1
            guard count <= 960_000 else { throw InterpreterRouteError.invalidPCM }
            if chunk.count == 1920 {
                try await route.append(chunk); chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            try await route.append(chunk)
        }
    }

    static func native(text: String, language: String, route: any InterpreterRoute) async throws {
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            throw InterpreterRouteError.unavailable("Download a system voice for \(language) in macOS Accessibility settings.")
        }
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let pair = AsyncThrowingStream<NativePacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { pair.continuation.finish(); return }
            guard let channels = pcm.floatChannelData, pcm.format.channelCount > 0 else {
                pair.continuation.finish(throwing: InterpreterRouteError.invalidPCM)
                return
            }
            let count = Int(pcm.frameLength)
            var samples = [Float](repeating: 0, count: count)
            for index in 0 ..< count {
                for channel in 0 ..< Int(pcm.format.channelCount) {
                    samples[index] += channels[channel][index] / Float(pcm.format.channelCount)
                }
            }
            let packet = NativePacket(samples: samples, sampleRate: pcm.format.sampleRate)
            if case .dropped = pair.continuation.yield(packet) {
                pair.continuation.finish(throwing: InterpreterRouteError.unavailable("The system voice ran ahead of playback. Pause and resume interpretation."))
            }
        }
        defer { synthesizer.stopSpeaking(at: .immediate); pair.continuation.finish() }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else {
            throw InterpreterRouteError.invalidPCM
        }
        var converter: AVAudioConverter?
        var source: AVAudioFormat?
        for try await packet in pair.stream {
            try Task.checkCancellation()
            if source?.sampleRate != packet.sampleRate {
                source = AVAudioFormat(standardFormatWithSampleRate: packet.sampleRate, channels: 1)
                converter = source.flatMap { AVAudioConverter(from: $0, to: target) }
                converter?.primeMethod = .none
            }
            guard let source, let converter,
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(packet.samples.count)),
                  let channel = input.floatChannelData?[0] else { throw InterpreterRouteError.invalidPCM }
            input.frameLength = AVAudioFrameCount(packet.samples.count)
            packet.samples.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress {
                    channel.update(from: base, count: pointer.count)
                }
            }
            let capacity = AVAudioFrameCount(ceil(Double(packet.samples.count) * 24000 / packet.sampleRate) + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw InterpreterRouteError.invalidPCM }
            nonisolated(unsafe) var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow; return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let error {
                throw error
            }
            let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            if let pointer = buffers.first?.mData, let bytes = buffers.first?.mDataByteSize, bytes > 0 {
                let data = Data(bytes: pointer, count: Int(bytes))
                for offset in stride(from: 0, to: data.count, by: 1920) {
                    try await route.append(data.subdata(in: offset ..< min(offset + 1920, data.count)))
                }
            }
        }
        if let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) {
            while true {
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let error {
                    throw error
                }
                let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                if let pointer = buffers.first?.mData, let bytes = buffers.first?.mDataByteSize, bytes > 0 {
                    let data = Data(bytes: pointer, count: Int(bytes))
                    for offset in stride(from: 0, to: data.count, by: 1920) {
                        try await route.append(data.subdata(in: offset ..< min(offset + 1920, data.count)))
                    }
                }
                if status == .endOfStream || output.frameLength == 0 {
                    break
                }
            }
        }
    }
}
