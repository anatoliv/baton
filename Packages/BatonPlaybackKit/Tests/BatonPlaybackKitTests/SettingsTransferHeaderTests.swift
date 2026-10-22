import Foundation
import XCTest
@testable import BatonPlaybackKit
import BatonSubsonicKit

/// C-2: a server's custom headers are how Cloudflare Access or Authelia admits Baton
/// (`CF-Access-Client-Secret`), so they are credentials. A preferences-only export is plain
/// JSON "safe to store or email", and must not carry them; the encrypted export still does.
final class SettingsTransferHeaderTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = ThrowawayDefaults.name("transfer-headers")
        defaults = UserDefaults(suiteName: suiteName)
        var server = NavidromeServerEntry(displayName: "Home", urlString: "https://music.example.test",
                                          username: "ana", authMode: .tokenSalt)
        server.customHeaders = ["CF-Access-Client-Secret": "synthetic-header-secret"]
        defaults.set(try JSONEncoder().encode([server]), forKey: NavidromeConfig.serversKey)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// What a receiving Mac ends up with: the export imported into a fresh preferences domain.
    private func importedServers(_ result: SettingsTransfer.ExportResult, passphrase: String? = nil) throws -> [NavidromeServerEntry] {
        let receiverName = suiteName + ".receiver"
        let receiver = try XCTUnwrap(UserDefaults(suiteName: receiverName))
        defer { UserDefaults().removePersistentDomain(forName: receiverName) }
        _ = try SettingsTransfer.applyImport(result.data, passphrase: passphrase, defaults: receiver,
                                             documentsIn: SettingsTransfer.documentsDirectory())
        let data = try XCTUnwrap(receiver.data(forKey: NavidromeConfig.serversKey))
        return try JSONDecoder().decode([NavidromeServerEntry].self, from: data)
    }

    func testAPreferencesOnlyExportLeavesCustomHeadersBehind() throws {
        let result = try SettingsTransfer.makeExport(includeSecrets: false, passphrase: nil, defaults: defaults,
                                                     documentsIn: SettingsTransfer.documentsDirectory())
        let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(outer["payload"] as? String)))
        XCTAssertNil(payload.range(of: Data("synthetic-header-secret".utf8)), "the header value is not in the file")
        let servers = try importedServers(result)
        XCTAssertEqual(servers.map(\.urlString), ["https://music.example.test"], "the server list itself still travels")
        XCTAssertNil(servers.first?.customHeaders)
    }

    func testTheEncryptedExportStillCarriesThem() throws {
        let result = try SettingsTransfer.makeExport(includeSecrets: true, passphrase: "synthetic passphrase",
                                                     defaults: defaults, documentsIn: SettingsTransfer.documentsDirectory())
        let servers = try importedServers(result, passphrase: "synthetic passphrase")
        XCTAssertEqual(servers.first?.customHeaders, ["CF-Access-Client-Secret": "synthetic-header-secret"])
    }
}
