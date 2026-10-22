import XCTest
@testable import Baton

/// The "Link a device" pane's approval prompt must answer every ask (TBX-1000000504, A-10).
/// The pane dropped its continuation, unanswered, when it showed a new code or closed, so the
/// pairing host's approval task stayed suspended for the life of the app.
@MainActor
final class PairingApprovalPromptTests: XCTestCase {

    /// Waits a bounded time for an ask to come back. Nil means it never did.
    private final class Box { var value: Bool? }

    private func answer(of task: Task<Bool, Never>, within seconds: Double = 1) async -> Bool? {
        let box = Box()
        Task { @MainActor in box.value = await task.value }
        let deadline = Date().addingTimeInterval(seconds)
        while box.value == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return box.value
    }

    func testWithdrawingAnOpenPromptRefusesIt() async {
        let prompt = PairingApprovalPrompt()
        let ask = Task { await prompt.ask("Anatoli's iPhone") }
        while prompt.deviceName == nil { await Task.yield() }

        prompt.withdraw()

        let answered = await answer(of: ask)
        XCTAssertEqual(answered, false, "a withdrawn prompt was left unanswered, so the host waited forever")
        XCTAssertNil(prompt.deviceName)
    }

    func testASecondAskRefusesTheFirst() async {
        let prompt = PairingApprovalPrompt()
        let first = Task { await prompt.ask("Phone A") }
        while prompt.deviceName == nil { await Task.yield() }
        let second = Task { await prompt.ask("Phone B") }
        while prompt.deviceName != "Phone B" { await Task.yield() }

        let firstAnswer = await answer(of: first)
        XCTAssertEqual(firstAnswer, false, "the first ask was dropped unanswered")
        prompt.answer(true)
        let secondAnswer = await answer(of: second)
        XCTAssertEqual(secondAnswer, true)
    }

    func testAllowAndRefuseAnswerOnce() async {
        let prompt = PairingApprovalPrompt()
        let ask = Task { await prompt.ask("Phone") }
        while prompt.deviceName == nil { await Task.yield() }
        prompt.answer(true)
        prompt.answer(false)   // a second click answers nothing
        prompt.withdraw()
        let answered = await answer(of: ask)
        XCTAssertEqual(answered, true)
    }
}
