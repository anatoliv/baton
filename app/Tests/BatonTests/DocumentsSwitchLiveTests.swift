import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// The Documents switch taking effect without a relaunch: the switch reads the key
/// live, and the library it drives starts and stops with it, the same instance throughout.
@MainActor
final class DocumentsSwitchLiveTests: XCTestCase {
    func testTheSwitchReadsTheKeyLive() {
        let defaults = ThrowawayDefaults.make("documents-live")
        let toggle = DefaultsSwitch(key: DocumentLibrary.enabledKey, defaultValue: true, defaults: defaults)
        var seen: [Bool] = []
        toggle.onChange { seen.append($0) }
        XCTAssertTrue(toggle.isOn, "an absent key reads as on")
        defaults.set(false, forKey: DocumentLibrary.enabledKey)
        XCTAssertFalse(toggle.isOn, "off as soon as Settings stores it")
        defaults.set(true, forKey: DocumentLibrary.enabledKey)
        XCTAssertTrue(toggle.isOn)
        defaults.set("unrelated", forKey: "baton.something.else")
        XCTAssertEqual(seen, [false, true], "told once per change, and not about other keys")
    }

    func testTheLibraryStopsAndStartsWithTheSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = ThrowawayDefaults.make("documents-live")
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("live-clips"))
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: DocumentLibraryTests.FakeKokoro(), refreshInterval: .milliseconds(50),
                                      storageDefaults: defaults, gateway: { nil })
        let toggle = DefaultsSwitch(key: DocumentLibrary.enabledKey, defaultValue: true, defaults: defaults)
        library.follow(toggle)
        library.start(force: true)
        let instance = ObjectIdentifier(library)
        XCTAssertTrue(library.isStarted)

        defaults.set(false, forKey: DocumentLibrary.enabledKey)
        XCTAssertFalse(library.isStarted, "turned off in Settings: stopped at once")
        defaults.set(true, forKey: DocumentLibrary.enabledKey)
        XCTAssertTrue(library.isStarted, "turned on again: started at once")
        XCTAssertEqual(ObjectIdentifier(library), instance, "the same library, not a new one")

        // And it works after the round trip: a book is made.
        let url = root.appendingPathComponent("note.md")
        try "# A Note\n\n## One\n\nA short line to read." .write(to: url, atomically: true, encoding: .utf8)
        let prepared = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
        try await library.submit(prepared)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, clippings.chapters(ofDocument: prepared.documentID).isEmpty {
            library.refresh()
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(clippings.chapters(ofDocument: prepared.documentID).isEmpty)
    }
}
