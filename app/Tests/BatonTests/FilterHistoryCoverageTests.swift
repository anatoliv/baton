import Foundation
import Testing
@testable import BatonPlaybackKit

/// `FilterHistory.allKeys` must name every screen that actually keeps filter history.
///
/// The list is load-bearing in two places that both fail silently when it is short:
/// Settings → "Clear filter history" clears only the listed keys, and
/// `PreferenceSync.mergedKeys` syncs only the listed keys. A screen missing from it keeps
/// recording your filters forever and carries them to no other device — with no error, no
/// warning, and nothing in the UI that looks wrong.
///
/// It had drifted to six entries while sixteen screens were writing history, so ten screens'
/// worth of filter history was unclearable and unsynced. Hand-maintained registries drift;
/// this reads the call sites instead.
@Suite("Filter history coverage")
struct FilterHistoryCoverageTests {
    /// …/app/Tests/BatonTests/ThisFile.swift → repo root
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(under relativePath: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(relativePath)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Pull the string literal out of every `historyKey:` / `filterHistoryKey:` argument.
    /// Handles the conditional form (`searchMode ? "search" : "liked"`) by taking every
    /// literal up to the end of the line.
    private func keysInUse() -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"(?:filterHistoryKey|historyKey):\s*([^\n]*)"#)
        let literal = try! NSRegularExpression(pattern: #""([A-Za-z][A-Za-z0-9]*)""#)
        var found: Set<String> = []

        for file in swiftFiles(under: "app/Sources") {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let full = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: full) {
                guard let argRange = Range(match.range(at: 1), in: source) else { continue }
                let argument = String(source[argRange])
                // `nil` disables history for that field — not a key.
                guard !argument.trimmingCharacters(in: .whitespaces).hasPrefix("nil") else { continue }
                let argFull = NSRange(argument.startIndex..., in: argument)
                for hit in literal.matches(in: argument, range: argFull) {
                    if let r = Range(hit.range(at: 1), in: argument) { found.insert(String(argument[r])) }
                }
            }
        }
        return found
    }

    @Test("Every screen that records filter history is declared in allKeys")
    func everyKeyDeclared() {
        let used = keysInUse()
        // A scan that finds nothing would pass this test forever after a refactor.
        #expect(used.count >= 10, "expected to find the filter fields, found \(used.count): \(used.sorted())")

        let declared = Set(FilterHistory.allKeys)
        let missing = used.subtracting(declared).sorted()
        #expect(
            missing.isEmpty,
            """
            These screens record filter history but are absent from FilterHistory.allKeys: \
            \(missing.joined(separator: ", ")).
            Their history is never cleared by Settings and never syncs between devices.
            """
        )
    }

    @Test("allKeys names no screen that no longer exists")
    func noStaleKeys() {
        let stale = Set(FilterHistory.allKeys).subtracting(keysInUse()).sorted()
        #expect(
            stale.isEmpty,
            "FilterHistory.allKeys lists \(stale.joined(separator: ", ")), which no filter field uses."
        )
    }

    @MainActor
    @Test("Every declared key is synced, not just cleared")
    func declaredKeysSync() {
        for key in FilterHistory.allKeys {
            #expect(
                PreferenceSync.mergedKeys.contains(FilterHistory.storageKey(key)),
                "\(key) is cleared by Settings but never syncs between devices"
            )
        }
    }
}
