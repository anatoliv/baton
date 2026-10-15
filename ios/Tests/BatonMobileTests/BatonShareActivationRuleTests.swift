import Foundation
import XCTest
@testable import BatonMobile

/// The share extension's NSExtensionActivationRule, read from the extension actually embedded in
/// the app and evaluated the way the share sheet does: "Baton" appears for one
/// document of an importable type or one web page, and not for photos, archives or a pile of files.
@MainActor
final class BatonShareActivationRuleTests: XCTestCase {
    private func rule() throws -> NSPredicate {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL, "the app has a PlugIns folder")
        let extensionBundle = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("BatonShare.appex")),
                                            "BatonShare.appex is embedded in the app")
        XCTAssertEqual(extensionBundle.bundleIdentifier, "io.tonebox.baton.share")
        let attributes = try XCTUnwrap((extensionBundle.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionAttributes"]
            as? [String: Any])
        let format = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String, "the rule is a predicate string")
        return NSPredicate(format: format)
    }

    private func share(_ attachments: [[String]]) -> [String: Any] {
        ["extensionItems": [["attachments": attachments.map { ["registeredTypeIdentifiers": $0] }]]]
    }

    func testImportableDocumentsAndWebPagesActivate() throws {
        let rule = try rule()
        for types in [["com.adobe.pdf"], ["org.idpf.epub-container"], ["public.html"], ["public.plain-text"],
                      ["net.daringfireball.markdown"], ["public.url"], ["com.adobe.pdf", "public.file-url"]] {
            XCTAssertTrue(rule.evaluate(with: share([types])), "\(types) should offer Baton")
        }
        XCTAssertTrue(rule.evaluate(with: share([["public.url"], ["public.plain-text"]])),
                      "a link with its title as text is one page")
        // Every type MobileDocuments.importableTypes accepts is one the rule accepts.
        for type in MobileDocuments.importableTypes {
            XCTAssertTrue(rule.evaluate(with: share([[type.identifier]])), "\(type.identifier) is importable but not shareable")
        }
    }

    func testOtherThingsDoNotActivate() throws {
        let rule = try rule()
        for attachments in [[["public.jpeg"]], [["com.pkware.zip-archive", "public.file-url"]], [["public.file-url"]],
                            [["com.adobe.pdf"], ["com.adobe.pdf"]], [["public.url"], ["public.url"]], []] {
            XCTAssertFalse(rule.evaluate(with: share(attachments)), "\(attachments) should not offer Baton")
        }
    }
}
