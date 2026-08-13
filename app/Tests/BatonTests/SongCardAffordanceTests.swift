import Foundation
import Testing

/// Every card that shows a *song* offers the same things.
///
/// Baton draws a song as a card in three unrelated types — `LikedSongGridCell` (Liked,
/// History, Mixes and the detail pages), `SongShelfCard` (Home's song shelves), and the
/// row thumbnail. The like control reached two of them. So a track you could heart in
/// Liked became un-heartable the moment you met it under "Jump back in", and because
/// Home's other shelves are albums — which correctly have no heart — the omission read
/// as deliberate.
///
/// This is the same shape as the nine Shuffle call sites and the twelve now-playing
/// indicators: one concept, several implementations, drifting quietly. Nothing about a
/// missing affordance fails a test or logs a warning; it just isn't there. So the guard
/// is a source check — any type that builds a `MusicMediaCard` from a song must give it
/// a `likeBadge`.
@Suite("Song card affordances")
struct SongCardAffordanceTests {
    /// …/app/Tests/BatonTests/ThisFile.swift → repo root
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func musicShellSources() throws -> [URL] {
        let dir = repoRoot.appendingPathComponent("app/Sources/Baton/Shell/Music")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// The card call and its arguments, from `MusicMediaCard(` to the closing `)` of the
    /// argument list — matched by paren depth so a nested call can't end it early.
    private func cardCalls(in source: String) -> [String] {
        var calls: [String] = []
        var search = source.startIndex
        while let start = source.range(of: "MusicMediaCard(", range: search ..< source.endIndex) {
            var depth = 0
            var index = source.index(before: start.upperBound)   // the opening paren
            var end: String.Index?
            while index < source.endIndex {
                let character = source[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index = source.index(after: index)
            }
            guard let end else { break }
            calls.append(String(source[start.lowerBound ... end]))
            search = source.index(after: end)
        }
        return calls
    }

    /// The type declaration that contains a given call — from the preceding one to the next
    /// — so a card can be classified by what its owner knows about, not merely by which
    /// fields the call happens to interpolate.
    ///
    /// Bounded on the declaration *keyword*, at any visibility. It used to terminate on the
    /// literals `"\nstruct "` and `"\nprivate struct "`, so a `public struct` or a `final
    /// class` beneath a card would have been swallowed into its neighbour's type text and
    /// classified as part of it. Nothing had gone wrong yet; it is the same coupling to
    /// incidental syntax that made two engine tests cry wolf, one target over.
    private static let typeDeclarations = ["struct ", "class ", "enum ", "extension "]

    private func enclosingType(of call: String, in source: String) -> String {
        guard let callRange = source.range(of: call) else { return call }
        let before = source[..<callRange.lowerBound]
        let start = Self.typeDeclarations
            .compactMap { before.range(of: $0, options: .backwards)?.lowerBound }
            .max()
        guard let start else { return call }
        let after = source[start...]
        // The next declaration that begins a line, whatever modifiers precede it.
        let next = after.indices.dropFirst().first { index in
            guard after[after.index(before: index)] == "\n" else { return false }
            let line = after[index...].prefix(while: { $0 != "\n" })
            return Self.typeDeclarations.contains { keyword in
                line.hasPrefix(keyword) || line.contains(" \(keyword)")
            }
        }
        return String(next.map { after[..<$0] } ?? after)
    }

    @Test("Every song card offers the like control")
    func songCardsCanBeLiked() throws {
        var offenders: [String] = []
        var songCards = 0

        for file in try musicShellSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for call in cardCalls(in: source) {
                // A *song* card is one whose enclosing type can name a song. Matching only
                // on `song.` inside the call missed the Downloads card, which builds itself
                // from `item.title`/`item.artist` and reaches the song as `item.song` — so
                // the guard reported clean while that card had no heart. Decide from the
                // whole type, not from the argument list.
                let type = enclosingType(of: call, in: source)
                let isSongCard = type.contains("song.") || type.contains("item.song")
                    || type.contains("NavidromeSong")
                guard isSongCard else { continue }
                songCards += 1
                if !call.contains("likeBadge:") {
                    offenders.append(file.lastPathComponent)
                }
            }
        }

        // A scan that matches nothing would pass forever after a rename.
        #expect(songCards >= 2, "expected to find the song cards, found \(songCards)")
        #expect(
            offenders.isEmpty,
            """
            These song cards have no like control: \(offenders.joined(separator: ", ")).
            A song is likeable wherever you meet it — pass `likeBadge:` to MusicMediaCard.
            """
        )
    }

    /// The badge must be drawn *after* the hover treatment. `hoverPlay` lays a
    /// hit-testable scrim across the whole cover, so a like button placed before it is
    /// covered at exactly the moment it becomes visible — the heart appears on hover, the
    /// scrim appears on hover — and every click lands on "play" instead. This shipped
    /// broken once; the ordering is load-bearing, not cosmetic.
    @Test("The like badge is layered above the hover scrim")
    func likeBadgeSitsAboveHoverPlay() throws {
        let card = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Sources/Baton/Shell/Music/MusicMediaCard.swift"),
            encoding: .utf8
        )
        // Anchored on `{ <identifier> }` — the brace is the structural part, the identifier
        // is the rule. It used to pin `".overlay { hoverPlay }"` and
        // `".overlay(alignment: .bottomTrailing) { likeBadge }"` in full, so giving the
        // hover overlay an alignment, or wrapping either line, would have reported that the
        // scrim swallows the heart's clicks — a claim about behaviour that a substring
        // search is in no position to make.
        let hover = try #require(
            card.range(of: "{ hoverPlay }"),
            "searched for `{ hoverPlay }` in MusicMediaCard.swift and did not find it — the hover overlay has been renamed or restructured, which this test cannot tell apart from its removal"
        )
        let like = try #require(
            card.range(of: "{ likeBadge }"),
            "searched for `{ likeBadge }` in MusicMediaCard.swift and did not find it — the like overlay has been renamed or restructured"
        )
        #expect(
            like.lowerBound > hover.upperBound,
            """
            The like badge is applied before hoverPlay, so the hover scrim swallows its clicks.
            Searched for `{ likeBadge }` after `{ hoverPlay }` in MusicMediaCard.swift and found it before.
            """
        )
    }

    /// One badge per corner of the artwork. The heart previously shared top-trailing with
    /// the now-playing bars and covered them — hiding the one thing that says a track is
    /// playing.
    @Test("Each artwork corner carries exactly one badge")
    func artworkCornersDoNotCollide() throws {
        let card = try String(
            contentsOf: repoRoot.appendingPathComponent("app/Sources/Baton/Shell/Music/MusicMediaCard.swift"),
            encoding: .utf8
        )
        // Scoped to `MusicMediaCard.artwork`. The file also holds `MusicSongThumb`, whose
        // own bottom-trailing heart is a *different* view over *different* artwork — a
        // whole-file count reads that as a collision and fails on correct code.
        // `var artwork`, not `private var artwork: some View {` — the visibility and the
        // opaque return type are decoration, and pinning them means a red gate the next time
        // either changes. The bound stays a structural one.
        let start = try #require(
            card.range(of: "var artwork"),
            "searched for `var artwork` in MusicMediaCard.swift and did not find it — it has been renamed, which this test cannot tell apart from a badge collision"
        )
        let rest = card[start.upperBound...]
        let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    private var ") ?? rest.range(of: "\n    var ")
        let artwork = String(end.map { rest[..<$0.lowerBound] } ?? rest)

        for corner in ["topLeading", "topTrailing", "bottomLeading", "bottomTrailing"] {
            let count = artwork.components(separatedBy: ".overlay(alignment: .\(corner))").count - 1
            #expect(count == 1, "the card's artwork has \(count) badges at \(corner) — they would overlap")
        }
    }
}
