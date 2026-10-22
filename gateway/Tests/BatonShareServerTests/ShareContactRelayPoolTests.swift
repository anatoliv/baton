@testable import BatonShareServer
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
private let streamType = SOCK_STREAM
#else
import Glibc
private let streamType = Int32(SOCK_STREAM.rawValue)
#endif

/// The contact relay waits up to 5 s for the loopback worker with blocking poll(2). Inside an
/// async function that wait held a cooperative-pool thread, so a few relays at once left nothing
/// to run the rest of the service on, including the worker's own callback into it
/// (TBX-1000000496 D-8). The wait now happens on a thread of its own.
final class ShareContactRelayPoolTests: XCTestCase {
    func testRelaysWaitingOnASilentWorkerLeaveTheCooperativePoolFree() async throws {
        // A worker that takes connections into its backlog and never answers.
        let silent = try XCTUnwrap(silentLoopbackListener(), "could not listen on loopback")
        defer { close(silent.descriptor) }
        let port = silent.port

        let relays = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        let started = Date()
        let waiting = (0 ..< relays).map { _ in
            Task.detached { _ = try? await ShareContactRelay.forward(port: port, path: "/enroll", body: Data("{}".utf8)) }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let answered = await Task.detached { Date() }.value
        XCTAssertLessThan(answered.timeIntervalSince(started), 2,
                          "\(relays) relays waiting on the worker must not occupy the pool's threads")
        for task in waiting { await task.value }
    }
}

/// A listening loopback socket that never accepts, and its port.
private func silentLoopbackListener() -> (descriptor: Int32, port: UInt16)? {
    let listener = socket(AF_INET, streamType, 0)
    guard listener >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
    }
    guard bound, listen(listener, 128) == 0 else { close(listener); return nil }
    return (listener, UInt16(bigEndian: address.sin_port))
}
