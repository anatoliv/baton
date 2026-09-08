import XCTest
import BatonPlaybackKit
import BatonSubsonicKit
@testable import Baton

/// The music friend's memory and its learned corrections travel with a setup.
///
/// Both live in Application Support JSON rather than in `UserDefaults`, so for as long as
/// this transfer has existed they were invisible to it: a phone set up from a Mac arrived
/// with a friend that had been told nothing and learned nothing, while every setting around
/// them came across correctly.
///
/// The friend's *log* is deliberately not carried, on the same reasoning that keeps play
/// history and the scrobble queue out of `excludedPreferenceKeys`: it is history, not a
/// setting, and it is the one thing here that would be surprising to receive.
final class SettingsTransferDocumentTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var source: URL!
    private var destination: URL!

    override func setUp() {
        super.setUp()
        suiteName = "io.tonebox.tests.transferdocs.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        NavidromeKeychain.inMemoryStore = [:]
        source = makeDirectory("source")
        destination = makeDirectory("destination")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        NavidromeKeychain.inMemoryStore = nil
        NavidromeConfig.defaults = .standard
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: destination)
        super.tearDown()
    }

    private func makeDirectory(_ label: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("io.tonebox.tests.\(label).\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, named name: String, to directory: URL) {
        try? Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func read(_ name: String, in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func seedFriendFiles() {
        write(#"{"entries":[{"text":"no live albums"}]}"#, named: "remote-memory.json", to: source)
        write(#"{"corrections":[{"note":"too loud"}]}"#, named: "music-friend-learned.json", to: source)
        write(#"{"exchanges":[{"request":"play something"}]}"#, named: "music-friend-log.json", to: source)
    }

    // MARK: - The bug this exists for

    func testTheFriendsMemoryAndLearningTravelWithAnEncryptedExport() throws {
        seedFriendFiles()
        NavidromeConfig.defaults = suite

        let export = try SettingsTransfer.makeExport(
            includeSecrets: true, passphrase: "correct horse", defaults: suite, documentsIn: source)
        XCTAssertEqual(export.documentCount, 2, "memory and learning, and not the log")

        let result = try SettingsTransfer.applyImport(
            export.data, passphrase: "correct horse", defaults: suite, documentsIn: destination)

        XCTAssertEqual(result.documentCount, 2)
        XCTAssertEqual(read("remote-memory.json", in: destination), #"{"entries":[{"text":"no live albums"}]}"#)
        XCTAssertEqual(read("music-friend-learned.json", in: destination), #"{"corrections":[{"note":"too loud"}]}"#)
    }

    /// History, not a setting. Receiving a log of what was asked on somebody else's machine
    /// is the one thing in this transfer that would be a surprise rather than a convenience.
    func testTheFriendsLogDoesNotTravel() throws {
        seedFriendFiles()
        NavidromeConfig.defaults = suite

        let export = try SettingsTransfer.makeExport(
            includeSecrets: true, passphrase: "pw", defaults: suite, documentsIn: source)
        _ = try SettingsTransfer.applyImport(
            export.data, passphrase: "pw", defaults: suite, documentsIn: destination)

        XCTAssertNil(read("music-friend-log.json", in: destination),
                     "the friend's log is history and must stay on the device that made it")
    }

    // MARK: - Where the line is drawn

    /// A preferences-only export is plain JSON that the header calls safe to store or email.
    /// What you have told the friend about yourself does not belong in a file with that
    /// promise, so documents ride with the secrets and are therefore always encrypted.
    func testAPlainExportCarriesNoDocuments() throws {
        seedFriendFiles()

        let export = try SettingsTransfer.makeExport(
            includeSecrets: false, passphrase: nil, defaults: suite, documentsIn: source)

        XCTAssertEqual(export.documentCount, 0)
        XCTAssertFalse(export.encrypted)
        let outer = try XCTUnwrap(try JSONSerialization.jsonObject(with: export.data) as? [String: Any])
        let inner = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(outer["payload"] as? String)))
        XCTAssertNil(String(decoding: inner, as: UTF8.self).range(of: "no live albums"),
                     "the friend's memory must not appear in a file offered as safe to email")
    }

    /// The same allowlist guard the secrets have, driven the way it would actually be
    /// attacked: a hand-built backup naming files of its own choosing, fed to the real
    /// import. A path traversal here would write anywhere the app can reach.
    func testAHandBuiltBackupCannotWriteFilesOfItsChoosing() throws {
        let inner: [String: Any] = [
            "app": "baton",
            "schemaVersion": 1,
            "preferences": [:],
            "documents": [
                "remote-memory.json": Data(#"{"entries":[]}"#.utf8).base64EncodedString(),
                "../../../evil.json": Data("owned".utf8).base64EncodedString(),
                "music-friend-log.json": Data("history".utf8).base64EncodedString(),
                "anything-else.json": Data("nope".utf8).base64EncodedString(),
            ],
        ]
        let payload = try PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
        let outer: [String: Any] = [
            "format": "baton-settings", "version": 1, "encrypted": false,
            "payload": payload.base64EncodedString(),
        ]
        let file = try JSONSerialization.data(withJSONObject: outer)

        let result = try SettingsTransfer.applyImport(
            file, passphrase: nil, defaults: suite, documentsIn: destination)

        XCTAssertEqual(result.documentCount, 1, "only the one allowlisted name may be written")
        XCTAssertNotNil(read("remote-memory.json", in: destination))
        XCTAssertNil(read("anything-else.json", in: destination))
        XCTAssertNil(read("music-friend-log.json", in: destination),
                     "not carried on export, and not accepted on import either")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("../../../evil.json").path),
            "a traversing name must not escape the documents directory")
    }

    /// Absent files are the normal case for a friend nobody has talked to, and must not turn
    /// an export into a failure or write empty files over a destination that has content.
    func testAnExportWithNoFriendFilesIsFineAndOverwritesNothing() throws {
        NavidromeConfig.defaults = suite
        write(#"{"entries":[{"text":"keep me"}]}"#, named: "remote-memory.json", to: destination)

        let export = try SettingsTransfer.makeExport(
            includeSecrets: true, passphrase: "pw", defaults: suite, documentsIn: source)
        XCTAssertEqual(export.documentCount, 0)

        let result = try SettingsTransfer.applyImport(
            export.data, passphrase: "pw", defaults: suite, documentsIn: destination)

        XCTAssertEqual(result.documentCount, 0)
        XCTAssertEqual(read("remote-memory.json", in: destination), #"{"entries":[{"text":"keep me"}]}"#,
                       "an export that carried nothing must not erase what is already here")
    }

    // MARK: - The test environment must not touch the real one

    func testTheDefaultDocumentsDirectoryIsAThrowawayUnderXCTest() throws {
        let underTest = try XCTUnwrap(SettingsTransfer.documentsDirectory(environment: .testing))
        XCTAssertFalse(underTest.path.contains("Application Support"),
                       "a test run must never read or write the developer's own friend memory")
    }
}
