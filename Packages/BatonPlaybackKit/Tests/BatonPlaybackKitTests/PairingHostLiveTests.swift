import Observation
import XCTest
@testable import BatonPlaybackKit

/// Does the listener actually come up?
///
/// The protocol tests cover the rules; this covers the thing that has to work on a real
/// machine — binding a port and getting far enough to draw a code. It is the step the Mac's
/// "Show pairing code" button depends on, and nothing exercised it before.
@MainActor
final class PairingHostLiveTests: XCTestCase {
    /// Without this, "Show pairing code" does nothing visible: the listener starts, the
    /// state moves to `.advertising`, and the view never redraws because nothing told it to.
    /// That shipped in 0.15.0 — the type was `@MainActor` but not `@Observable`, which no
    /// compiler warns about and no protocol test can see.
    func testStateChangesAreObservable() async throws {
        let host = PairingHost()
        defer { host.stop() }

        XCTAssertTrue((host as Any) is any Observable,
                      "SwiftUI can only redraw on state it is able to observe")

        // The onChange callback is invoked off the current isolation, so the flag it sets
        // needs to survive that hop — an expectation is the idiomatic way to say so.
        let changed = expectation(description: "observers are notified of a state change")
        withObservationTracking {
            _ = host.state
        } onChange: {
            changed.fulfill()
        }

        try host.start(host: "127.0.0.1")
        await fulfillment(of: [changed], timeout: 5)
    }

    func testStartReachesAdvertisingWithAUsablePort() async throws {
        let host = PairingHost()
        defer { host.stop() }

        try host.start(host: "127.0.0.1")

        // start() populates the invitation from a background poll for the assigned port.
        for _ in 0 ..< 100 {
            if case .advertising = host.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        guard case let .advertising(invitation) = host.state else {
            return XCTFail("listener never advertised — state is \(host.state)")
        }
        XCTAssertGreaterThan(invitation.port, 0, "a code with port 0 is unusable")
        XCTAssertEqual(invitation.host, "127.0.0.1")
        XCTAssertNotNil(DevicePairing.parse(invitation.url), "the code it draws must parse back")
    }
}
