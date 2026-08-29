import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The framing half of the pairing short read, tested without a socket.
///
/// **These exist because three tests next door do not run.** `PairingTransportReadTests` parks its
/// socket cases with an unconditional skip: the `NWConnection` loopback harness would not come up
/// in the test process, so every read returned nothing and the suite reported a fact about the
/// harness rather than about the code. That was honest, but it left the shipped bug uncovered —
/// and the bug was pure framing: `receive(minimumIncompleteLength: 1, …)` resumed on the first
/// byte and threw the rest of the payload away.
///
/// Framing is only visible when a payload arrives in more than one piece, which is exactly what
/// the harness could not arrange. Separating the decision from the socket makes it arrangeable by
/// hand — the same move the gateway's `StreamingUpload` made, for the same reason.
///
/// This does not replace pairing a real phone with a real Mac. It replaces *nothing being tested*.
final class PairingAccumulatorTests: XCTestCase {

    private typealias Accumulator = PairingClient.Accumulator

    /// Feed a payload in fixed-size pieces, then close, and return what the sink decided.
    private func deliver(_ payload: Data, inPiecesOf size: Int, cap: Int = 4 * 1024 * 1024) -> Data? {
        var sink = Accumulator(cap: cap)
        var offset = 0
        while offset < payload.count {
            let end = min(offset + size, payload.count)
            let step = sink.consume(payload[offset ..< end], isComplete: false, failed: false)
            if case let .finished(result) = step { return result }
            offset = end
        }
        // The host sends the whole payload and then closes.
        if case let .finished(result) = sink.consume(nil, isComplete: true, failed: false) {
            return result
        }
        return nil
    }

    /// The bug, stated as a test. A real settings export is tens of KB and never fits one TCP
    /// segment, so this is the case that actually shipped broken.
    func testAPayloadArrivingInManyPiecesIsReassembledWhole() {
        let payload = Data((0 ..< 300_000).map { UInt8($0 % 251) })
        for piece in [1024, 16_384, 65_536] {
            XCTAssertEqual(deliver(payload, inPiecesOf: piece), payload,
                           "lost data when it arrived in \(piece)-byte pieces")
        }
    }

    /// The old code returned the first segment. One byte at a time is that failure at its most
    /// extreme, and the cheapest proof nothing depends on convenient piece sizes.
    func testOneByteAtATimeStillReassembles() {
        let payload = Data((0 ..< 2000).map { UInt8($0 % 251) })
        XCTAssertEqual(deliver(payload, inPiecesOf: 1), payload)
    }

    /// A small export fits in one segment and always paired fine, which is why the bug looked
    /// intermittent rather than total. It must keep working.
    func testASinglePieceStillArrives() {
        let payload = Data("a small settings export".utf8)
        XCTAssertEqual(deliver(payload, inPiecesOf: 4096), payload)
    }

    /// A peer that connects and sends nothing gives nil, not empty data. `applyImport` on empty
    /// data would report "this isn't a Baton backup", which is the misleading message that sent
    /// everyone looking at the export format in the first place.
    func testAConnectionThatClosesWithNothingSentIsNil() {
        var sink = Accumulator()
        XCTAssertEqual(sink.consume(nil, isComplete: true, failed: false), .finished(nil))
    }

    /// A failure mid-stream keeps what arrived rather than discarding it: if it is complete it
    /// parses, and if it is not, the format check says so honestly instead of hanging.
    func testAnErrorMidStreamKeepsWhatArrived() {
        var sink = Accumulator()
        XCTAssertEqual(sink.consume(Data("half".utf8), isComplete: false, failed: false), .needMore)
        XCTAssertEqual(sink.consume(nil, isComplete: false, failed: true), .finished(Data("half".utf8)))
    }

    /// A pairing payload is settings, not media. Reading until close with no ceiling would let a
    /// peer stream forever into memory.
    func testTheCapStopsAnEndlessPeer() {
        var sink = Accumulator(cap: 1000)
        var step: Accumulator.Step = .needMore
        for _ in 0 ..< 10 {
            step = sink.consume(Data(repeating: 0x41, count: 200), isComplete: false, failed: false)
            if case .finished = step { break }
        }
        guard case let .finished(payload) = step else { return XCTFail("the cap never fired") }
        XCTAssertGreaterThanOrEqual(payload?.count ?? 0, 1000)
        XCTAssertLessThan(payload?.count ?? 0, 2000, "kept reading well past the cap")
    }
}
