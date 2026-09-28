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
    /// The argument list is matched by balancing parentheses, not by a regex. Attribute
    /// arguments nest, so `@available(*, deprecated, message: "use foo(bar:)")` has to count as
    /// one attribute; the old non-nesting `\([^)]*\)` stopped at the inner paren and exempted
    /// exactly the attributes with the most to say. Its replacement, a greedy `\(.*\)`, ran from
    /// the attribute's `(` to the *last* `)` on the line, so a whole declaration such as
    /// `@AppStorage(key) private var port = Int(defaultPort)` read as a bare attribute, and a
    /// doc comment for the next property made it fail a release gate. Balancing ends
    /// the attribute at its own closing paren, and anything after that is a declaration.
    /// Parentheses inside string literals are skipped, so a message like `"(see above"` cannot
    /// unbalance the count.
    static func isAttributeOnly(_ line: String) -> Bool {
        let chars = Array(line)
        guard chars.first == "@", chars.count > 1,
              chars[1] == "_" || chars[1].isLetter else { return false }
        var index = 2
        while index < chars.count, chars[index] == "_" || chars[index].isLetter || chars[index].isNumber {
            index += 1
        }
        if index == chars.count { return true }             // `@Name`
        guard chars[index] == "(" else { return false }     // `@Name something`: a declaration

        var depth = 0
        var inString = false
        while index < chars.count {
            let char = chars[index]
            if inString {
                if char == "\\" { index += 1 }              // skip the escaped character
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "(" {
                depth += 1
            } else if char == ")" {
                depth -= 1
                if depth == 0 { return index == chars.count - 1 }
            }
            index += 1
        }
        return false                                        // unclosed: not a bare attribute
    }

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
            offences += Self.offences(in: lines, file: url.lastPathComponent)
        }

        XCTAssertEqual(offences, [], "\n" + offences.joined(separator: "\n")
            + "\n\nMove the attribute so it touches its own declaration.")
    }

    /// Every attribute in `lines` that sits alone with a comment as the next non-blank line.
    static func offences(in lines: [String], file: String) -> [String] {
        var offences: [String] = []
        for (index, line) in lines.enumerated() {
            let attribute = line.trimmingCharacters(in: .whitespaces)
            guard isAttributeOnly(attribute) else { continue }

            var next = index + 1
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                next += 1
            }
            guard next < lines.count,
                  isComment(lines[next].trimmingCharacters(in: .whitespaces)) else { continue }

            offences.append("\(file):\(index + 1): \(attribute) is followed by "
                            + "a comment, so it binds to whatever that comment documents")
        }
        return offences
    }

    /// The rule can still fail. The shapes the real bugs had must each be reported, or a
    /// loosened check would pass the whole-tree scan by never matching anything.
    func testTheStrandedShapesStillFail() {
        let stranded: [(String, [String])] = [
            // TBX-5234: @MainActor left above a type inserted underneath it.
            ("RemoteMemoryStore", ["@MainActor", "/// Keeps what the friend was told.", "enum FriendLedgerStore {}"]),
            // TBX-5252 / S-F25: an attribute sandwiched between two halves of a doc comment.
            ("ClippingStore", ["    /// Bring local state into line.", "    @discardableResult",
                               "    /// `deleted` carries the playable ids.", "    func reconcile() {}"]),
            ("StreamingPlaybackController", ["    @MainActor", "", "    // resolves a download URL",
                                             "    static func resolveDownloadURL() {}"]),
            // Nested arguments must still count as one bare attribute.
            ("Nested", ["@available(*, deprecated, message: \"use foo(bar:)\")", "/// Old API.", "func old() {}"]),
        ]
        for (file, lines) in stranded {
            XCTAssertEqual(Self.offences(in: lines, file: file).count, 1, "\(file) should be reported")
        }
    }

    /// A complete one-line declaration whose initializer ends in `)` is not a bare attribute,
    /// even with the next property's doc comment right below it (TBX-7324, the 0.19.6 gate).
    func testAOneLineDeclarationEndingInAParenIsNotStranded() {
        let lines = [
            "    @AppStorage(BatonMCPConstants.preferredPortDefaultsKey) private var preferredPort = Int(BatonMCPConstants.defaultPort)",
            "    /// Whether the server is running.",
            "    @State private var running = false",
        ]
        XCTAssertEqual(Self.offences(in: lines, file: "MCPSettings"), [])
        XCTAssertFalse(Self.isAttributeOnly("@Attr(x) let y = f()"))
        XCTAssertFalse(Self.isAttributeOnly("@Attr(\"(\") var y = g()"))
        XCTAssertTrue(Self.isAttributeOnly("@Attr(\")\")"))
        XCTAssertTrue(Self.isAttributeOnly("@objc"))
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
