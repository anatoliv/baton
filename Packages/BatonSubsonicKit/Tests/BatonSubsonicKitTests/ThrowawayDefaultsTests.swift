import Foundation
import XCTest
@testable import BatonSubsonicKit

/// Test suites must not outlive the test process (TBX-7443: 20,262 leftover plists).
final class ThrowawayDefaultsTests: XCTestCase {
    private let uuid = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"

    func testOnlyNamespacedUUIDSuitesCountAsThrowaway() {
        let ns = ThrowawayDefaults.namespace
        XCTAssertTrue(ThrowawayDefaults.isThrowawayPlist("\(ns)music.\(uuid).plist"))
        XCTAssertTrue(ThrowawayDefaults.isThrowawayPlist("\(ns)friendsync.phone.\(uuid).plist"))

        // A fixed-name suite, another project's suite, the old un-namespaced form, and a
        // name that merely ends in something UUID-shaped are all left alone.
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("\(ns)music.plist"))
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("io.tonebox.tests.cycle-tonebox.tasks.labelFilter.plist"))
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("io.tonebox.tests.music.\(uuid).plist"))
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("\(ns)music\(uuid).plist"))
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("\(ns)music.\(uuid).plist.bak"))
    }

    /// What `cfprefsd` writes back after a run is swept by the next one, and nothing else is.
    func testTheSweepRemovesOnlyStaleThrowawayPlists() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("throwaway-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let ns = ThrowawayDefaults.namespace
        let stale = dir.appendingPathComponent("\(ns)music.\(uuid).plist")
        let fresh = dir.appendingPathComponent("\(ns)eq.\(UUID().uuidString).plist")
        let fixed = dir.appendingPathComponent("\(ns)queuerestore.plist")
        let foreign = dir.appendingPathComponent("io.tonebox.tests.fresh.plist")
        for url in [stale, fresh, fixed, foreign] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("{}".utf8)))
        }
        let old = Date().addingTimeInterval(-3 * 60 * 60)
        for url in [stale, fixed, foreign] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        let removed = ThrowawayDefaults.sweepStale(in: dir, olderThan: ThrowawayDefaults.staleAge)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "a stale throwaway plist should go")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a suite a running test may use must stay")
        XCTAssertTrue(fm.fileExists(atPath: fixed.path), "a fixed-name suite must stay")
        XCTAssertTrue(fm.fileExists(atPath: foreign.path), "another project's suite must stay")
    }

    /// What `cfprefsd` writes back after a run is an empty `{}` plist. That goes after a
    /// minute, while one holding data waits the full ``staleAge``.
    func testAnEmptyStubGoesSoonerThanASuiteWithData() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("throwaway-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func plist(_ value: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        let ns = ThrowawayDefaults.namespace
        let stub = dir.appendingPathComponent("\(ns)music.\(UUID().uuidString).plist")
        let live = dir.appendingPathComponent("\(ns)music.\(UUID().uuidString).plist")
        XCTAssertTrue(fm.createFile(atPath: stub.path, contents: try plist([:])))
        XCTAssertTrue(fm.createFile(atPath: live.path, contents: try plist(["queue": "a"])))
        let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)
        for url in [stub, live] {
            try fm.setAttributes([.modificationDate: fiveMinutesAgo], ofItemAtPath: url.path)
        }

        XCTAssertEqual(ThrowawayDefaults.sweepStale(in: dir, olderThan: ThrowawayDefaults.staleAge), 1)
        XCTAssertFalse(fm.fileExists(atPath: stub.path), "an empty stub a few minutes old should go")
        XCTAssertTrue(fm.fileExists(atPath: live.path), "a suite with data must wait the full stale age")
    }

    #if os(macOS)
    /// The stub `cfprefsd` writes after exit is removed by a cleaner that outlives the process.
    /// It deletes only throwaway plists, whatever it is handed.
    func testTheLateCleanerRemovesOnlyThrowawayPlists() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("throwaway-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let stub = dir.appendingPathComponent("\(ThrowawayDefaults.namespace)music.\(UUID().uuidString).plist")
        let other = dir.appendingPathComponent("io.tonebox.tests.fresh.plist")
        for url in [stub, other] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("{}".utf8)))
        }

        ThrowawayDefaults.removeLater([stub.path, other.path], after: 1)

        let deadline = Date().addingTimeInterval(10)
        while fm.fileExists(atPath: stub.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(fm.fileExists(atPath: stub.path), "the cleaner should delete the stub")
        XCTAssertTrue(fm.fileExists(atPath: other.path), "a path that is not a throwaway plist must survive")
    }
    #endif

    /// No test builds its own UUID-named suite. TBX-7443 fixed one prefix and 57 more kept
    /// leaking (45,310 plists) because nothing stopped a new prefix. So this reads every test
    /// source in the repository and fails on a UUID-bearing string handed to
    /// `UserDefaults(suiteName:` or stored in anything called `suite…`. Route the
    /// name through `ThrowawayDefaults.name(_:)` instead.
    func testNoTestMintsItsOwnUUIDSuite() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BatonSubsonicKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BatonSubsonicKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repository root
        let uuidLiteral = #""(?:[^"\\\n]|\\.)*\\\(UUID\("#
        let direct = try NSRegularExpression(pattern: #"UserDefaults\(suiteName:\s*"# + uuidLiteral)
        let stored = try NSRegularExpression(
            pattern: #"(?i)\b\w*suite\w*\s*(?::\s*String\s*)?=\s*"# + uuidLiteral)

        var scanned = 0
        var offences: [String] = []
        for file in try Self.testSources(under: repo) {
            scanned += 1
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard direct.firstMatch(in: line, range: range) != nil
                        || stored.firstMatch(in: line, range: range) != nil else { continue }
                let relative = file.path.replacingOccurrences(of: repo.path + "/", with: "")
                offences.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        // 200-odd test files as of 2026-09-25: a count this low means a root moved, not that
        // the problem went away.
        XCTAssertGreaterThan(scanned, 150, "Scanned only \(scanned) test sources")
        XCTAssertEqual(offences, [], "\n" + offences.joined(separator: "\n")
            + "\n\nUse ThrowawayDefaults.name(\"<label>\") so the suite is removed at exit.")
    }

    /// Every `.swift` file under a test directory: the packages, both apps, the gateway and
    /// the parked watch app. This file is excluded, since it names the pattern it bans.
    private static func testSources(under repo: URL) throws -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        let packages = repo.appendingPathComponent("Packages")
        for entry in (try? fm.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil)) ?? [] {
            roots.append(entry.appendingPathComponent("Tests"))
        }
        for path in ["app/Tests", "ios/Tests", "gateway/Tests", "watch"] {
            roots.append(repo.appendingPathComponent(path))
        }
        var found: [URL] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            let files = fm.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ThrowawayDefaultsTests.swift" }
            found += files ?? []
        }
        return found
    }

    /// The exit hook empties each suite this process made and deletes its file.
    func testRemoveAllDeletesTheSuitesThisProcessMade() throws {
        let (name, defaults) = ThrowawayDefaults.suite("guard")
        XCTAssertTrue(name.hasPrefix(ThrowawayDefaults.namespace + "guard."))
        defaults.set("x", forKey: "k")
        defaults.synchronize()
        let url = ThrowawayDefaults.plistURL(name, in: ThrowawayDefaults.preferencesDirectory)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the suite should reach disk")

        ThrowawayDefaults.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(UserDefaults(suiteName: name)?.object(forKey: "k"))
    }
}
