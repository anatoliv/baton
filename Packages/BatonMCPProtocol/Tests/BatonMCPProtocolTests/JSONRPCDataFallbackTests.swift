import XCTest
@testable import BatonMCPProtocol

/// `JSONRPC.data`'s `?? Data("{}".utf8)` fallback. It read as reachable, and the
/// doc comment above it said so, but `JSONSerialization.data(withJSONObject:)` raises an
/// Objective-C `NSInvalidArgumentException` for a value it cannot encode rather than throwing
/// a Swift error, and `try?` only catches the latter. Feeding it an invalid object crashed the
/// process before the `??` was ever reached: on the old code, either test below aborted the
/// whole test run with something like
/// `*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason:
/// 'Invalid type in JSON write (NaN)'` (confirmed by running this file against a stash of the
/// pre-fix `data(_:)`, which is why the assertions live in two separate tests rather than one:
/// a single test would still only report the first crash, but this way the log shows which
/// shape of bad input was under test when the process went down).
///
/// The fix validates with `isValidJSONObject` first and, on failure, encodes a well-formed
/// JSON-RPC error object instead of `{}` or a crash.
final class JSONRPCDataFallbackTests: XCTestCase {
    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `Double.nan` is not JSON-legal: `JSONSerialization` rejects NaN and infinite numbers.
    func testANanValueDegradesToAJSONRPCErrorRatherThanCrashing() throws {
        let object = try decode(JSONRPC.data(["jsonrpc": "2.0", "id": 1, "result": Double.nan]))
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertTrue(object["id"] is NSNull, "the id is unknown once encoding failed")
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, JSONRPCError.internalError)
        XCTAssertNotNil(error["message"] as? String)
        XCTAssertNil(object["result"], "a fallback error envelope carries no result")
    }

    /// `JSONSerialization` also rejects a dictionary whose values are not themselves
    /// JSON-legal, such as one keyed by something other than a string once it is nested
    /// inside the object being encoded.
    func testANonStringKeyedNestedDictionaryDegradesToAJSONRPCErrorRatherThanCrashing() throws {
        let notJSONLegal: [AnyHashable: Any] = [1: "one", 2: "two"]
        let object = try decode(JSONRPC.data(["jsonrpc": "2.0", "id": 1, "result": notJSONLegal]))
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, JSONRPCError.internalError)
    }

    /// The guard this fix adds does not change behaviour for the object shapes the module
    /// actually builds; every envelope constructor stays encodable.
    func testValidEnvelopesAreUnaffected() throws {
        let object = try decode(JSONRPC.data(JSONRPC.result(id: 1, ["ok": true])))
        XCTAssertEqual((object["result"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertNil(object["error"])
    }
}
