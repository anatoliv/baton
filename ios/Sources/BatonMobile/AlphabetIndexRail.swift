import SwiftUI

/// The A–Z scrubber down the right edge of a long alphabetical list.
///
/// At 2,604 albums the grid is a flick marathon: getting to "S" means paging through
/// everything before it. Every list app on the platform solved this the same way — a rail
/// of letters you tap or drag — and its absence was the biggest browse gap Amperfy showed
/// up. Shown only for alphabetical sorts, because jumping to "S" in a most-played ordering
/// is a question with no answer.
enum AlphabetIndex {
    /// One rail entry: the letter, and the id of the first item filed under it.
    struct Entry: Equatable, Identifiable {
        let letter: String
        let firstID: String
        var id: String { letter }
    }

    /// Builds the rail from `(id, sortName)` pairs already in display order.
    ///
    /// Letters come from the *data*, not a fixed A–Z: a library with no "Q" gets no dead
    /// "Q" target, and one full of "Æ" and "É" files them under the diacritic-folded
    /// letter the list itself sorts by. Digits and punctuation pool under "#", matching
    /// how the underlying sort groups them.
    static func entries(from items: [(id: String, name: String)]) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for item in items {
            let letter = bucket(for: item.name)
            if seen.insert(letter).inserted {
                out.append(Entry(letter: letter, firstID: item.id))
            }
        }
        return out
    }

    static func bucket(for name: String) -> String {
        // Fold diacritics the way the sort does, so "Édith" lands under E.
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let first = folded.trimmingCharacters(in: .whitespaces).first else { return "#" }
        return first.isLetter ? String(first).uppercased() : "#"
    }
}

/// The rail itself. Tap a letter or drag along the edge; `onSelect` receives the id to
/// scroll to. Kept dumb on purpose — the host owns the ScrollViewReader.
struct AlphabetIndexRail: View {
    let entries: [AlphabetIndex.Entry]
    var onSelect: (AlphabetIndex.Entry) -> Void

    @State private var lastLetter: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    Text(entry.letter)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .foregroundStyle(.tint)
            .contentShape(Rectangle())
            // One continuous gesture covers both tap and drag: a drag with zero distance
            // is a tap, and sliding a finger down the rail walks the alphabet with haptic
            // ticks, which is how the system's own index feels.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !entries.isEmpty, geo.size.height > 0 else { return }
                        let fraction = min(max(value.location.y / geo.size.height, 0), 0.999)
                        let entry = entries[Int(fraction * CGFloat(entries.count))]
                        if entry.letter != lastLetter {
                            lastLetter = entry.letter
                            UISelectionFeedbackGenerator().selectionChanged()
                            onSelect(entry)
                        }
                    }
                    .onEnded { _ in lastLetter = nil }
            )
        }
        .frame(width: 22)
        .accessibilityElement()
        .accessibilityLabel("Alphabet index")
        .accessibilityHint("Drag to jump through the list")
        .accessibilityIdentifier("AlphabetIndexRail")
    }
}
