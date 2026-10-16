import Foundation
import XCTest
#if canImport(BatonMobile)
@testable import BatonMobile
#endif

final class IncomingShareSceneScopeTests: XCTestCase {
    func testOnlyTheSceneThatReceivedTheLinkOwnsItsPresentation() {
        let receiver = UUID(), other = UUID()
        XCTAssertTrue(IncomingShareSceneScope.owns(receiver, scene: receiver))
        XCTAssertFalse(IncomingShareSceneScope.owns(receiver, scene: other))
    }
    func testUnscopedInternalRequestCannotBroadcastToForegroundScenes() {
        XCTAssertFalse(IncomingShareSceneScope.owns(nil, scene: UUID()))
        XCTAssertFalse(IncomingShareSceneScope.owns(nil, scene: UUID()))
    }
    func testMovingTheSameInvitationToAnotherSceneEndsOldOwnership() {
        let first = UUID(), next = UUID()
        XCTAssertTrue(IncomingShareSceneScope.owns(first, scene: first))
        XCTAssertFalse(IncomingShareSceneScope.owns(next, scene: first))
        XCTAssertTrue(IncomingShareSceneScope.owns(next, scene: next))
    }
}
