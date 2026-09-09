import XCTest
@testable import BatonPlaybackKit

/// The real `PairingHost` (Mac) talking to the real `PairingClient` (phone), both in this
/// process, over loopback.
///
/// Found while working TBX-5151: `PairingHostLiveTests` already proved the listener side
/// reaches `.advertising` in-process, and `PairingTransportReadTests` proved the client side
/// reads a full payload from a loopback socket that stands in for the host. What neither did
/// is run the two halves against each other — which turns out to work fine in-process, once
/// the client is the thing making the connection rather than a bespoke `NWListener` server
/// standing in for one (see the comment on `PairingTransportReadTests.serve`). So this closes
/// the specific gap those two left: it is the transport half of TBX-3846's fix, proven with
/// the genuine production types on both ends rather than a substitute for either.
///
/// **What this does not prove**, because none of it is reachable without hardware, and this
/// is exactly the residual TBX-5151 is tracking: LAN reachability across two real devices
/// (this binds `127.0.0.1`, not a LAN interface), the QR scan itself, the SwiftUI sheet swap
/// in `MacTransferView`/`PairingScannerView`, and the real encrypted `SettingsTransfer`
/// payload end to end (the payload here is a stub, to isolate the socket behaviour from the
/// encryption format).
@MainActor
final class PairingHostClientLoopbackTests: XCTestCase {
    /// A payload that fits in one TCP segment — the case that always worked, even with the
    /// old short read, and the reason the bug looked intermittent rather than broken.
    func testASmallPayloadRoundTrips() async throws {
        let host = PairingHost()
        defer { host.stop() }
        let expected = Data("hello from the mac".utf8)
        host.approve = { _ in true }
        host.makePayload = { _ in expected }

        try host.start(host: "127.0.0.1")
        let invitation = try await advertisedInvitation(host)

        let received = try await PairingClient.redeem(invitation, deviceName: "ProbeDevice")
        XCTAssertEqual(received, expected)
    }

    /// 512 KB is many TCP segments — the exact shape the old `minimumIncompleteLength: 1`
    /// read truncated to whatever arrived in the first one. This is the regression TBX-3846
    /// fixed, run here against the real host rather than a stand-in server.
    func testALargePayloadArrivesWholeWithNoShortRead() async throws {
        let host = PairingHost()
        defer { host.stop() }
        let expected = Data((0 ..< 512 * 1024).map { UInt8($0 % 251) })
        host.approve = { _ in true }
        host.makePayload = { _ in expected }

        try host.start(host: "127.0.0.1")
        let invitation = try await advertisedInvitation(host)

        let received = try await PairingClient.redeem(invitation, deviceName: "ProbeDevice")
        XCTAssertEqual(received.count, expected.count,
                       "short read: got \(received.count) of \(expected.count) bytes")
        XCTAssertEqual(received, expected, "bytes must arrive in order and intact")

        // The host's own state machine should agree the link completed, not just the client.
        for _ in 0 ..< 100 {
            if case .linked = host.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case let .linked(name) = host.state else {
            return XCTFail("host never reached .linked — state is \(host.state)")
        }
        XCTAssertEqual(name, "ProbeDevice")
    }

    /// The buffer is written from the receive callback and read from the timeout block, on
    /// two different queues. Before the lock, that was an unsynchronised read of a `Data`
    /// being reallocated: a torn or short payload that fails to parse, which looks exactly
    /// like the short read TBX-3846 fixed and would be chased the same wrong way (S-F27).
    ///
    /// Driven directly rather than through a socket because a race needs to be provoked,
    /// not waited for: the real receive callbacks are serialised by the connection's queue,
    /// so a loopback test would pass on the broken code every time. Many small appends from
    /// several threads while another thread reads is the shape that loses bytes, and the
    /// same test under the thread sanitizer names the two queues.
    func testTheBufferSurvivesAppendsAndReadsFromSeveralThreadsAtOnce() {
        let writers = 8
        let chunksPerWriter = 64
        let chunkSize = 512

        for iteration in 0 ..< 20 {
            let sink = PairingClient.SharedAccumulator(cap: 4 * 1024 * 1024)
            let done = DispatchGroup()
            let queue = DispatchQueue(label: "pairing.race.\(iteration)", attributes: .concurrent)

            for writer in 0 ..< writers {
                queue.async(group: done) {
                    let chunk = Data(repeating: UInt8(writer), count: chunkSize)
                    for _ in 0 ..< chunksPerWriter {
                        _ = sink.consume(chunk, isComplete: false, failed: false)
                    }
                }
            }
            // The timeout block's read, running while the appends are in flight.
            for _ in 0 ..< 4 {
                queue.async(group: done) {
                    for _ in 0 ..< chunksPerWriter { _ = sink.accumulated.count }
                }
            }
            done.wait()

            let assembled = sink.accumulated
            XCTAssertEqual(assembled.count, writers * chunksPerWriter * chunkSize,
                           "bytes were lost or torn on iteration \(iteration): appends from two queues raced")
            var counts = [Int](repeating: 0, count: 256)
            for byte in assembled { counts[Int(byte)] += 1 }
            for writer in 0 ..< writers {
                XCTAssertEqual(counts[writer], chunksPerWriter * chunkSize,
                               "writer \(writer)'s bytes did not all survive on iteration \(iteration)")
            }
            for other in writers ..< 256 {
                XCTAssertEqual(counts[other], 0, "a byte nobody wrote appeared in the payload")
            }
        }
    }

    /// Only one of the timeout block and the last receive callback may resume the
    /// continuation, and they run on different queues. Resuming a checked continuation
    /// twice traps, so this is a crash rather than a wrong answer.
    func testExactlyOneCallerClaimsTheFinish() {
        for _ in 0 ..< 50 {
            let sink = PairingClient.SharedAccumulator(cap: 1024)
            let claims = RaceCounter()
            let done = DispatchGroup()
            let queue = DispatchQueue(label: "pairing.finish", attributes: .concurrent)
            for _ in 0 ..< 8 {
                queue.async(group: done) { if sink.claimFinish() { claims.increment() } }
            }
            done.wait()
            XCTAssertEqual(claims.value, 1, "two queues both resumed the continuation")
        }
    }

    private func advertisedInvitation(_ host: PairingHost) async throws -> DevicePairing.Invitation {
        for _ in 0 ..< 100 {
            if case let .advertising(invitation) = host.state { return invitation }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("host never reached .advertising in time")
    }
}

/// A counter the test itself can share across threads without being the thing under test.
private final class RaceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
