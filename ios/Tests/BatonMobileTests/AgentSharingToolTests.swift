import XCTest
import BatonShareKit
@testable import BatonMobile

@MainActor
final class AgentSharingToolTests: XCTestCase {
    func testSharingToolIsAdvertisedWithMacArguments() throws {
        let tool = try XCTUnwrap(AgentTools.definitions.first { $0["name"] as? String == "music_share" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(["query", "note", "expires_days", "hide_details", "recipient"]))
        XCTAssertEqual(schema["required"] as? [String], [])
    }

    func testDefaultShareOptionsUseSevenDaysAndPublicPreview() throws {
        let options = try AgentTools.sharingOptions([:], from: "Sender")
        XCTAssertEqual(options.expiresInSeconds, 604800)
        XCTAssertTrue(options.showsDetails)
        XCTAssertEqual(options.note, "")
        XCTAssertEqual(options.from, "Sender")
    }

    func testExplicitNotePrivatePreviewAndAllSupportedExpiries() throws {
        for days in [1, 7, 30] {
            let options = try AgentTools.sharingOptions(["note": "A note", "hide_details": true, "expires_days": days], from: "Sender")
            XCTAssertEqual(options.expiresInSeconds, days * 86400)
            XCTAssertFalse(options.showsDetails)
            XCTAssertEqual(options.note, "A note")
            XCTAssertEqual(options.from, "Sender")
        }
    }

    func testUnsupportedExpiryIsRefused() {
        for days in [-1, 0, 2, 31, Int.max] {
            XCTAssertThrowsError(try AgentTools.sharingOptions(["expires_days": days], from: "")) { error in
                XCTAssertEqual(error.localizedDescription, "expires_days must be 1, 7 or 30.")
            }
        }
    }

    func testAgentRefusesBeforeManualConsentAndReportsAnError() async {
        let tools = AgentTools(model: MobileModel(), canShare: { false })
        let result = await tools.run(name: "music_share", arguments: ["query": "must not search or upload"], sessionID: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.hasPrefix("Share a song once from Baton itself first"))
    }

    func testInvalidExpiryCannotReachSongResolution() async {
        let tools = AgentTools(model: MobileModel(), canShare: { true })
        let result = await tools.run(name: "music_share", arguments: ["expires_days": 2], sessionID: nil)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "expires_days must be 1, 7 or 30.")
    }

    func testNoCurrentSongIsAnErrorRatherThanFabricatedShare() async {
        let tools = AgentTools(model: MobileModel(), canShare: { true })
        let result = await tools.run(name: "music_share", arguments: [:], sessionID: nil)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Nothing is playing. Provide a query for the song to share.")
    }

    func testMalformedRecipientCannotReachSongResolutionOrUpload() async {
        let tools = AgentTools(model: MobileModel(), canShare: { true })
        let result = await tools.run(name: "music_share", arguments: ["recipient": "Maya\nAnother person"], sessionID: nil)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, ShareToolHandoff.ValidationError.invalidRecipient.localizedDescription)
    }
}
