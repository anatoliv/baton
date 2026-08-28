import Foundation
import Network
import Observation
import OSLog

private let pairingLog = Logger(subsystem: "io.tonebox.baton", category: "DevicePairing")

/// The Mac's side of pairing: a listener that lives exactly as long as one link attempt.
///
/// Bound to the LAN rather than loopback (unlike the MCP server, which is deliberately
/// unreachable off-device) because the whole point is for a phone to reach it. That makes
/// the lifetime the security boundary: one connection, one payload, then closed — and the
/// invitation expires on its own even if nobody scans it.
@MainActor
@Observable
public final class PairingHost {
    public enum State: Equatable {
        case idle
        /// Showing a code and waiting for a scan.
        case advertising(DevicePairing.Invitation)
        /// A device proved it saw the code and is waiting on the owner's approval.
        case awaitingApproval(deviceName: String)
        case linked(deviceName: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Called when a device passes the proof check, so the app can ask its owner. Returning
    /// false refuses the link.
    public var approve: ((String) async -> Bool)?
    /// Supplies the payload once approved. Takes the whole invitation rather than a
    /// passphrase so the call site can't derive the wrong one — `DevicePairing.makePayload`
    /// is the intended implementation, and it always encrypts.
    public var makePayload: ((DevicePairing.Invitation) throws -> Data)?

    private var listener: NWListener?
    private var expiry: Task<Void, Never>?

    public init() {}

    /// Reports a failure the host itself can't detect — the app knowing it has no usable
    /// LAN address, say. Kept as a method so `state` stays `private(set)`: everything that
    /// moves the machine forward lives in here, where the transitions can be reasoned about.
    public func fail(_ message: String) {
        stop()
        state = .failed(message)
    }

    /// Starts advertising. `host` is the LAN address to put in the code — supplied by the
    /// caller because picking "the right" interface is a judgement the app makes.
    public func start(host: String) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in await self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self] newState in
            guard case let .failed(error) = newState else { return }
            Task { @MainActor in
                self?.state = .failed(error.localizedDescription)
                pairingLog.error("pairing listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: .main)
        self.listener = listener

        // The port is assigned on start; wait for it before making the invitation.
        Task { @MainActor [weak self] in
            for _ in 0 ..< 50 {
                if let port = listener.port?.rawValue, port != 0 {
                    self?.state = .advertising(.make(host: host, port: port))
                    self?.armExpiry()
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            self?.state = .failed("Couldn't open a port for pairing.")
        }
    }

    public func stop() {
        expiry?.cancel()
        expiry = nil
        listener?.cancel()
        listener = nil
        if case .linked = state {} else { state = .idle }
    }

    /// A pairing attempt stops being valid on its own.
    ///
    /// Covers `.awaitingApproval` as well as `.advertising`, and that is the important
    /// half: a device has by then *proved possession of the code* and is holding an open
    /// socket. Guarding only the advertising state meant an unanswered prompt kept the
    /// listener alive indefinitely — the one window where the timeout is doing real work.
    private func armExpiry() {
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DevicePairing.timeToLive))
            guard let self, let expired = Self.expiryOutcome(for: state) else { return }
            stop()
            state = expired
        }
    }

    /// What a timeout should do from a given state, or nil to leave it alone.
    ///
    /// Split out as a pure function so the rule can be tested without a socket and a
    /// ninety-second wait. The rule itself is the fix: `.awaitingApproval` must expire too,
    /// because by then a device has proved it saw the code and is holding an open
    /// connection — an unanswered prompt used to keep that alive indefinitely.
    nonisolated static func expiryOutcome(for state: State) -> State? {
        switch state {
        case .advertising:
            .failed("The code expired. Show a new one.")
        case .awaitingApproval:
            .failed("Nobody approved the link in time. Show a new code.")
        case .idle, .linked, .failed:
            nil   // nothing in flight to end
        }
    }

    private func handle(_ connection: NWConnection) async {
        guard case let .advertising(invitation) = state else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)

        guard let request = await receive(connection),
              let hello = try? JSONDecoder().decode(DevicePairing.Hello.self, from: request),
              DevicePairing.isValid(hello, for: invitation)
        else {
            // Says nothing about *why*: a prober learns only that it failed.
            pairingLog.error("pairing rejected: bad or absent proof")
            connection.cancel()
            return
        }

        state = .awaitingApproval(deviceName: hello.deviceName)
        let approved = await approve?(hello.deviceName) ?? false
        // The expiry may have fired while the prompt was on screen; if it did, this
        // attempt is over regardless of what was clicked afterwards.
        guard case .awaitingApproval = state else {
            connection.cancel()
            return
        }
        guard approved else {
            connection.cancel()
            stop()
            state = .idle
            return
        }

        do {
            let payload = try makePayload?(invitation) ?? Data()
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
            state = .linked(deviceName: hello.deviceName)
        } catch {
            state = .failed(error.localizedDescription)
            connection.cancel()
        }
        // One connection, one payload. The listener closes either way.
        expiry?.cancel()
        listener?.cancel()
        listener = nil
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                if !resumed { resumed = true; continuation.resume(returning: data) }
            }
        }
    }
}

/// The phone's side: connect, prove, receive.
public enum PairingClient {
    public enum Failure: LocalizedError {
        case unreachable
        case refused
        case empty

        public var errorDescription: String? {
            switch self {
            case .unreachable: "Couldn't reach your Mac. Both devices need to be on the same network."
            case .refused: "Your Mac didn't accept this code. It may have expired — show a new one."
            case .empty: "Your Mac didn't send anything back."
            }
        }
    }

    /// Redeems an invitation, returning the encrypted settings payload.
    public static func redeem(_ invitation: DevicePairing.Invitation, deviceName: String) async throws -> Data {
        let connection = NWConnection(
            host: NWEndpoint.Host(invitation.host),
            port: NWEndpoint.Port(rawValue: invitation.port) ?? .any,
            using: .tcp
        )
        connection.start(queue: .global(qos: .userInitiated))
        defer { connection.cancel() }

        let hello = DevicePairing.hello(for: invitation, deviceName: deviceName)
        guard let request = try? JSONEncoder().encode(hello) else { throw Failure.refused }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            connection.send(content: request, completion: .contentProcessed { error in
                guard !resumed else { return }
                resumed = true
                if error != nil { continuation.resume(throwing: Failure.unreachable) }
                else { continuation.resume() }
            })
        }

        let payload = await receiveAll(connection)
        guard let payload, !payload.isEmpty else { throw Failure.empty }
        return payload
    }

    /// Read until the sender closes, accumulating every segment.
    ///
    /// This used to be a single `receive(minimumIncompleteLength: 1, …)`, which resumes as soon
    /// as **one byte** has arrived — so it returned whatever happened to be in the first TCP
    /// segment and discarded the rest. The host sends the whole payload and then closes
    /// (`send(… completion: .contentProcessed { connection.cancel() })`), so anything larger
    /// than a segment arrived truncated, failed to parse as JSON, and surfaced as "This file
    /// isn't a Baton settings backup" — an error about the payload's *shape*, for what was
    /// really a short read.
    ///
    /// It is size-dependent, which is why it can look intermittent: a small settings export
    /// fits in one segment and pairs fine, and the same code fails once the export grows.
    /// `timeout` is not optional politeness. Reading until close means a peer that connects and
    /// then says nothing would otherwise hang pairing forever — the previous single-read version
    /// could not hang that way, so adding the loop without a deadline would trade a truncated
    /// payload for a stuck screen, which is worse.
    static func receiveAll(_ connection: NWConnection,
                           cap: Int = 4 * 1024 * 1024,
                           timeout: TimeInterval = 20) async -> Data? {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) var accumulated = Data()
            nonisolated(unsafe) var resumed = false

            @Sendable func finish(_ value: Data?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }

            let deadline = DispatchQueue.global()
            deadline.asyncAfter(deadline: .now() + timeout) {
                // Whatever arrived is better than nothing: if it is complete it parses, and if
                // it is not, the format check reports that honestly rather than hanging.
                finish(accumulated.isEmpty ? nil : accumulated)
                connection.cancel()
            }

            @Sendable func readMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty { accumulated.append(data) }
                    if error != nil || isComplete {
                        finish(accumulated.isEmpty ? nil : accumulated)
                    } else if accumulated.count >= cap {
                        // A pairing payload is settings, not media. Something is wrong.
                        finish(accumulated)
                    } else {
                        readMore()
                    }
                }
            }
            readMore()
        }
    }
}
