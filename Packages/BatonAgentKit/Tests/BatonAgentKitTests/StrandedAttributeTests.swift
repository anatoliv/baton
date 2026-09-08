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
/// The rule is textual and deliberately narrow — an attribute alone on a line, with a doc
/// comment as the next thing after it. A doc comment always documents the declaration below
/// it, so an attribute sitting above one is either stranded (this bug) or, at best, written
/// on the wrong side of the documentation and one insert away from becoming this bug.
final class StrandedAttributeTests: XCTestCase {
    /// `@Name` or `@Name(...)`, alone on the line. Anything else on the line means the
    /// attribute is already part of a complete declaration and cannot drift.
    private static let attributeOnly = try! NSRegularExpression(
        pattern: #"^@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?$"#)

    func testNoAttributeIsSeparatedFromItsDeclarationByADocComment() throws {
        let sources = try Self.swiftSources()
        XCTAssertGreaterThan(sources.count, 10,
                             "Found almost no sources — the path below has moved, not the problem gone")

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
                      lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("///") else { continue }

                offences.append("\(url.lastPathComponent):\(index + 1): \(attribute) is followed by "
                                + "a doc comment, so it binds to whatever that comment documents")
            }
        }

        XCTAssertEqual(offences, [], "\n" + offences.joined(separator: "\n")
            + "\n\nMove the attribute so it touches its own declaration.")
    }

    /// Every `.swift` file in this package's sources.
    private static func swiftSources() throws -> [URL] {
        // …/Tests/BatonAgentKitTests/StrandedAttributeTests.swift → …/Sources/BatonAgentKit
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // BatonAgentKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // BatonAgentKit (package root)
            .appendingPathComponent("Sources/BatonAgentKit")
        let found = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        return try XCTUnwrap(found, "Couldn't enumerate \(sources.path)")
    }
}
