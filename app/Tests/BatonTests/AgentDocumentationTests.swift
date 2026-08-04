import XCTest
@testable import Baton

/// The docs describe a tool catalog; the catalog is code. Nothing compared them,
/// so they drifted: `music_get_playlist` and `music_set_crossfade` shipped and
/// went unmentioned in both the bundled help and the public help page for
/// several releases, and the headline count ("28 music operations") was wrong in
/// three places at once.
///
/// A tool an agent can call but nobody documented is a feature that effectively
/// does not exist, so this compares them on every build.
@MainActor
final class AgentDocumentationTests: XCTestCase {
    /// The repo-root guides are the canonical copies — a build phase syncs them
    /// into `Sources/Baton/Resources`, so editing the synced copy is silently
    /// undone. Read the source of truth, not the copy.
    private func repoFile(_ name: String) throws -> String {
        // …/app/Tests/BatonTests/ThisFile.swift → repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BatonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var publishedToolNames: [String] {
        BatonMCPToolCatalog.definitions().compactMap { $0["name"] as? String }
    }

    /// Every tool an agent can call has to be named in the user guide.
    func testEveryShippedToolIsInTheHelpGuide() throws {
        let help = try repoFile("HELP.md")
        let missing = publishedToolNames.filter { !help.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "undocumented in HELP.md: \(missing.sorted()) — add them to the tool catalog tables"
        )
    }

    /// The same catalog is published at baton.tonebox.io/help, and it is what
    /// someone reads *before* installing.
    func testEveryShippedToolIsOnThePublicHelpPage() throws {
        let page = try repoFile("website/help.html")
        let missing = publishedToolNames.filter { !page.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "undocumented in website/help.html: \(missing.sorted())"
        )
    }

    /// The counts are prose, so they rot quietly rather than failing to compile.
    func testTheAdvertisedToolCountMatchesTheCatalog() throws {
        let musicTools = publishedToolNames.filter { $0.hasPrefix("music_") }.count
        for file in ["HELP.md", "README.md", "website/help.html"] {
            let text = try repoFile(file)
            XCTAssertTrue(
                text.contains("\(musicTools) music operations")
                    || text.contains("\(musicTools) `music_*` operations")
                    || text.contains("\(musicTools) <strong>music operations")
                    || text.contains("<strong>\(musicTools) music operations</strong>"),
                "\(file) doesn't state the real count of \(musicTools) music_* tools"
            )
        }
    }

    /// Agent mode is the one setting that changes what leaves the machine, so
    /// the promise has to be stated wherever the feature is described — and it
    /// must no longer claim, unconditionally, that the library never travels.
    func testThePrivacyDifferenceIsDocumentedWhereverAgentModeIs() throws {
        for file in ["HELP.md", "FAQ.md", "website/help.html"] {
            let text = try repoFile(file)
            XCTAssertTrue(
                text.lowercased().contains("look around"),
                "\(file) never mentions agent mode"
            )
        }
        // The old unconditional promise. It was true of single-shot mode only,
        // and shipping it next to agent mode would make it a lie.
        let help = try repoFile("HELP.md")
        XCTAssertFalse(
            help.contains("never your library, your server credentials"),
            "HELP.md still carries the pre-agent-mode privacy claim"
        )
    }
}
