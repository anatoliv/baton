@testable import BatonShareKit
import Foundation
import XCTest

final class ShareLedgerTests: XCTestCase {
    func record(_ id: String, expires: TimeInterval = 86400) -> ShareLedger.Record {
        ShareLedger.Record(id: id, link: "https://batonmusic.app/s/\(id)#k", songID: "song-\(id)", title: "T\(id)",
                           artist: "A", isPrivate: false, createdAt: Date(), expiresAt: Date() + expires)
    }

    func summary(_ id: String, status: ShareStatus, plays: Int = 0) -> ShareSummary {
        var stats = ShareStats()
        stats.plays = plays
        return ShareSummary(id: id, status: status, createdAt: ShareDate.string(Date()),
                            expiresAt: ShareDate.string(Date(timeIntervalSince1970: 2_000_000_000)),
                            playCap: 100, preview: nil, stats: stats, reactions: [])
    }

    func testHeldShareIsNotCountedAsPlayableEvenBeforeOriginalExpiry() {
        var ledger = ShareLedger()
        var held = record("held")
        var owned = summary("held", status: .ready)
        owned.actionRequired = "This link is disabled for review."
        held.summary = owned
        ledger.add(held)
        XCTAssertFalse(held.isLive())
        XCTAssertTrue(ledger.records.filter { $0.isLive() }.isEmpty)
    }

    func testHeldRecordRemainsManageableAfterOriginalExpiryButRevokedDoesNot() throws {
        var ledger = ShareLedger()
        ledger.add(record("held", expires: -10))
        var owned = summary("held", status: .ready)
        owned.expiresAt = ShareDate.string(Date(timeIntervalSince1970: 100))
        owned.actionRequired = "Preserved for review; remaining lifetime is paused."
        ledger.merge([owned])
        let decoded = try JSONDecoder().decode(ShareLedger.self, from: JSONEncoder().encode(ledger))
        let held = try XCTUnwrap(decoded.records.first)
        XCTAssertTrue(held.isHeldForReview)
        XCTAssertFalse(held.isLive())
        owned.status = .revoked
        ledger.update(owned)
        XCTAssertFalse(try XCTUnwrap(ledger.records.first).isHeldForReview)
    }

    func testNewestFirstAndNoDuplicates() {
        var ledger = ShareLedger()
        ledger.add(record("a"))
        ledger.add(record("b"))
        ledger.add(record("a"))
        XCTAssertEqual(ledger.records.map(\.id), ["a", "b"])
    }

    func testMergeTakesStatsFromTheServerAndKeepsTheLink() {
        var ledger = ShareLedger()
        ledger.add(record("live"))
        ledger.add(record("gone", expires: -10))
        ledger.add(record("missing-but-live"))
        ledger.merge([summary("live", status: .ready, plays: 4)])
        XCTAssertEqual(ledger.records.map(\.id).sorted(), ["live", "missing-but-live"],
                       "an ended share the server no longer lists is dropped; a live one is kept")
        let live = ledger.records.first { $0.id == "live" }!
        XCTAssertEqual(live.summary?.stats.plays, 4)
        XCTAssertEqual(live.link, "https://batonmusic.app/s/live#k")
        XCTAssertEqual(live.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))

        ledger.update(summary("live", status: .revoked))
        XCTAssertEqual(ledger.records.first { $0.id == "live" }?.status, .revoked)
        XCTAssertFalse(ledger.records.first { $0.id == "live" }!.isLive())
    }

    func testFailuresQueueUpToTheSpecLimitAndClearWhenTaken() {
        var ledger = ShareLedger()
        for _ in 0 ..< 12 { ledger.noteFailure("network") }
        ledger.noteFailure("invented")
        XCTAssertEqual(ledger.pendingFailures.count, ShareLimits.maxRecentFailures)
        XCTAssertEqual(ledger.pendingFailures.last?.reason, "other", "unknown reasons are reported as other")
        XCTAssertEqual(ledger.takeFailures().count, 10)
        XCTAssertEqual(ledger.pendingFailures, [])
    }

    func testSavesPrivatelyAndSurvivesACorruptFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)/shares.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = ShareLedger()
        ledger.add(record("a"))
        ledger.noteFailure("transcode")
        try ledger.save(to: url)
        XCTAssertEqual(ShareLedger.load(from: url), ledger)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "the file holds every link's key")
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(ShareLedger.load(from: url), ShareLedger())
    }

    func testAnUnreadableLedgerIsKeptAsideBeforeTheNextSaveReplacesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("shares.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        func aside() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("shares.json.corrupt-") }
        }
        XCTAssertEqual(ShareLedger.load(from: url), ShareLedger(), "no ledger yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "and nothing set aside for it")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unreadable = Data(#"{"records":[{"id":"a","link":"https://batonmusic.app/s/a#only-here""#.utf8)
        try unreadable.write(to: url)
        XCTAssertEqual(ShareLedger.load(from: url), ShareLedger())
        XCTAssertEqual(ShareLedger.load(from: url), ShareLedger(), "a second open finds nothing new to set aside")
        var fresh = ShareLedger()
        fresh.add(record("b"))
        try fresh.save(to: url)

        let kept = try aside()
        XCTAssertEqual(kept.count, 1)
        let copy = try XCTUnwrap(kept.first)
        XCTAssertEqual(try Data(contentsOf: copy), unreadable, "the only copy of those keys survives the save")
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "the copy holds link keys too")
        XCTAssertEqual(ShareLedger.load(from: url), fresh)
    }

    func testTypedNamespacesPreserveSameIDKeysAndHeldMixtapeOnReopen() throws {
        var ledger = ShareLedger()
        let single = record("same")
        var multi = record("same", expires: -10)
        multi.kind = .mixtape; multi.songIDs = ["second", "first"]
        multi.link = "https://batonmusic.app/m/same#different-key"
        ledger.add(single); ledger.add(multi)
        XCTAssertEqual(ledger.records.count, 2)
        var held = summary("same", status: .ready, plays: 9)
        held.expiresAt = ShareDate.string(Date(timeIntervalSince1970: 100))
        held.actionRequired = "Preserved for review"
        let typed = MixtapeSummary(share: held, trackCount: 2,
            reviewDeadline: "2030-01-01T00:00:00Z", pausedLifetimeSeconds: 3600)
        ledger.merge([summary("same", status: .ready, plays: 3)])
        ledger.mergeMixtapes([typed])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-kinds-" + UUID().uuidString).appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ledger.save(to: url)
        var reopened = ShareLedger.load(from: url)
        let song = try XCTUnwrap(reopened.records.first { $0.containerKind == .song })
        let mixtape = try XCTUnwrap(reopened.records.first { $0.containerKind == .mixtape })
        XCTAssertEqual(song.link, single.link); XCTAssertEqual(song.summary?.stats.plays, 3)
        XCTAssertEqual(mixtape.link, multi.link); XCTAssertEqual(mixtape.summary?.stats.plays, 9)
        XCTAssertEqual(mixtape.songIDs, ["second", "first"])
        XCTAssertTrue(mixtape.isHeldForReview); XCTAssertFalse(mixtape.isLive())
        XCTAssertEqual(mixtape.mixtapeSummary?.reviewDeadline, typed.reviewDeadline)
        XCTAssertEqual(mixtape.mixtapeSummary?.pausedLifetimeSeconds, 3600)
        reopened.mergeMixtapes([])
        XCTAssertEqual(reopened.records.count, 2, "a temporarily missing held owner row retains its local key")
        reopened.remove(id: "same")
        XCTAssertEqual(reopened.records.map(\.containerKind), [.mixtape])
        reopened.remove(id: "same", kind: .mixtape)
        XCTAssertTrue(reopened.records.isEmpty)
    }

    func testPresentation() {
        let link = URL(string: "https://batonmusic.app/s/x#k")!
        XCTAssertEqual(SharePresentation.message(title: "Song", artist: "Band", note: " Listen ", link: link),
                       "Listen\n\nSong by Band https://batonmusic.app/s/x#k")
        XCTAssertEqual(SharePresentation.message(title: "Song", artist: "", note: "", link: link),
                       "Song https://batonmusic.app/s/x#k")
        XCTAssertEqual(SharePresentation.peaks([0, 0.5, 1, 0.25], count: 2), [128, 255])
        XCTAssertEqual(SharePresentation.peaks([0, 0, 0], count: 8), [0, 0, 0], "never more buckets than samples")
        XCTAssertEqual(SharePresentation.peaks([], count: 8), [])
        XCTAssertEqual(SharePresentation.peaks((0 ..< 10000).map { Float($0) }, count: 200).count, 200)
        let now = Date()
        XCTAssertEqual(SharePresentation.expiry(now + 6.5 * 86400, now: now), "Expires in 6 days")
        XCTAssertEqual(SharePresentation.expiry(now + 3600 * 3.2, now: now), "Expires in 3 hours")
        XCTAssertEqual(SharePresentation.expiry(now - 1, now: now), "Expired")
        var stats = ShareStats()
        stats.opens = 3
        stats.plays = 2
        XCTAssertEqual(SharePresentation.stats(stats), "Opened 3 · Played 2")
    }
}
