import Foundation
import XCTest
#if canImport(BatonMobile)
@testable import BatonMobile
#endif

final class IncomingSharePresentationStateTests: XCTestCase {
    private struct Invitation: Equatable { let id: String; let key: Data }
    private typealias State = IncomingSharePresentationState<Invitation>
    private let first = Invitation(id: "same-share", key: Data([1]))
    private let changedKey = Invitation(id: "same-share", key: Data([2]))

    func testStableModalDefersWithoutLosingRequest() {
        var state = State(); state.receive(first)
        XCTAssertNil(state.next(canPresent: false)); XCTAssertEqual(state.request?.invitation, first)
        guard case let .present(request) = state.next(canPresent: true) else { return XCTFail() }
        XCTAssertEqual(request.invitation, first); XCTAssertEqual(state.phase, .presenting(request.token))
    }
    func testSameInvitationDoesNotReopenOrReplace() {
        var state = State(); state.receive(first); let token = state.request!.token
        _ = state.next(canPresent: true); state.presented(token); state.receive(first)
        XCTAssertEqual(state.request?.token, token); XCTAssertNil(state.next(canPresent: true))
    }
    func testSameIDChangedKeySupersedesWithNewIdentity() {
        var state = State(); state.receive(first); let token = state.request!.token
        _ = state.next(canPresent: true); state.presented(token); state.receive(changedKey)
        guard case let .replace(request) = state.next(canPresent: true) else { return XCTFail() }
        XCTAssertNotEqual(request.token, token); XCTAssertEqual(request.invitation, changedKey)
        XCTAssertFalse(state.close(token)); XCTAssertTrue(state.isCurrent(request.token))
    }
    func testSupersessionDuringPresentationWaitsForActualCompletion() {
        var state = State(); state.receive(first); let old = state.request!.token
        _ = state.next(canPresent: true); state.receive(changedKey)
        XCTAssertNil(state.next(canPresent: true)); XCTAssertFalse(state.close(old))
        state.presented(UUID()); XCTAssertEqual(state.phase, .presenting(old))
        state.presented(old)
        guard case let .replace(request) = state.next(canPresent: true) else { return XCTFail() }
        XCTAssertEqual(request.invitation, changedKey)
        state.presented(old); state.dismissed(old)
        XCTAssertEqual(state.phase, .visible(request.token)); XCTAssertTrue(state.isCurrent(request.token))
    }
    func testCloseDuringPresentationClearsKeyAndDismissesAfterCompletion() {
        var state = State(); state.receive(first); let token = state.request!.token
        _ = state.next(canPresent: true); XCTAssertTrue(state.close(token))
        XCTAssertNil(state.request); XCTAssertNil(state.next(canPresent: true))
        state.presented(token)
        guard case .dismiss(token) = state.next(canPresent: true) else { return XCTFail() }
        state.dismissed(token); XCTAssertEqual(state.phase, .idle); XCTAssertNil(state.request)
    }
    func testNewLinkDuringDismissalSurvivesOldCloseAndDismissCallbacks() {
        var state = State(); state.receive(first); let old = state.request!.token
        _ = state.next(canPresent: true); state.presented(old); _ = state.close(old)
        _ = state.next(canPresent: true); state.receive(changedKey); let latest = state.request!.token
        XCTAssertNil(state.next(canPresent: true)); XCTAssertFalse(state.close(old))
        state.dismissed(old)
        guard case let .present(request) = state.next(canPresent: true) else { return XCTFail() }
        XCTAssertEqual(request.token, latest); XCTAssertEqual(request.invitation, changedKey)
    }
    func testABARequestFencesOldCloseEvenWhenValueMatchesAgain() {
        var state = State(); state.receive(first); let old = state.request!.token
        _ = state.next(canPresent: true); state.presented(old)
        state.receive(changedKey); _ = state.next(canPresent: true)
        state.receive(first); let latest = state.request!.token; _ = state.next(canPresent: true)
        XCTAssertNotEqual(latest, old); XCTAssertFalse(state.close(old)); XCTAssertTrue(state.isCurrent(latest))
    }
    func testTeardownClearsPrivateRequestAndIgnoresAllLateCompletions() {
        var state = State(); state.receive(first); let old = state.request!.token
        _ = state.next(canPresent: true); state.clear(); state.presented(old); state.dismissed(old)
        XCTAssertNil(state.request); XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.close(old)); XCTAssertNil(state.next(canPresent: true))
    }
    func testNewSourceGenerationFencesCallbackBeforeRendererUpdate() {
        var state = State(); let old = UUID(); let newest = UUID()
        state.receive(first, token: old); _ = state.next(canPresent: true); state.presented(old)
        XCTAssertTrue(state.isCurrent(old, sourceToken: old))
        XCTAssertFalse(state.isCurrent(old, sourceToken: newest), "Routing changed before UIKit's render update")
        state.receive(first, token: newest)
        XCTAssertFalse(state.close(old)); XCTAssertTrue(state.isCurrent(newest, sourceToken: newest))
        guard case let .replace(request) = state.next(canPresent: true) else { return XCTFail() }
        XCTAssertEqual(request.token, newest)
    }

    func testVisibleSupersessionClearsPrivateContentBeforeBlockedOrInactiveDrive() {
        var state = State(); let old = UUID(); let next = UUID()
        state.receive(first, token: old); _ = state.next(canPresent: true); state.presented(old)
        XCTAssertFalse(state.needsPrivateContentClear(sourceToken: old))
        XCTAssertTrue(state.needsPrivateContentClear(sourceToken: next), "Clear even before renderer receives new request")
        state.receive(changedKey, token: next)
        // No next action is executed: UIKit is still inactive or behind an alert/transition.
        XCTAssertEqual(state.phase, .visible(old))
        XCTAssertTrue(state.needsPrivateContentClear(sourceToken: next))
        XCTAssertEqual(state.request?.invitation, changedKey, "Only the pending replacement remains")
        guard case .replace = state.next(canPresent: true) else { return XCTFail() }
        XCTAssertFalse(state.needsPrivateContentClear(sourceToken: next))
    }

    func testBackgroundDuringPresentationDeniesLateAudioActivation() {
        var state = State(); let token = UUID()
        state.receive(first, token: token); _ = state.next(canPresent: true)
        XCTAssertTrue(state.canActivateAudio(token, sourceToken: token, foreground: true))
        XCTAssertFalse(state.canActivateAudio(token, sourceToken: token, foreground: false))
        state.presented(token)
        XCTAssertFalse(state.canActivateAudio(token, sourceToken: token, foreground: false))
        XCTAssertFalse(state.canActivateAudio(token, sourceToken: UUID(), foreground: true))
        _ = state.close(token)
        XCTAssertFalse(state.canActivateAudio(token, sourceToken: token, foreground: true))
    }

    func testConfirmedDismissalDuringPresentationFencesLateCompletionAndKeepsReplacement() {
        var state = State(); state.receive(first); let old = state.request!.token
        _ = state.next(canPresent: true); state.receive(changedKey); let next = state.request!.token
        XCTAssertFalse(state.close(old)); state.dismissed(old)
        XCTAssertEqual(state.phase, .idle); XCTAssertTrue(state.isCurrent(next))
        state.presented(old); XCTAssertEqual(state.phase, .idle)
        guard case let .present(request) = state.next(canPresent: true) else { return XCTFail() }
        XCTAssertEqual(request.token, next)
    }

}
