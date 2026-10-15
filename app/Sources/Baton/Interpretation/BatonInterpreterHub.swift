import BatonMCPProtocol
import BatonPlaybackKit
import BatonSpeech
import BatonSubsonicKit
import Foundation
import Network

/// MCP negotiates devices and a short-lived ticket. Two authenticated TCP
/// connections carry length-prefixed JSON metadata/PCM and render receipts.
/// The token is never advertised in discovery or persisted to disk.
@MainActor
final class BatonInterpreterHub {
    private struct Lane {
        let device: InterpreterDevices.Device
        var route: any InterpreterRoute
        var connection: NWConnection?
        var generation: UInt64 = 0
        var sequence: UInt64?
        var seen: Set<String> = []
        var sourceSeen: Set<String> = []
        var operation: Task<[String: StringOrNumber], any Error>?
        var pcmCommit: [String: Any]?
        var pcmSequence: UInt64 = 0
    }

    /// Codable receipts avoid sending untyped dictionaries across task boundaries.
    private enum StringOrNumber: Encodable, Sendable {
        case string(String), number(Double), integer(UInt64)
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self { case let .string(value): try container.encode(value); case let .number(value): try container.encode(value); case let .integer(value): try container.encode(value) }
        }
    }

    private var lanes: [String: Lane] = [:]
    private var opening = false
    private var listener: NWListener?
    private var monitor: Task<Void, Never>?
    private var ticket = ""
    private var sessionID: String?
    private var expires = Date.distantPast
    private var activity = Date.distantPast
    private var pendingConnections = 0
    private var voiceEngine = "kokoro"
    private var ttsURL = ""
    private var focusHandle: String?
    private var focus: BatonAudioFocusRegistry?
    private weak var music: MusicModel?

    private let devices: @MainActor () -> [InterpreterDevices.Device]
    private let makeRoute: @MainActor (InterpreterDevices.Device) throws -> any InterpreterRoute

    init(devices: @escaping @MainActor () -> [InterpreterDevices.Device] = { InterpreterDevices.all() },
         makeRoute: @escaping @MainActor (InterpreterDevices.Device) throws -> any InterpreterRoute = { try InterpreterAudioRoute(device: $0) })
    {
        self.devices = devices
        self.makeRoute = makeRoute
    }

    var isActive: Bool {
        sessionID != nil
    }

    func open(_ args: [String: Any], music: MusicModel, focus: BatonAudioFocusRegistry) async throws -> String {
        guard sessionID == nil, !opening else { throw BatonMCPToolError(message: "A meeting interpreter is already open. Close it before starting another.") }
        opening = true
        defer { opening = false }
        guard let incomingUID = args["incoming_device_uid"] as? String,
              let outgoingUID = args["outgoing_device_uid"] as? String,
              let incoming = devices().first(where: { $0.uid == incomingUID && $0.output }),
              let outgoing = devices().first(where: { $0.uid == outgoingUID && $0.output && $0.input && $0.virtual }),
              incoming.uid != outgoing.uid
        else {
            throw BatonMCPToolError(message: "Select headphones and a separate duplex virtual microphone. The outgoing route cannot use speakers.")
        }
        let engine = args["voice_engine"] as? String ?? "kokoro"
        guard ["kokoro", "native"].contains(engine) else { throw BatonMCPToolError(message: "Choose Kokoro or the system voice.") }
        let first = try makeRoute(incoming)
        let second: any InterpreterRoute
        do { second = try makeRoute(outgoing) } catch { first.stop(); throw error }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = false
        let candidate: NWListener
        do { candidate = try NWListener(using: parameters, on: .any) } catch { first.stop(); second.stop(); throw error }
        candidate.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(3)); candidate.cancel() } catch {}
        }
        defer { deadline.cancel() }
        let ready = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var settled = false
            candidate.stateUpdateHandler = { state in
                switch state {
                case .ready: if !settled {
                        settled = true; continuation.resume(returning: true)
                    }
                case .failed, .cancelled: if !settled {
                        settled = true; continuation.resume(returning: false)
                    }
                default: break
                }
            }
            candidate.start(queue: .main)
        }
        guard ready, let port = candidate.port else {
            first.stop(); second.stop(); candidate.cancel()
            throw BatonMCPToolError(message: "Baton could not open its local interpretation stream.")
        }
        listener = candidate
        sessionID = UUID().uuidString
        ticket = BatonMCPAuth.generateToken()
        expires = Date().addingTimeInterval(60)
        activity = Date()
        self.music = music
        self.focus = focus
        voiceEngine = engine
        ttsURL = args["tts_url"] as? String ?? SpeechConfig.baseURL(for: .kokoro)
        lanes = ["incoming": Lane(device: incoming, route: first), "outgoing": Lane(device: outgoing, route: second)]
        first.onFailure = { [weak self] in self?.cancelLane("incoming") }
        second.onFailure = { [weak self] in self?.cancelLane("outgoing") }
        music.speech.stop()
        music.speech.interpretationActive = true
        focusHandle = focus.suspend(owner: "tonebox.interpretation", connectionID: "interpreter", on: music.music)["handle"] as? String
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                if Date().timeIntervalSince(activity) > 30 {
                    close(); return
                }
                if let handle = focusHandle, let focus = self.focus {
                    _ = focus.renew(handle: handle)
                }
            }
        }
        return try json(["protocol_version": 1, "session_id": sessionID ?? "", "token": ticket,
                         "host": "127.0.0.1", "port": Int(port.rawValue), "pcm_sample_rate": 24000, "pcm_channels": 1,
                         "pcm_encoding": "s16le", "incoming_generation": 0, "outgoing_generation": 0])
    }

    func status() throws -> String {
        try json(["active": isActive, "session_id": sessionID ?? "", "lanes": lanes.mapValues { ["generation": $0.generation, "connected": $0.connection != nil] as [String: Any] }])
    }

    func close(_ args: [String: Any]) throws -> String {
        guard args["session_id"] as? String == sessionID, sessionID != nil else { throw BatonMCPToolError(message: "The interpretation session has changed.") }
        close()
        return "{\"closed\":true}"
    }

    func close() {
        sessionID = nil
        ticket = ""
        monitor?.cancel(); monitor = nil
        for lane in Array(lanes.keys) {
            cancelLane(lane)
        }
        lanes.removeAll()
        listener?.cancel(); listener = nil
        if let focusHandle, let focus, let music {
            _ = focus.resume(handle: focusHandle, on: music.music)
        }
        focusHandle = nil
        music?.speech.interpretationActive = false
    }

    func cancel(_ args: [String: Any]) throws -> String {
        guard args["session_id"] as? String == sessionID, let lane = args["lane"] as? String,
              let current = lanes[lane], let generation = unsigned(args["generation"]), generation <= current.generation
        else {
            throw BatonMCPToolError(message: "This interpretation generation is no longer active.")
        }
        if generation == current.generation {
            cancelLane(lane)
        }
        return try json(["cancelled": true, "generation": lanes[lane]?.generation ?? 0])
    }

    private func cancelLane(_ name: String) {
        guard var lane = lanes[name] else { return }
        guard lane.generation < UInt64.max else { lane.route.stop(); lane.connection?.cancel(); lanes[name] = nil; return }
        lane.generation += 1
        lane.operation?.cancel()
        lane.route.stop()
        let connection = lane.connection
        lane.connection = nil
        lane.operation = nil
        lane.pcmCommit = nil
        lanes[name] = lane
        connection?.cancel()
    }

    func configure(_ args: [String: Any]) throws -> String {
        guard args["session_id"] as? String == sessionID, let name = args["lane"] as? String, let old = lanes[name], old.generation < UInt64.max,
              let uid = args["device_uid"] as? String, let device = devices().first(where: { $0.uid == uid && $0.output }),
              name != "outgoing" || (device.virtual && device.input),
              lanes[name == "incoming" ? "outgoing" : "incoming"]?.device.uid != uid
        else {
            throw BatonMCPToolError(message: "Select an available, separate audio route.")
        }
        let route = try makeRoute(device)
        cancelLane(name)
        var replacement = Lane(device: device, route: route)
        replacement.generation = old.generation + 1
        replacement.seen = old.seen
        replacement.sourceSeen = old.sourceSeen
        lanes[name] = replacement
        route.onFailure = { [weak self] in self?.cancelLane(name) }
        ticket = BatonMCPAuth.generateToken()
        expires = Date().addingTimeInterval(60)
        activity = Date()
        return try json(["session_id": sessionID ?? "", "generation": replacement.generation, "token": ticket])
    }

    private func accept(_ connection: NWConnection) {
        guard pendingConnections < 4, isActive else { connection.cancel(); return }
        pendingConnections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    guard let self, let name = self.lanes.first(where: { $0.value.connection === connection })?.key else { return }
                    self.cancelLane(name)
                    if self.lanes.values.allSatisfy({ $0.connection == nil }) {
                        self.close()
                    }
                }
            default: break
            }
        }
        connection.start(queue: .main)
        Task { [weak self] in
            guard let self else { connection.cancel(); return }
            defer { self.pendingConnections -= 1; connection.cancel() }
            var ownedLane: String?
            let authTimer = Task { do { try await Task.sleep(for: .seconds(3)); connection.cancel() } catch {} }
            defer { authTimer.cancel() }
            do {
                let authentication = try await object(InterpreterFrames.receive(connection))
                guard authentication["type"] as? String == "authenticate", Date() < expires,
                      authentication["session_id"] as? String == sessionID,
                      let supplied = authentication["token"] as? String,
                      BatonMCPAuth.constantTimeEquals(supplied, self.ticket),
                      let name = authentication["lane"] as? String, var lane = lanes[name], lane.connection == nil
                else {
                    throw BatonMCPToolError(message: "Interpretation authentication failed.")
                }
                authTimer.cancel()
                ownedLane = name
                lane.connection = connection
                lanes[name] = lane
                activity = Date()
                try await InterpreterFrames.send(connection, data: JSONSerialization.data(withJSONObject: ["type": "authenticated"]))
                while isActive {
                    let packet = try await object(InterpreterFrames.receive(connection))
                    activity = Date()
                    guard lanes[name]?.connection === connection else { throw InterpreterRouteError.cancelled }
                    let reply = try await handle(packet, lane: name)
                    try await InterpreterFrames.send(connection, data: reply)
                }
            } catch {
                if let data = try? JSONSerialization.data(withJSONObject: ["type": "error", "message": error.localizedDescription]) {
                    try? await InterpreterFrames.send(connection, data: data)
                }
            }
            if let name = ownedLane, lanes[name]?.connection === connection {
                cancelLane(name)
                if lanes.values.allSatisfy({ $0.connection == nil }) {
                    close()
                }
            }
        }
    }

    private func handle(_ packet: [String: Any], lane name: String) async throws -> Data {
        guard var lane = lanes[name], let sessionID else { throw InterpreterRouteError.cancelled }
        let type = packet["type"] as? String ?? ""
        if type == "heartbeat" {
            return try JSONSerialization.data(withJSONObject: ["type": "pong"])
        }
        guard packet["session_id"] as? String == sessionID, packet["lane"] as? String == name,
              let generation = unsigned(packet["generation"]), generation == lane.generation,
              let commitID = packet["commit_id"] as? String, UUID(uuidString: commitID) != nil
        else {
            throw BatonMCPToolError(message: "Stale or invalid interpretation audio frame.")
        }
        if type == "speech" || type == "begin_pcm" {
            guard let sequence = unsigned(packet["sequence"]), lane.sequence.map({ sequence > $0 }) ?? true,
                  !lane.seen.contains(commitID), lane.seen.count < 8192, lane.operation == nil, lane.pcmCommit == nil
            else {
                throw BatonMCPToolError(message: "Duplicate or out-of-order interpretation commit.")
            }
            guard let spanID = packet["source_span_id"] as? String, UUID(uuidString: spanID) != nil,
                  let revision = packet["source_revision"] as? String, revision.count == 64, revision.allSatisfy(\.isHexDigit),
                  let language = packet["target_language"] as? String, ["en", "es"].contains(language) else { throw InterpreterRouteError.invalidPCM }
            let sourceKey = spanID + ":" + revision + ":" + language
            guard !lane.sourceSeen.contains(sourceKey) else { throw BatonMCPToolError(message: "This source phrase has already been delivered.") }
            lane.seen.insert(commitID); lane.sourceSeen.insert(sourceKey); lane.sequence = sequence
            try lane.route.begin()
            if type == "begin_pcm" {
                lane.pcmCommit = packet
                lane.pcmSequence = 0
                lanes[name] = lane
                return try JSONSerialization.data(withJSONObject: ["type": "accepted", "commit_id": commitID])
            }
            guard let text = packet["text"] as? String, !text.isEmpty, text.utf8.count <= 8192 else { throw InterpreterRouteError.invalidPCM }
            let route = lane.route
            let engine = voiceEngine
            let ttsURL = ttsURL
            let operation = Task { () throws -> [String: StringOrNumber] in
                if engine == "native" {
                    try await InterpreterVoiceStream.native(text: text, language: language, route: route)
                } else {
                    try await InterpreterVoiceStream.kokoro(text: text, language: language, baseURL: ttsURL, route: route)
                }
                let rendered = try await route.end()
                return ["type": .string("rendered"), "session_id": .string(sessionID), "lane": .string(name),
                        "generation": .integer(generation), "sequence": .integer(sequence), "commit_id": .string(commitID),
                        "first_render_ms": .number(rendered.0), "total_ms": .number(rendered.1)]
            }
            lane.operation = operation
            lanes[name] = lane
            let result = try await operation.value
            guard lanes[name]?.generation == generation else { throw InterpreterRouteError.cancelled }
            lanes[name]?.operation = nil
            return try JSONEncoder().encode(result)
        }
        guard let active = lane.pcmCommit, active["commit_id"] as? String == commitID else { throw InterpreterRouteError.invalidPCM }
        if type == "pcm" {
            guard unsigned(packet["chunk_sequence"]) == lane.pcmSequence,
                  let base64 = packet["audio"] as? String, let data = Data(base64Encoded: base64) else { throw InterpreterRouteError.invalidPCM }
            try await lane.route.append(data)
            guard lanes[name]?.generation == generation else { throw InterpreterRouteError.cancelled }
            lanes[name]?.pcmSequence += 1
            return try JSONSerialization.data(withJSONObject: ["type": "accepted", "commit_id": commitID])
        }
        guard type == "end_pcm", let sequence = unsigned(active["sequence"]) else { throw InterpreterRouteError.invalidPCM }
        let rendered = try await lane.route.end()
        guard lanes[name]?.generation == generation else { throw InterpreterRouteError.cancelled }
        lanes[name]?.pcmCommit = nil
        return try JSONSerialization.data(withJSONObject: ["type": "rendered", "session_id": sessionID, "lane": name,
                                                           "generation": generation, "sequence": sequence, "commit_id": commitID,
                                                           "first_render_ms": rendered.0, "total_ms": rendered.1])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InterpreterRouteError.invalidPCM }
        return value
    }

    private func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else { throw InterpreterRouteError.invalidPCM }
        return string
    }

    private func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else { return nil }
        return UInt64(number.stringValue)
    }
}

enum InterpreterFrames {
    static func receive(_ connection: NWConnection) async throws -> Data {
        let header = try await exact(connection, count: 4)
        let length = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard length > 0, length <= 65536 else { throw InterpreterRouteError.invalidPCM }
        return try await exact(connection, count: Int(length))
    }

    static func send(_ connection: NWConnection, data: Data) async throws {
        guard !data.isEmpty, data.count <= 65536 else { throw InterpreterRouteError.invalidPCM }
        let length = UInt32(data.count)
        var frame = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        frame.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func exact(_ connection: NWConnection, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let remaining = count - data.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if complete {
                        continuation.resume(throwing: InterpreterRouteError.cancelled)
                    } else {
                        continuation.resume(throwing: InterpreterRouteError.invalidPCM)
                    }
                }
            }
            data.append(chunk)
        }
        return data
    }
}
