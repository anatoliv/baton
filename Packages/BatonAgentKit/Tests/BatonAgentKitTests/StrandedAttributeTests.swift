import XCTest

/// An attribute that has drifted away from the declaration it was written for.
///
/// Swift skips blank lines and comments between an attribute and a declaration, so
/// `@MainActor` on its own line binds to whatever declaration comes next — even one inserted
/// underneath it months later, carrying its own doc comment. That is exactly what happened in
/// `RemoteMemoryStore.swift`: `@MainActor` was written above the class, `FriendLedgerStore` was
/// added between the two, and the attribute silently moved onto an enum whose only member is
/// `static` and does nothing with it, while the class holding the mutable state lost it
///. Nothing went red, because the class is non-`Sendable` and the compiler was
/// already refusing to let it cross isolation domains at each use site — so the isolation
/// stayed real while the declaration of it was gone.
///
/// It is invisible in review for the same reason it was invisible in the compiler: the file
/// reads correctly top to bottom, and only the *order* of two blocks is wrong. So this reads
/// the sources instead.
///
/// The rule is textual and deliberately narrow — an attribute alone on a line, with a comment
/// as the next thing after it. A comment above a declaration documents that declaration, so an
/// attribute sitting above one is either stranded (this bug) or, at best, written on the wrong
/// side of the documentation and one insert away from becoming this bug.
///
/// It used to scan only `Sources/BatonAgentKit`: 19 files of the 316 this repo compiles, on the
/// argument that the bug had been found there. Running its own rule over the whole tree turned
/// up two more, both in `BatonPlaybackKit` and both of the "one insert away" kind — in
/// `StreamingPlaybackController` an insert had already happened and the doc comment for
/// `resolveStreamURL` was left describing `resolveDownloadURL`. A guard that reads 6% of the
/// code is not a guard; it is a record of where somebody last looked. (TBX-5317, S-F25)
final class StrandedAttributeTests: XCTestCase {
    /// `@Name` or `@Name(...)`, alone on the line. Anything else on the line means the
    /// attribute is already part of a complete declaration and cannot drift.
    ///
    /// The parenthesised part is `\(.*\)` rather than `\([^)]*\)` because attribute arguments
    /// nest: `@available(*, deprecated, message: "use foo(bar:)")` closes an inner paren and the
    /// non-nesting form stopped matching at it, so exactly the attributes with the most to say
    /// were the ones exempt from the rule.
    private static let attributeOnly = try! NSRegularExpression(
        pattern: #"^@[A-Za-z_][A-Za-z0-9_]*(\(.*\))?$"#)

    /// Any comment, not just `///`. A `//` line or a `/** */` block between an attribute and a
    /// declaration strands it identically; Swift skips all three. Neither form appears in the
    /// tree today, so widening this costs nothing now and covers the next one.
    private static func isComment(_ line: String) -> Bool {
        line.hasPrefix("//") || line.hasPrefix("/*")
    }

    func testNoAttributeIsSeparatedFromItsDeclarationByADocComment() throws {
        let sources = try Self.swiftSources()
        // 316 files as of 2026-09-09. The old bound was 10, which the single-package scan met
        // with 19 — so the number is only useful if it is close enough to the truth to notice a
        // source root going missing.
        XCTAssertGreaterThan(sources.count, 200,
                             "Found \(sources.count) sources — a source root has moved, not the problem gone")

        var offences: [String] = []
        for url in sources {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let attribute = line.trimmingCharacters(in: .whitespaces)
                let range = NSRange(attribute.startIndex..., in: attribute)
                guard Self.attributeOnly.firstMatch(in: attribute, range: range) != nil else { continue }

                var next = index + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                    next += 1
                }
                guard next < lines.count,
                      Self.isComment(lines[next].trimmingCharacters(in: .whitespaces)) else { continue }

                offences.append("\(url.lastPathComponent):\(index + 1): \(attribute) is followed by "
                                + "a comment, so it binds to whatever that comment documents")
            }
        }

        XCTAssertEqual(offences, [], "\n" + offences.joined(separator: "\n")
            + "\n\nMove the attribute so it touches its own declaration.")
    }

    /// Every `.swift` file this repository ships, across all five source trees.
    ///
    /// Test sources are excluded on purpose: a test that plants the very shape being banned, in
    /// order to prove the rule fires, must not fail the rule. Nothing else is excluded, and a
    /// root that stops existing is caught by the count assertion above rather than passing
    /// quietly as zero files.
    private static func swiftSources() throws -> [URL] {
        // …/Packages/BatonAgentKit/Tests/BatonAgentKitTests/StrandedAttributeTests.swift → repo
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // BatonAgentKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // BatonAgentKit (package root)
            .deletingLastPathComponent()      // Packages
            .deletingLastPathComponent()      // repository root

        let fm = FileManager.default
        var roots: [URL] = []
        // Every package's Sources, discovered rather than listed, so a package added later is
        // covered without anyone remembering this file.
        let packages = repo.appendingPathComponent("Packages")
        for entry in (try? fm.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil)) ?? [] {
            let sources = entry.appendingPathComponent("Sources")
            if fm.fileExists(atPath: sources.path) { roots.append(sources) }
        }
        // The four trees outside Packages: files both apps compile, the gateway, and the three
        // app targets. `watch` is here too, parked or not, since it compiles the shared code.
        for path in ["Shared", "gateway/Sources", "app/Sources", "ios/Sources", "watch"] {
            let url = repo.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) { roots.append(url) }
        }
        XCTAssertFalse(roots.isEmpty, "No source root exists under \(repo.path)")

        var found: [URL] = []
        for root in roots {
            let enumerated = fm.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
            found += try XCTUnwrap(enumerated, "Couldn't enumerate \(root.path)")
        }
        return found.filter { !$0.path.contains("/Tests/") }
    }
}
