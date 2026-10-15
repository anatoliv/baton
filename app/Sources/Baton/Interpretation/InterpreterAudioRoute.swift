import AVFoundation
import CoreAudio
import Foundation

enum InterpreterRouteError: Error, LocalizedError {
    case unavailable(String)
    case invalidPCM
    case emptyAudio
    case cancelled
    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        case .invalidPCM: "The voice service returned invalid PCM audio."
        case .emptyAudio: "The voice service returned no audio."
        case .cancelled: "Interpretation audio was stopped."
        }
    }
}

enum InterpreterDevices {
    struct Device: Codable, Sendable {
        let uid: String
        let name: String
        let id: UInt32
        let input: Bool
        let output: Bool
        let virtual: Bool
    }

    static func all() -> [Device] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = property(kAudioDevicePropertyTransportType)
            _ = AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            return Device(uid: uid, name: name, id: id,
                          input: hasChannels(id, scope: kAudioDevicePropertyScopeInput),
                          output: hasChannels(id, scope: kAudioDevicePropertyScopeOutput),
                          virtual: transport == kAudioDeviceTransportTypeVirtual)
        }
    }

    private static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard result == noErr else { return nil }
        return value as String?
    }

    private static func hasChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }
}

/// A persistent, pinned graph for exactly one interpreter lane. At most one
/// second of PCM is scheduled ahead; producer backpressure is based on render
/// callbacks. Device loss stops this graph rather than following system output.
@MainActor
final class InterpreterAudioRoute: InterpreterRoute {
    let deviceUID: String
    private let deviceID: AudioDeviceID
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var epoch = UUID()
    private var queuedFrames: Int = 0
    private var receivedFrames = 0
    private var space: CheckedContinuation<Void, any Error>?
    private var finish: CheckedContinuation<(Double, Double), any Error>?
    private let clock = ContinuousClock()
    private var started: ContinuousClock.Instant?
    private var firstRenderMS: Double?
    private var configurationObserver: NSObjectProtocol?
    var onFailure: (@MainActor () -> Void)?

    init(device: InterpreterDevices.Device) throws {
        deviceUID = device.uid
        deviceID = device.id
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1), device.output else {
            throw InterpreterRouteError.unavailable("Select an available output device.")
        }
        self.format = format
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.outputNode.auAudioUnit.setDeviceID(device.id)
        engine.mainMixerNode.outputVolume = SpeechAudioPlayer.isMuted ? 0 : 1
        engine.prepare()
        try engine.start()
        node.play()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stop()
                self.onFailure?()
            }
        }
    }

    func begin() throws {
        guard engine.isRunning, InterpreterDevices.all().contains(where: { $0.uid == deviceUID && $0.id == deviceID }),
              engine.outputNode.auAudioUnit.deviceID == deviceID
        else {
            stop()
            throw InterpreterRouteError.unavailable("The selected audio device disconnected. Select it again to resume interpretation.")
        }
        guard started == nil else { throw InterpreterRouteError.unavailable("This interpretation lane is already playing.") }
        started = clock.now
        firstRenderMS = nil
        receivedFrames = 0
    }

    func append(_ pcm: Data) async throws {
        guard started != nil, engine.isRunning, !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= 4800 else {
            throw InterpreterRouteError.invalidPCM
        }
        let current = epoch
        if queuedFrames >= 24000 {
            try await withCheckedThrowingContinuation { space = $0 }
        }
        try Task.checkCancellation()
        guard epoch == current, engine.isRunning else { throw InterpreterRouteError.cancelled }
        let frames = pcm.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let samples = buffer.floatChannelData?[0] else {
            throw InterpreterRouteError.invalidPCM
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let bytes = [UInt8](pcm)
        for index in 0 ..< frames {
            let raw = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
            samples[index] = Float(Int16(bitPattern: raw)) / 32768
        }
        queuedFrames += frames
        receivedFrames += frames
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played(frames: frames, epoch: current) }
        }
    }

    func end() async throws -> (Double, Double) {
        guard receivedFrames > 0 else { throw InterpreterRouteError.emptyAudio }
        if queuedFrames == 0 {
            return completed()
        }
        return try await withCheckedThrowingContinuation { finish = $0 }
    }

    func stop() {
        epoch = UUID()
        node.stop()
        engine.stop()
        queuedFrames = 0
        started = nil
        space?.resume(throwing: InterpreterRouteError.cancelled)
        space = nil
        finish?.resume(throwing: InterpreterRouteError.cancelled)
        finish = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    private func played(frames: Int, epoch current: UUID) {
        guard epoch == current, let started else { return }
        if firstRenderMS == nil {
            firstRenderMS = max(0, ms(started.duration(to: clock.now)) - Double(frames) / 24)
        }
        queuedFrames = max(0, queuedFrames - frames)
        space?.resume()
        space = nil
        if queuedFrames == 0, let finish {
            self.finish = nil
            finish.resume(returning: completed())
        }
    }

    private func completed() -> (Double, Double) {
        let total = started.map { ms($0.duration(to: clock.now)) } ?? 0
        started = nil
        return (firstRenderMS ?? total, total)
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
