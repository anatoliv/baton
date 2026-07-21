import XCTest
@testable import Baton

/// W-55: the load / empty / error state a screen shows is derived by a pure resolver, so the
/// priority (loading → error → empty → content) is testable independent of any SwiftUI view.
final class ContentDisplayStateTests: XCTestCase {
    func testLoadingWinsWhileFetching() {
        XCTAssertEqual(ContentDisplayState.resolve(isLoading: true, error: nil, isEmpty: true), .loading)
        XCTAssertEqual(ContentDisplayState.resolve(isLoading: true, error: "boom", isEmpty: false), .loading)
    }

    func testErrorShownWhenSettledWithAFailure() {
        XCTAssertEqual(ContentDisplayState.resolve(isLoading: false, error: "network down", isEmpty: true), .failed("network down"))
    }

    func testWhitespaceOnlyErrorIsNotAFailure() {
        XCTAssertEqual(ContentDisplayState.resolve(isLoading: false, error: "   ", isEmpty: false), .content)
    }

    func testEmptyWhenSettledWithNoDataAndNoError() {
        XCTAssertEqual(ContentDisplayState.resolve(isLoading: false, error: nil, isEmpty: true), .empty)
    }

    func testContentWhenSettledWithData() {
        XCTAssertEqual(ContentDisplayState.resolve(isLoading: false, error: nil, isEmpty: false), .content)
    }
}
