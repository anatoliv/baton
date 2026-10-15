import Foundation
import XCTest
@testable import BatonShareKit

final class ShareToolHandoffTests: XCTestCase {
    func testNamedRecipientProducesDraftAndPreservesEntireFragment() throws {
        let recipient = try ShareToolHandoff.recipient(from: ["recipient": "  Maya  "])
        let link = ShareLink(id: Base64URL.encode(Data(repeating: 1, count: 16)),
                             key: Data(repeating: 2, count: ShareCrypto.keyLength)).url().absoluteString
        let result = ShareToolHandoff.result(link: link, title: "Blue", artist: "Artist",
                                             expiresAt: Date(timeIntervalSince1970: 100), recipient: recipient)
        XCTAssertEqual(result["delivery_status"], "not_sent")
        XCTAssertEqual(result["recipient"], "Maya")
        XCTAssertEqual(result["link"], link)
        XCTAssertEqual(result["message"], "Maya, listen to Blue by Artist.\n\(link)")
        XCTAssertEqual(result["message"]?.components(separatedBy: "\n").last, link)
    }

    func testUnnamedHandoffDoesNotInventARecipient() throws {
        XCTAssertNil(try ShareToolHandoff.recipient(from: [:]))
        XCTAssertNil(try ShareToolHandoff.recipient(from: ["recipient": "   "]))
        let result = ShareToolHandoff.result(link: "full-link#key", title: "Blue", artist: "",
                                             expiresAt: Date(), recipient: nil)
        XCTAssertNil(result["recipient"])
        XCTAssertEqual(result["message"], "listen to Blue.\nfull-link#key")
        XCTAssertEqual(result["delivery_status"], "not_sent")
    }

    func testMalformedRecipientsAreRefusedBeforeUpload() {
        let values: [Any] = [42, NSNull(), ["Maya"], String(repeating: "a", count: 81),
                             "Maya\nSomeone else", "Maya\r", "Maya\u{202e}", "Maya\u{0000}"]
        for value in values {
            XCTAssertThrowsError(try ShareToolHandoff.recipient(from: ["recipient": value])) { error in
                XCTAssertEqual(error as? ShareToolHandoff.ValidationError, .invalidRecipient)
            }
        }
    }

    func testUnicodeNamesAndBoundaryLengthRemainUsable() throws {
        XCTAssertEqual(try ShareToolHandoff.recipient(from: ["recipient": "Zoë O’Connor"]), "Zoë O’Connor")
        XCTAssertEqual(try ShareToolHandoff.recipient(from: ["recipient": "李明"]), "李明")
        XCTAssertEqual(try ShareToolHandoff.recipient(from: ["recipient": String(repeating: "é", count: 80)]), String(repeating: "é", count: 80))
    }
}
