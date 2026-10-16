import Foundation
import XCTest
@testable import BatonShareKit

@MainActor
private final class ConsentGate {
    var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

final class ReactionPushConsentTests: XCTestCase {
    func testOnlyVersionedGenericOwnerRouteAcceptsNoKeysOrURLs() throws {
        let id = "AAAAAAAAAAAAAAAAAAAAAA"
        let good: [String: Any] = ["v": 1, "route": "shared-links", "shareID": id]
        XCTAssertEqual(ReactionPushOwnerRoute.shareID(from: try JSONSerialization.data(withJSONObject: good)), id)
        for change in [["key": "secret"], ["url": "https://example.com"], ["v": 2], ["v": true],
                       ["route": "play"], ["shareID": "invalid"]] as [[String: Any]] {
            var bad = good; bad.merge(change) { _, new in new }
            XCTAssertNil(ReactionPushOwnerRoute.shareID(from: try JSONSerialization.data(withJSONObject: bad)))
        }
        XCTAssertNil(ReactionPushOwnerRoute.shareID(from: Data(repeating: 1, count: 4097)))
    }
    @MainActor func testUnavailableAndDeniedNeverRegisterOrCollectToken() async throws {
        var permissions = 0; var registrations = 0; var uploads = 0
        let coordinator = ReactionPushConsentCoordinator(permission: { permissions += 1; return false },
            register: { registrations += 1 }, unregister: {}, persist: { _ in },
            upload: { _ in uploads += 1 }, remove: {})
        let inactive = await coordinator.enableAfterExplicitAction(); XCTAssertFalse(inactive)
        XCTAssertEqual(permissions, 0)
        coordinator.setAvailable(true)
        let denied = await coordinator.enableAfterExplicitAction(); XCTAssertFalse(denied)
        try await coordinator.receive(token: Data([1]))
        XCTAssertEqual(permissions, 1); XCTAssertEqual(registrations, 0); XCTAssertEqual(uploads, 0)
    }
    @MainActor func testOptOutWhilePermissionPendingCannotRestoreOptIn() async throws {
        let gate = ConsentGate(); var registrations = 0
        let coordinator = ReactionPushConsentCoordinator(permission: { await gate.wait(); return true },
            register: { registrations += 1 }, unregister: {}, persist: { _ in }, upload: { _ in }, remove: {})
        coordinator.setAvailable(true)
        let enabling = Task { await coordinator.enableAfterExplicitAction() }
        while !gate.entered { await Task.yield() }
        try await coordinator.disable(); gate.resume()
        let enabled = await enabling.value
        XCTAssertFalse(enabled); XCTAssertFalse(coordinator.optedIn); XCTAssertEqual(registrations, 0)
    }
    @MainActor func testLateInFlightRegistrationIsRemovedAfterOptOut() async throws {
        let gate = ConsentGate(); var removals = 0
        let coordinator = ReactionPushConsentCoordinator(permission: { true }, register: {}, unregister: {},
            persist: { _ in }, upload: { _ in await gate.wait() }, remove: { removals += 1 })
        coordinator.setAvailable(true); _ = await coordinator.enableAfterExplicitAction()
        let upload = Task { try await coordinator.receive(token: Data([1, 2, 3])) }
        while !gate.entered { await Task.yield() }
        try await coordinator.disable(); XCTAssertEqual(removals, 1)
        gate.resume(); try await upload.value
        XCTAssertEqual(removals, 2); XCTAssertFalse(coordinator.optedIn)
    }
    @MainActor func testForegroundOnlyRefreshesTokenForAuthorizedOptInAndNeverPrompts() async throws {
        var prompts = 0; var registrations = 0; var uploads = 0
        let coordinator = ReactionPushConsentCoordinator(optedIn: true,
            permission: { prompts += 1; return true }, register: { registrations += 1 },
            unregister: {}, persist: { _ in }, upload: { _ in uploads += 1 }, remove: {})
        coordinator.foreground(authorized: true); XCTAssertEqual(registrations, 0)
        coordinator.setAvailable(true); coordinator.foreground(authorized: false)
        coordinator.foreground(authorized: true); XCTAssertEqual(registrations, 1); XCTAssertEqual(prompts, 0)
        try await coordinator.receive(token: Data())
        try await coordinator.receive(token: Data(repeating: 1, count: 1025))
        XCTAssertEqual(uploads, 0)
    }
    @MainActor func testPermissionRevokedBeforeLateTokenCallbackDoesNotUpload() async throws {
        var uploads = 0
        let coordinator = ReactionPushConsentCoordinator(permission: { true }, register: {}, unregister: {},
            persist: { _ in }, upload: { _ in uploads += 1 }, remove: {})
        coordinator.setAvailable(true); _ = await coordinator.enableAfterExplicitAction()
        coordinator.foreground(authorized: false)
        try await coordinator.receive(token: Data([1, 2, 3]))
        XCTAssertEqual(uploads, 0)
    }
}
