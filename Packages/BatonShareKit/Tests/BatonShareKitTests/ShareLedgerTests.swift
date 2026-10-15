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
