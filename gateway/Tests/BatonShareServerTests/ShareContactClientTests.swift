import BatonShareKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

private final class ContactProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Cache-Control": "private, no-store"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ShareContactClientTests: XCTestCase {
    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContactProtocol.self]
        return URLSession(configuration: configuration)
    }
    func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw ShareContactClient.Failure.invalid }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
            guard body.count <= 65536 else { throw ShareContactClient.Failure.invalid }
        }
    }
    func testOriginatingInstallationUsesFreshPurposeGrantForEveryContactAction() async throws {
        let transport = session(); defer { transport.invalidateAndCancel(); ContactProtocol.handler = nil }
        var purposes: [String] = []
        var calls: [String] = []
        var current = ""
        ContactProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "batonmusic.app")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer PUBLIC-INSTALLATION")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: self.requestBody(request)) as? [String: Any])
            let path = request.url!.path
            calls.append(path)
            if path == "/v1/share/contact/authorization" {
                let purpose = try XCTUnwrap(body["purpose"] as? String)
                purposes.append(purpose); current = "PUBLIC-GRANT-" + String(purposes.count)
                XCTAssertNil(body["address"]); XCTAssertNil(body["code"])
                return (200, try JSONSerialization.data(withJSONObject: ["authorization": current]))
            }
            XCTAssertEqual(body["authorization"] as? String, current)
            if path.hasSuffix("/access") {
                return (200, try JSONSerialization.data(withJSONObject: ["instructions": "PRIVATE FIXTURE INSTRUCTIONS", "location": "/s/fixture", "action": "disable"]))
            }
            return (200, Data("{\"status\":\"disconnected\"}".utf8))
        }
        let client = ShareContactClient(secret: "PUBLIC-INSTALLATION", session: transport)
        _ = try await client.enroll(address: "PUBLIC@fixture.invalid", include: [])
        _ = try await client.verify(code: "PUBLIC-code")
        _ = try await client.status()
        let notice = try await client.access(code: "PUBLIC-notice")
        XCTAssertEqual(notice.instructions, "PRIVATE FIXTURE INSTRUCTIONS")
        _ = try await client.withdraw()
        XCTAssertEqual(purposes, ["enroll", "verify", "status", "caseAccess", "withdraw"])
        XCTAssertEqual(calls.count, 10)
    }
    func testUnqualifiedOriginAndInvalidCodeNeverSendPrivateInput() async throws {
        let transport = session(); defer { transport.invalidateAndCancel(); ContactProtocol.handler = nil }
        ContactProtocol.handler = { _ in XCTFail("Private input was sent"); return (500, Data()) }
        let client = ShareContactClient(base: URL(string: "http://batonmusic.app")!, secret: "PUBLIC", session: transport)
        do { _ = try await client.enroll(address: "PUBLIC@fixture.invalid", include: []); XCTFail("HTTP origin accepted") }
        catch { XCTAssertEqual(error as? ShareContactClient.Failure, .invalid) }
        do { _ = try await client.access(code: "code with spaces"); XCTFail("Malformed code accepted") }
        catch { XCTAssertEqual(error as? ShareContactClient.Failure, .invalid) }
    }
}
