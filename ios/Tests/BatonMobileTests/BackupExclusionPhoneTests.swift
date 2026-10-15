import XCTest
import BatonPlaybackKit
import BatonSubsonicKit
@testable import BatonMobile

/// The iPhone half of DOC-24: with no arguments, the stores the app constructs keep clipping
/// audio out of the backup and the sidecar in it.
///
/// `BatonPlaybackKitTests` proves the rule on the Mac by passing the decision in. This is the
/// only place the production default, `#if os(iOS)`, is actually compiled and run, so it is the
/// test that fails if the platform check is ever inverted or dropped.
@MainActor
final class BackupExclusionPhoneTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-backup-phone-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testThePhoneExcludesReCreatableAudio() {
        XCTAssertTrue(BackupExclusion.appliesOnThisPlatform)
    }

    func testAClippingKeptOnThePhoneHasItsAudioExcludedAndItsSidecarBackedUp() throws {
        let store = ClippingStore(directory: dir)
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-staged-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 2048).write(to: staged)

        let item = try store.adopt(staged, title: "A reading", text: "The words")

        XCTAssertTrue(BackupExclusion.isExcluded(item.url))
        XCTAssertFalse(BackupExclusion.isExcluded(dir.appendingPathComponent("\(item.id).json")),
                       "the sidecar is the only record of what the audio is")
    }
}
