import Foundation

/// Lets the gateway reach a user's *player*. Curation runs at the server, but
/// "play it" has to happen where the speakers are — so a device (the phone, the
/// Mac) holds an authenticated long-poll open, receives commands, and posts the
/// results back.
///
/// Long-polling rather than a WebSocket on purpose: it reuses the HTTP parser
/// already in BatonMCPProtocol, survives every proxy, and needs no RFC-6455
/// framing/masking code of our own — bespoke frame parsing is bug surface with
/// nothing to show for it at one command per few seconds.
actor DeviceLink {
    struct Command: Sendable {
        let id: String
        let name: String
        /// The tool arguments as serialized JSON. `[String: Any]` is not Sendable
        /// and this crosses an actor boundary, so the bytes travel instead of the
        /// dictionary — they were about to become bytes on the wire anyway.
        let argumentsJSON: Data

        var json: [String: Any] {
            let arguments = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any] ?? [:]
            return ["id": id, "name": name, "arguments": arguments]
        }
    }

    /// Commands waiting for a device to pick up.
    private var queue: [Command] = []
    /// A device parked in `poll` waiting for work.
    private var waitingDevice: CheckedContinuation<Command?, Never>?
    /// Tool calls waiting for the device's answer, keyed by command id.
    private var pendingResults: [String: CheckedContinuation<(text: String, isError: Bool), Never>] = [:]
    /// When the device last polled — "connected" means recently enough to trust.
    private var lastPollAt: Date?

    /// True when a device has polled recently enough to route playback to it.
    var isDeviceConnected: Bool {
        guard let lastPollAt else { return false }
        return Date().timeIntervalSince(lastPollAt) < 90
    }

    // MARK: - Device side

    /// Called by `GET /v1/device/poll`. Returns the next command, or nil when the
    /// hold expires (the device immediately polls again).
    func awaitCommand(timeout: TimeInterval = 25) async -> Command? {
        lastPollAt = Date()
        if !queue.isEmpty { return queue.removeFirst() }

        let command = await withCheckedContinuation { (continuation: CheckedContinuation<Command?, Never>) in
            waitingDevice = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                await self.expirePoll()
            }
        }
        return command
    }

    private func expirePoll() {
        guard let waiting = waitingDevice else { return }
        waitingDevice = nil
        waiting.resume(returning: nil)
    }

    /// Called by `POST /v1/device/result` — hands the answer to the waiting tool.
    func deliverResult(id: String, text: String, isError: Bool) {
        lastPollAt = Date()
        guard let continuation = pendingResults.removeValue(forKey: id) else { return }
        continuation.resume(returning: (text, isError))
    }

    // MARK: - Tool side

    /// Sends a command to the connected device and waits for its answer. Returns
    /// nil when no device is listening, so the caller can answer honestly instead
    /// of pretending something played.
    func dispatch(name: String, argumentsJSON: Data, timeout: TimeInterval = 20) async -> (text: String, isError: Bool)? {
        guard isDeviceConnected else { return nil }
        let command = Command(id: UUID().uuidString, name: name, argumentsJSON: argumentsJSON)

        if let waiting = waitingDevice {
            waitingDevice = nil
            waiting.resume(returning: command)
        } else {
            queue.append(command)
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(text: String, isError: Bool), Never>) in
            pendingResults[command.id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                await self.expireResult(id: command.id)
            }
        }
        return result
    }

    private func expireResult(id: String) {
        guard let continuation = pendingResults.removeValue(forKey: id) else { return }
        continuation.resume(returning: ("The device didn't answer in time.", true))
    }
}
