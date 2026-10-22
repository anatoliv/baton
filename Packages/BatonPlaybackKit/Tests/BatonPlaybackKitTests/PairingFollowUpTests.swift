import Network
import XCTest
@testable import BatonPlaybackKit

/// Pairing transport follow-ups, over loopback.
@MainActor
final class PairingFollowUpTests: XCTestCase {
    /// Redeem queued its Hello on a connection that never came up, and that send never
    /// completed: with nothing listening, pairing waited for good (C-15).
    func testRedeemingAgainstNothingListeningFailsPromptly() async throws {
        // A port nothing listens on: bind one, note it, and close it again.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        for _ in 0 ..< 100 where listener.port == nil || listener.port?.rawValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try XCTUnwrap(listener.port?.rawValue)
        listener.cancel()
        try await Task.sleep(for: .milliseconds(200))

        let invitation = DevicePairing.Invitation.make(host: "127.0.0.1", port: port)
        let saved = PairingClient.connectTimeout
        PairingClient.connectTimeout = 3
        defer { PairingClient.connectTimeout = saved }
        let started = Date()
        let box = Outcome()
        let redeem = Task { @MainActor in
            do { _ = try await PairingClient.redeem(invitation, deviceName: "Probe"); box.finish(nil) }
            catch { box.finish(error) }
        }
        defer { redeem.cancel() }
        while !box.finished, Date().timeIntervalSince(started) < 8 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(box.finished, "redeem was still waiting on a closed port after 8 s")
        XCTAssertEqual(box.error as? PairingClient.Failure, .unreachable)
    }

    /// On an iPhone the first connection to a LAN host sits in `.waiting` while the Local
    /// Network prompt is up, and a brief loss of route looks the same. Treating `.waiting` as
    /// unreachable failed first pairing before anyone could answer the prompt; redeem waits for
    /// the deadline instead.
    func testAConnectionThatIsWaitingIsGivenUntilTheDeadline() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        for _ in 0 ..< 100 where listener.port == nil || listener.port?.rawValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try XCTUnwrap(listener.port?.rawValue)
        listener.cancel()
        try await Task.sleep(for: .milliseconds(200))

        let saved = PairingClient.connectTimeout
        PairingClient.connectTimeout = 2
        defer { PairingClient.connectTimeout = saved }
        let started = Date()
        let box = Outcome()
        let redeem = Task { @MainActor in
            do { _ = try await PairingClient.redeem(.make(host: "127.0.0.1", port: port), deviceName: "Probe"); box.finish(nil) }
            catch { box.finish(error) }
        }
        defer { redeem.cancel() }
        while !box.finished, Date().timeIntervalSince(started) < 8 { try await Task.sleep(for: .milliseconds(25)) }
        let waited = Date().timeIntervalSince(started)
        XCTAssertTrue(box.finished)
        XCTAssertGreaterThanOrEqual(waited, 1.8, "a waiting connection was given up after \(waited) s, before the deadline")
        XCTAssertEqual(box.error as? PairingClient.Failure, .unreachable)
    }

    /// The host read the Hello with one receive, so a Hello split across two segments was
    /// refused as a bad proof (C-16).
    func testAHelloSplitAcrossTwoSegmentsIsAccepted() async throws {
        let host = PairingHost()
        defer { host.stop() }
        host.approve = { _ in true }
        host.makePayload = { _ in Data("ok".utf8) }
        try host.start(host: "127.0.0.1")
        var invitation: DevicePairing.Invitation?
        for _ in 0 ..< 100 {
            if case let .advertising(advertised) = host.state { invitation = advertised; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let advertised = try XCTUnwrap(invitation)
        let hello = try JSONEncoder().encode(DevicePairing.hello(for: advertised, deviceName: "SplitDevice"))
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: advertised.port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: .main)
        let half = hello.count / 2
        connection.send(content: hello.prefix(half), completion: .idempotent)
        try await Task.sleep(for: .milliseconds(400))
        connection.send(content: hello.suffix(from: half), completion: .idempotent)
        for _ in 0 ..< 100 {
            if case .linked = host.state { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard case let .linked(name) = host.state else {
            return XCTFail("a split Hello was refused: host state is \(host.state)")
        }
        XCTAssertEqual(name, "SplitDevice")
    }
}

@MainActor
private final class Outcome {
    private(set) var finished = false
    private(set) var error: Error?
    func finish(_ error: Error?) { finished = true; self.error = error }
}
