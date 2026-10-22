import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Baton

/// Finder's Open With > Baton and the "Make an Audiobook with Baton" service (spec §9,
/// An internal task). Both hand files to `BatonCommandRouter.openDocuments`, which sends a readable one
/// to the import sheet the way File > Import Document… does. The hand-over itself needs Finder;
/// what is tested is where each kind of hand-over goes, the service's pasteboard reading, and the
/// declarations in the built Info.plist that keep Baton from ever becoming a default app.
@MainActor
final class DocumentOpenWithTests: XCTestCase {
    private let pdf = URL(fileURLWithPath: "/tmp/tbx-10950/Room with a View.pdf")
    private let markdown = URL(fileURLWithPath: "/tmp/tbx-10950/notes.md")
    private let rtf = URL(fileURLWithPath: "/tmp/tbx-10950/letter.rtf")
    private let swift = URL(fileURLWithPath: "/tmp/tbx-10950/main.swift")

    override func tearDown() {
        ScreenTextReader.shared.onDocumentFiles = nil
        super.tearDown()
    }

    // MARK: - Routing

    func testASupportedFileOpensTheImportSheetOverBooks() {
        let router = BatonCommandRouter()
        let route = router.openDocuments([pdf], documentsEnabled: true)
        XCTAssertEqual(route, .importSheet(pdf, others: 0))
        XCTAssertEqual(router.pendingDocumentImport, pdf, "the same hand-off Import Document… makes")
        XCTAssertEqual(router.pendingTab, .books, "imports land in Books (TBX-11018)")
        XCTAssertNil(DocumentLibrary.openAlert(for: route), "no alert when the sheet opens")
        XCTAssertNil(DocumentLibrary.othersNotice(opened: pdf, others: 0))
    }

    func testAnUnsupportedFileImportsNothingAndSaysWhatBatonReads() {
        let router = BatonCommandRouter()
        let route = router.openDocuments([rtf], documentsEnabled: true)
        XCTAssertEqual(route, .unsupported(rtf))
        XCTAssertNil(router.pendingDocumentImport)
        XCTAssertNil(router.pendingTab)
        let alert = DocumentLibrary.openAlert(for: route)
        XCTAssertEqual(alert?.title, "Baton can't read letter.rtf")
        XCTAssertEqual(alert?.message,
                       "Baton makes audiobooks from PDF, EPUB, web pages saved as HTML, plain text and Markdown files.")
    }

    func testWithDocumentsOffNothingIsImportedAndTheAlertSaysWhereToTurnItOn() {
        let router = BatonCommandRouter()
        let route = router.openDocuments([pdf], documentsEnabled: false)
        XCTAssertEqual(route, .documentsOff)
        XCTAssertNil(router.pendingDocumentImport, "nothing reaches the import sheet")
        XCTAssertNil(router.pendingTab)
        let alert = DocumentLibrary.openAlert(for: route)
        XCTAssertEqual(alert?.title, "Documents is turned off")
        XCTAssertTrue(alert?.message.contains("turn on Documents in Settings, under Speech") == true,
                      "the Mac's switch is under Settings > Speech: \(alert?.message ?? "nil")")
    }

    func testSeveralFilesOpenTheFirstReadableOneAndCountTheRest() {
        let router = BatonCommandRouter()
        let route = router.openDocuments([rtf, markdown, pdf], documentsEnabled: true)
        XCTAssertEqual(route, .importSheet(markdown, others: 2), "the first file Baton reads, not the first file")
        XCTAssertEqual(router.pendingDocumentImport, markdown)
        XCTAssertEqual(DocumentLibrary.othersNotice(opened: markdown, others: 2),
                       "Opened notes.md. Baton imports one document at a time, so open the other 2 files after this one.")
        XCTAssertEqual(DocumentLibrary.othersNotice(opened: markdown, others: 1),
                       "Opened notes.md. Baton imports one document at a time, so open the other file after this one.")
    }

    func testALinkIsNotAFileHandOver() {
        let router = BatonCommandRouter()
        XCTAssertEqual(router.openDocuments([URL(string: "baton://player")!], documentsEnabled: true), .none,
                       "baton:// links keep their own handler")
        XCTAssertNil(router.pendingDocumentImport)
    }

    func testPlainTextThatIsCodeIsRefusedNotImported() {
        // Swift source conforms to public.plain-text, so Finder offers Baton for it. Opening one
        // must say Baton cannot read it rather than import code as a book.
        XCTAssertEqual(DocumentLibrary.route(opening: [swift], documentsEnabled: true), .unsupported(swift))
    }

    // MARK: - Finder's hand-over of several files

    /// `onOpenURL` passes on only the first file Finder hands over; the rest are read from the
    /// open-documents Apple event it answers.
    func testEveryFileOfAnOpenDocumentsEventIsRead() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: pdf), at: 1)
        list.insert(NSAppleEventDescriptor(fileURL: markdown), at: 2)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(list, forKeyword: keyDirectObject)
        XCTAssertEqual(BatonAppDelegate.fileURLs(inOpenEvent: event).map(\.path), [pdf.path, markdown.path])

        let other = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertEqual(BatonAppDelegate.fileURLs(inOpenEvent: other), [], "a baton:// link event carries no files")
        XCTAssertEqual(BatonAppDelegate.fileURLs(inOpenEvent: nil), [])
    }

    // MARK: - The service

    func testTheServiceHandsItsFilesToTheHook() {
        let pasteboard = NSPasteboard(name: .init("tbx-10950-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([pdf as NSURL, markdown as NSURL])
        var received: [URL] = []
        ScreenTextReader.shared.onDocumentFiles = { received = $0 }
        var error: NSString?
        ScreenTextReader.shared.makeAudiobook(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertEqual(received.map(\.path), [pdf.path, markdown.path])
    }

    func testTheServiceWithNoFilesReportsToTheSendingApp() {
        let pasteboard = NSPasteboard(name: .init("tbx-10950-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        var called = false
        ScreenTextReader.shared.onDocumentFiles = { _ in called = true }
        var error: NSString?
        ScreenTextReader.shared.makeAudiobook(pasteboard, userData: nil, error: &error)
        XCTAssertFalse(called)
        XCTAssertEqual(error as String?, "Select a document in Finder first, then choose Make an Audiobook with Baton.")
    }

    // MARK: - The built Info.plist

    private let declared = ["com.adobe.pdf", "org.idpf.epub-container", "public.html",
                            "public.plain-text", "net.daringfireball.markdown"]

    func testEveryDocumentTypeIsAViewerAtAlternateRank() throws {
        let types = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        var seen: [String] = []
        for type in types {
            XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer")
            XCTAssertEqual(type["LSHandlerRank"] as? String, "Alternate",
                           "Alternate keeps Baton out of the default app for \(type["CFBundleTypeName"] ?? "?")")
            seen += type["LSItemContentTypes"] as? [String] ?? []
        }
        XCTAssertEqual(Set(seen), Set(declared))
    }

    func testTheFileServiceSendsTheSameTypesAndEveryOneIsImportable() throws {
        let services = try XCTUnwrap(Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]])
        let service = try XCTUnwrap(services.first { $0["NSMessage"] as? String == "makeAudiobook" })
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], "Make an Audiobook with Baton")
        XCTAssertEqual(Set(service["NSSendFileTypes"] as? [String] ?? []), Set(declared))
        XCTAssertTrue(ScreenTextReader.shared.responds(to: Selector(("makeAudiobook:userData:error:"))))
        let importable = Set(DocumentLibrary.importableTypes.map(\.identifier))
        for identifier in declared {
            XCTAssertTrue(importable.contains(identifier), "\(identifier) is declared but Import Document… refuses it")
        }
    }
}
