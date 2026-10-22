import BatonShareKit
import Foundation
import XCTest
@testable import BatonMobile

/// The share extension's hand-off to the app: what the extension's writer leaves in
/// the App Group inbox, the app's reader takes out exactly once, oldest first, and anything stale,
/// half-written or malformed is removed instead of offered. A throwaway folder stands in for the
/// App Group container.
@MainActor
final class ShareInboxTests: XCTestCase {
    private var work: URL!
    private var inbox: PendingShareInbox!
    private var staging: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("share-inbox-\(UUID().uuidString)", isDirectory: true)
        inbox = PendingShareInbox(root: work.appendingPathComponent("PendingImports", isDirectory: true))
        staging = work.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func source(_ name: String, _ text: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func entries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inbox.root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: - A Baton share link is not a page (TBX-1000000505 B-6)

    /// Its fragment is the song's key. As a "page" it was written to the App Group, used as the
    /// document's file name and sent to the gateway by Send to my Mac.
    func testABatonShareLinkIsRefusedAndNothingIsWritten() throws {
        for raw in ["https://batonmusic.app/s/AbCdEf123456#k3yk3yk3yk3yk3yk3yk3yk3yk3yk3yk3yk3yk3yk3yk",
                    "https://www.batonmusic.app/m/AbCdEf123456#key", "https://baton.tonebox.io/b/AbCdEf123456#key",
                    "baton://share/AbCdEf123456#key"] {
            let link = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try inbox.writeLink(link), raw) { error in
                guard case PendingShareInbox.WriteError.batonShareLink = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(entries(), [], "nothing with a key in it reaches the App Group")
        XCTAssertFalse(PendingShareInbox.isBatonShareLink(try XCTUnwrap(URL(string: "https://batonmusic.app/help"))),
                       "the site's other pages are ordinary pages")
    }

    /// The extension cannot link BatonShareKit, so it keeps its own copy of the hosts; this is the
    /// check that the two agree with what the app itself opens as a share.
    func testTheShareLinkRuleAgreesWithShareKit() throws {
        XCTAssertEqual(PendingShareInbox.batonShareHosts, ShareLink.hosts)
        let key = Base64URL.encode(Data(repeating: 7, count: ShareCrypto.keyLength))
        let id = Base64URL.encode(Data(repeating: 1, count: 16))
        for path in ["s", "m", "b"] {
            for host in ShareLink.hosts {
                let link = try XCTUnwrap(URL(string: "https://\(host)/\(path)/\(id)#\(key)"))
                XCTAssertEqual(PendingShareInbox.isBatonShareLink(link), ShareInvitation(url: link) != nil, link.absoluteString)
            }
        }
    }

    func testAPageIsKeptWithoutItsFragment() throws {
        let marker = try inbox.writeLink(try XCTUnwrap(URL(string: "https://example.com/essays/one?ref=share#comments")))
        XCTAssertEqual(marker.link, "https://example.com/essays/one?ref=share")
    }

    /// A share link an older extension already wrote is removed rather than offered.
    func testAShareLinkMarkerFromBeforeIsRemoved() throws {
        let id = UUID().uuidString
        let folder = inbox.root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = PendingShareInbox.Marker(id: id, kind: .link, originalName: "batonmusic.app",
                                              created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                                              link: "https://batonmusic.app/s/AbCdEf123456#key")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: folder.appendingPathComponent(PendingShareInbox.markerName))
        XCTAssertNil(inbox.claimOldest(into: staging))
        XCTAssertEqual(entries(), [])
    }

    /// Import a Link and Open in Baton both end in `offerImport`.
    func testTheAppRefusesAShareLinkAsADocument() throws {
        let model = MobileModel()
        let before = model.pendingDocumentImport
        model.offerImport(try XCTUnwrap(URL(string: "https://batonmusic.app/s/AbCdEf123456#key")))
        XCTAssertEqual(model.pendingDocumentImport, before, "nothing offered for import")
        XCTAssertEqual(model.linkFailure, MobileModel.shareLinkIsNotADocument)
    }

    func testASharedFileIsReadOnceUnderItsOriginalName() throws {
        let marker = try inbox.writeFile(copying: try source("chapter.md", "# One\n\nWords."), originalName: "chapter.md")
        XCTAssertEqual(marker.kind, .file)
        XCTAssertEqual(entries(), [marker.id], "the share waits in the inbox under its id")

        let claimed = try XCTUnwrap(inbox.claimOldest(into: staging))
        XCTAssertEqual(claimed.marker, marker)
        XCTAssertEqual(claimed.url.lastPathComponent, "chapter.md", "the import screen and importer see the original name")
        XCTAssertTrue(claimed.url.path.hasPrefix(staging.path), "the app owns its copy, outside the container")
        XCTAssertEqual(try String(contentsOf: claimed.url, encoding: .utf8), "# One\n\nWords.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.url.deletingLastPathComponent()
            .appendingPathComponent(PendingShareInbox.markerName).path), "the marker does not travel with the file")

        XCTAssertEqual(entries(), [], "claimed means gone from the inbox")
        XCTAssertNil(inbox.claimOldest(into: staging), "a marker is read exactly once")
    }

    func testASharedLinkComesBackAsThePageAddress() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/essays/one?ref=share"))
        let marker = try inbox.writeLink(page)
        XCTAssertEqual(marker.kind, .link)
        XCTAssertEqual(marker.originalName, "example.com")
        let claimed = try XCTUnwrap(inbox.claimOldest(into: staging))
        XCTAssertEqual(claimed.url, page)
        XCTAssertNil(inbox.claimOldest(into: staging))
        XCTAssertThrowsError(try inbox.writeLink(try XCTUnwrap(URL(string: "file:///etc/hosts"))), "only web pages are links")
    }

    func testSharedTextBecomesAPlainTextDocument() throws {
        try inbox.writeText("Selected words.")
        let claimed = try XCTUnwrap(inbox.claimOldest(into: staging))
        XCTAssertEqual(claimed.url.pathExtension, "txt")
        XCTAssertTrue(MobileDocuments.canImport(claimed.url), "the importer accepts what the inbox hands over")
    }

    func testTheOldestShareOpensFirstAndTheRestWait() throws {
        let now = Date()
        let newer = try inbox.writeLink(try XCTUnwrap(URL(string: "https://example.com/b")), now: now.addingTimeInterval(-60))
        let older = try inbox.writeFile(copying: try source("a.txt", "A"), originalName: "a.txt", now: now.addingTimeInterval(-600))
        XCTAssertEqual(inbox.claimOldest(into: staging, now: now)?.marker, older)
        XCTAssertEqual(entries(), [newer.id], "the newer share stays for the next activation")
        XCTAssertEqual(inbox.claimOldest(into: staging, now: now)?.marker, newer)
        XCTAssertNil(inbox.claimOldest(into: staging, now: now))
    }

    func testAStaleShareIsRemovedNotOffered() throws {
        let now = Date()
        try inbox.writeFile(copying: try source("old.pdf", "%PDF"), originalName: "old.pdf",
                            now: now.addingTimeInterval(-PendingShareInbox.maximumAge - 60))
        XCTAssertNil(inbox.claimOldest(into: staging, now: now))
        XCTAssertEqual(entries(), [], "a week-old share is tidied away")
    }

    func testMalformedMarkersAreRemovedAndAValidOneStillOpens() throws {
        let good = try inbox.writeLink(try XCTUnwrap(URL(string: "https://example.com/good")))
        let fileManager = FileManager.default
        func folder(_ name: String) throws -> URL {
            let url = inbox.root.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // Not JSON at all.
        try Data("not json".utf8).write(to: try folder(UUID().uuidString).appendingPathComponent(PendingShareInbox.markerName))
        // No marker: a folder nobody finished.
        _ = try folder(UUID().uuidString)
        // A file marker whose file is missing.
        let missing = UUID().uuidString
        try Data(#"{"version":1,"id":"\#(missing)","kind":"file","originalName":"gone.pdf","created":"2026-10-15T08:00:00Z"}"#.utf8)
            .write(to: try folder(missing).appendingPathComponent(PendingShareInbox.markerName))
        // A marker naming a different folder than its own.
        let elsewhere = try folder(UUID().uuidString)
        try Data(#"{"version":1,"id":"\#(UUID().uuidString)","kind":"link","originalName":"x","created":"2026-10-15T08:00:00Z","link":"https://example.com"}"#.utf8)
            .write(to: elsewhere.appendingPathComponent(PendingShareInbox.markerName))
        // A link marker pointing somewhere that is not a web page, and an unknown kind.
        let local = UUID().uuidString
        try Data(#"{"version":1,"id":"\#(local)","kind":"link","originalName":"x","created":"2026-10-15T08:00:00Z","link":"file:///etc/hosts"}"#.utf8)
            .write(to: try folder(local).appendingPathComponent(PendingShareInbox.markerName))
        let odd = UUID().uuidString
        try Data(#"{"version":1,"id":"\#(odd)","kind":"video","originalName":"x","created":"2026-10-15T08:00:00Z"}"#.utf8)
            .write(to: try folder(odd).appendingPathComponent(PendingShareInbox.markerName))
        XCTAssertEqual(entries().count, 7)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T09:00:00Z"))
        XCTAssertEqual(inbox.claimOldest(into: staging, now: max(now, good.created))?.marker, good)
        XCTAssertEqual(entries(), [], "every malformed share was removed on the way")
    }

    func testAnUnfinishedWriteIsInvisibleUntilAbandoned() throws {
        let incoming = inbox.root.appendingPathComponent(PendingShareInbox.incomingName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        XCTAssertNil(inbox.claimOldest(into: staging), "half a share is never offered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path), "a write in progress is left alone")
        XCTAssertNil(inbox.claimOldest(into: staging, now: Date().addingTimeInterval(PendingShareInbox.abandonedWriteAge + 60)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "an extension killed mid-copy leaves nothing behind")
    }

    func testUnsafeNamesAreFlattenedOrRefused() {
        XCTAssertEqual(PendingShareInbox.safeName("Notes/Draft: one.md"), "Notes-Draft- one.md")
        XCTAssertNil(PendingShareInbox.safeName("../../a/b.pdf"), "a path that climbs out is refused")
        XCTAssertNil(PendingShareInbox.safeName(".hidden"))
        XCTAssertNil(PendingShareInbox.safeName(PendingShareInbox.markerName))
        XCTAssertNil(PendingShareInbox.safeName("   "))
    }

    func testTheAppClaimsThroughMobileDocuments() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/via-app"))
        try inbox.writeLink(page)
        XCTAssertEqual(MobileDocuments.claimSharedImport(from: inbox), page)
        XCTAssertNil(MobileDocuments.claimSharedImport(from: inbox))
        XCTAssertNil(MobileDocuments.claimSharedImport(from: nil), "no App Group, nothing to read")
    }

    /// The extension's confirmation: a page shared from Safari is named by its title,
    /// not by its site; a file keeps its name; a link with no usable title falls back to the host.
    func testTheConfirmationNamesAPageByItsTitle() throws {
        let page = URL(string: "https://www.gutenberg.org/cache/epub/1952/pg1952-images.html")!
        let link = try inbox.writeLink(page)
        XCTAssertEqual(link.originalName, "www.gutenberg.org")

        let title = PendingShareInbox.pageTitle(from: [nil, "  The Yellow Wallpaper  "], link: link.link)
        XCTAssertEqual(PendingShareInbox.confirmation(for: link, pageTitle: title), "Saved “The Yellow Wallpaper” for Baton")

        // The address, the host, several lines of text or nothing at all are not a title.
        XCTAssertNil(PendingShareInbox.pageTitle(from: [page.absoluteString, "www.gutenberg.org", "One\nTwo", "", nil],
                                                 link: link.link))
        XCTAssertNil(PendingShareInbox.pageTitle(from: [String(repeating: "a", count: 201)], link: link.link))
        XCTAssertEqual(PendingShareInbox.pageTitle(from: ["https://example.com/other", "Real Title"], link: link.link),
                       "Real Title", "the first usable one")
        XCTAssertEqual(PendingShareInbox.confirmation(for: link, pageTitle: nil), "Saved www.gutenberg.org for Baton")

        let file = try inbox.writeFile(copying: try source("Machine_stops.pdf", "%PDF"), originalName: "Machine_stops.pdf")
        XCTAssertEqual(PendingShareInbox.confirmation(for: file, pageTitle: "Some Page"), "Saved Machine_stops.pdf for Baton")
    }
}
