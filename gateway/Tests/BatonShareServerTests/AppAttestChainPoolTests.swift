@testable import BatonShareServer
import Crypto
import Foundation
import X509
import XCTest

/// Chain validation is async, and the synchronous caller waits for it. With the validator on the
/// cooperative pool, enough callers waiting at once (each on a pool thread, as the transport's
/// handlers are) left no thread to run any validator: every attestation failed after a 5 s
/// stall (TBX-1000000496 D-7). The validator now runs on a thread of its own.
final class AppAttestChainPoolTests: XCTestCase {
    func testChainValidationCompletesWhileItsCallersHoldEveryPoolThread() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let rootKey = P256.Signing.PrivateKey(), leafKey = P256.Signing.PrivateKey()
        let root = try AppAttestTestFixture.root(rootKey, now: now)
        let leaf = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 3600, issuer: root.subject,
            subject: try DistinguishedName { CommonName("Synthetic leaf") }, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions { Critical(KeyUsage(digitalSignature: true)) }, issuerPrivateKey: .init(rootKey))
        XCTAssertNoThrow(try AppAttestVerifier.validateChain(leaf: leaf, intermediates: [], root: root, now: now), "the fixture chain is valid")

        // As in ShareService.handle: one request validates under the service lock while the
        // others wait for that lock, each on a pool thread of its own.
        let waiters = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        // Swift 6.0 on Linux sees neither NSLock nor Certificate as Sendable; one box carries both.
        let shared = Shared(leaf: leaf, root: root, now: now)
        let started = Date()
        // Detached with no priority, like the validator itself, so on a Mac they share its slice
        // of the pool, as every task shares Linux's single pool.
        let validating = Task.detached { validateHoldingLock(shared) }
        let waiting = (0 ..< waiters).map { _ in Task.detached { waitForLock(shared) } }
        let validated = [await validating.value]
        for task in waiting { await task.value }
        XCTAssertEqual(validated, [true], "the chain validated while every other pool thread waited on the lock")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "without waiting out the 5 s bound")
    }
}

private final class Shared: @unchecked Sendable {
    let lock = NSLock()
    let leaf: Certificate, root: Certificate, now: Date
    init(leaf: Certificate, root: Certificate, now: Date) { self.leaf = leaf; self.root = root; self.now = now }
}

/// Synchronous, as the service's handler is: it blocks the pool thread it runs on.
private func validateHoldingLock(_ shared: Shared) -> Bool {
    shared.lock.lock()
    defer { shared.lock.unlock() }
    Thread.sleep(forTimeInterval: 0.5) // the waiters take every other pool thread meanwhile
    return (try? AppAttestVerifier.validateChain(leaf: shared.leaf, intermediates: [], root: shared.root, now: shared.now)) != nil
}

private func waitForLock(_ shared: Shared) {
    Thread.sleep(forTimeInterval: 0.05)
    shared.lock.lock()
    shared.lock.unlock()
}
