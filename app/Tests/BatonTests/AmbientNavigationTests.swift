import Foundation
import Testing

/// The music window owns exactly one `NavigationStack`.
///
/// `MusicView` wraps the whole content pane in `NavigationStack(path: $path)`, and every
/// browser pushes into it with `NavigationLink(value:)` plus a `navigationDestination`
/// registered up there. `MusicFoldersView` once built a *second* stack inside that one,
/// and the result was worse than a cosmetic glitch: the sidebar highlight still moved
/// when you clicked another item, but the content pane stayed on Folders forever. The
/// window was stuck until relaunch — and because the selected tab is persisted, a
/// relaunch put you straight back into it.
///
/// Nothing in the suite could see that. It is not a wrong value anywhere; it is a view
/// hierarchy that composes badly, and it type-checks perfectly. The phone never had the
/// bug because its Folders view always used the ambient stack. So the guard is a source
/// check: no view under the music shell may declare a `NavigationStack` except the one
/// that legitimately owns it.
@Suite("Ambient navigation")
struct AmbientNavigationTests {
    /// …/app/Tests/BatonTests/ThisFile.swift → repo root
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BatonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
    }

    /// The single legitimate owner of the stack.
    private static let owner = "MusicView.swift"

    /// Where `Color.hoverTint` is defined — the one file allowed to write the literal.
    private static let tintOwner = "Color+Baton.swift"

    private func musicShellSources() throws -> [URL] {
        let dir = repoRoot.appendingPathComponent("app/Sources/Baton/Shell/Music")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return names.filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    @Test("Only MusicView builds a NavigationStack")
    func singleStack() throws {
        let files = try musicShellSources()
        // A guard that silently matches nothing is worse than no guard: it reports green
        // forever after a directory move.
        #expect(files.count > 10, "expected to be scanning the music shell, found \(files.count) files")

        var offenders: [String] = []
        for file in files {
            let name = file.lastPathComponent
            guard name != Self.owner else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            // Skip comment lines — the podcast views *mention* the ambient stack in prose,
            // and prose is not a second stack.
            let declares = source.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { return false }
                return trimmed.contains("NavigationStack")
            }
            if declares { offenders.append(name) }
        }

        #expect(
            offenders.isEmpty,
            """
            These views build their own NavigationStack inside the one MusicView already \
            provides: \(offenders.joined(separator: ", ")).
            A nested stack swallows sidebar tab switches — the highlight moves, the content \
            pane does not. Push with NavigationLink(value:) and register the destination in \
            MusicView instead.
            """
        )
    }

    /// Hover is one look, expressed once.
    ///
    /// `Color.hoverTint` is the row-hover token. Podcasts, Radio and the Up Next queue each
    /// grew their own literal instead — `Color.secondary.opacity(0.08)` and
    /// `Color.primary.opacity(0.07)` — which read as *nearly* right and so survived every
    /// review. Against the dark scheme this window forces, `secondary` at 0.08 lands around
    /// 0.04 effective: a hover you have to look for. Same class of drift as the nine Shuffle
    /// call sites and the twelve now-playing indicators.
    @Test("Row hover uses the shared tint, never a literal")
    func hoverTintIsShared() throws {
        var offenders: [String] = []
        for file in try musicShellSources() {
            // The token has to be spelled out somewhere; that somewhere is its definition.
            guard file.lastPathComponent != Self.tintOwner else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                // A literal opacity in the same expression as a hover flag is the tell.
                let mentionsHover = trimmed.contains("hover") || trimmed.contains("hovering")
                let isLiteralTint = trimmed.contains("Color.secondary.opacity(")
                    || trimmed.contains("Color.primary.opacity(")
                if mentionsHover && isLiteralTint {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Hard-coded hover tint at: \(offenders.joined(separator: ", ")).
            Use Color.hoverTint so every row in the window highlights identically.
            """
        )
    }

    @Test("MusicView registers a destination for every value its browsers push")
    func destinationsCoverPushedValues() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Sources/Baton/Shell/Music/MusicView.swift"),
            encoding: .utf8
        )
        // A NavigationLink(value:) with no matching destination is a link that does nothing
        // when clicked — silent, and exactly as invisible to the suite as the nested stack was.
        for type in ["NavidromeAlbum", "NavidromeArtist", "NavidromePlaylist", "MusicMix", "NavidromeFolder"] {
            #expect(
                source.contains("navigationDestination(for: \(type).self)"),
                "MusicView has no navigationDestination for \(type) — links pushing it go nowhere"
            )
        }
    }
}
