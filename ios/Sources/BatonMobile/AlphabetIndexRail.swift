import SwiftUI
import BatonSubsonicModels

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

        /// What the rail actually draws.
        ///
        /// Server buckets are not always single characters: Navidrome returns ranges like
        /// `X-Z` and a literal `[Unknown]`, and a word in a 22pt column wraps onto two
        /// lines and clips mid-letter. Up to three characters fits — which keeps `X-Z`,
        /// the one that carries information — and anything longer becomes `?`, the
        /// conventional mark for "filed under nothing".
        var displayLetter: String { letter.count <= 3 ? letter : "?" }
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

    /// How many items a list needs before it earns a rail.
    ///
    /// Overridable with `-baton.railMinimum <n>` because the default hid this whole
    /// feature from every test that could have caught its bugs: demo.navidrome.org reports
    /// 26 artists and 19 playlists, both under 30, so a simulator run against the demo
    /// library renders every rail screen railless. Two broken rails shipped behind that.
    static var minimumItems: Int {
        let override = UserDefaults.standard.integer(forKey: "baton.railMinimum")
        return override > 0 ? override : 30
    }

    /// Rail entries that something has vouched for the ordering of.
    ///
    /// The rail is a map of the list, so it is only ever correct when its letters run in
    /// the same order as the rows. Nothing used to enforce that. Four screens each wrote
    /// their own `guard sort == …` and Genres forgot, so it drew an index over a list
    /// ordered by song count — `E, R, H, A, C, P` — where tapping "A" jumped to wherever
    /// the first A-genre sat in a popularity ranking.
    ///
    /// A rule living in four places is a rule one of them will miss. This is the only way
    /// to obtain entries, and neither route lets a caller stay silent about ordering.
    struct Ordered {
        let entries: [Entry]

        /// No rail. What a screen whose list isn't alphabetically ordered gets.
        static let none = Ordered(entries: [])

        /// From the server's own index buckets — `getArtists`, `getIndexes`.
        ///
        /// Correct by construction and in any script: the party that ordered the rows is
        /// the party naming the letters, so the two cannot disagree.
        static func server<Element>(_ list: ServerIndexedList<Element>,
                                    minimum: Int = AlphabetIndex.minimumItems) -> Ordered
        where Element.ID == String {
            guard list.items.count > minimum else { return .none }
            return Ordered(entries: list.indexTargets.map {
                Entry(letter: $0.letter, firstID: $0.firstID)
            })
        }

        /// From a list the *client* put in order, where the caller states in the same
        /// breath whether that order is alphabetical. Passing `false` yields no rail.
        static func clientSorted(_ items: [(id: String, name: String)],
                                 isAlphabetical: Bool,
                                 minimum: Int = AlphabetIndex.minimumItems) -> Ordered {
            guard isAlphabetical, items.count > minimum else { return .none }
            return Ordered(entries: AlphabetIndex.entries(from: items))
        }
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
    /// Horizontal room the rail needs — its own width, and the inset callers reserve.
    ///
    /// One constant used in both places, because the first attempt used two. The rail was
    /// framed at 22 while `alphabetIndexRail(_:proxy:)` reserved 18, so it overhung the
    /// content by 4pt and the letters kept landing on the chevrons — the collision the
    /// modifier exists to prevent, 4pt instead of 22pt but still there and still visible.
    ///
    /// The 18 came from Albums, where it is written *on top of* a `.padding(.horizontal)`:
    /// 16 + 18 = 34pt of gutter for the same 22pt rail. Transplanted out of that context it
    /// silently lost the 16 underneath it. Deriving the frame from this constant is what
    /// makes the two impossible to disagree.
    static let reservedWidth: CGFloat = 22

    /// Breathing room between the letters and whatever the rows end in.
    ///
    /// Albums' effective 12pt, kept explicit so it reads as a choice rather than as
    /// whatever fell out of two paddings adding up.
    static let clearance: CGFloat = 12

    let entries: [AlphabetIndex.Entry]
    var onSelect: (AlphabetIndex.Entry) -> Void

    @State private var lastLetter: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    Text(entry.displayLetter)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
        .frame(width: Self.reservedWidth)
        .accessibilityElement()
        .accessibilityLabel("Alphabet index")
        .accessibilityHint("Drag to jump through the list")
        .accessibilityIdentifier("AlphabetIndexRail")
    }
}

extension View {
    /// Attaches the A–Z rail *and* reserves the room it needs.
    ///
    /// These two have to happen together and did not. The rail is an overlay, so it draws
    /// on top of whatever is under it — and only Albums ever added the matching trailing
    /// inset. On Artists and Folders the letters have always sat on top of the rows'
    /// disclosure chevrons, and when Liked, Playlists and Genres gained the rail they
    /// inherited the same collision, because the overlay is the memorable half and the
    /// padding is the half you forget.
    ///
    /// One modifier so forgetting is no longer possible.
    func alphabetIndexRail(_ ordered: AlphabetIndex.Ordered,
                           proxy: ScrollViewProxy) -> some View {
        modifier(AlphabetIndexRailModifier(entries: ordered.entries, proxy: proxy))
    }
}

/// Attaches the rail, reserves its room, and withholds both at accessibility text sizes.
///
/// The letters are hardcoded 10pt in a 22pt column: under the 44pt touch target, and the
/// one piece of type in the app that ignores Dynamic Type outright. Scaling it was costed
/// and cancelled as overengineering — a rail wide enough for accessibility type is a rail
/// that eats the rows it indexes.
///
/// So at accessibility sizes there is no rail, and the filter every one of these screens
/// now has is the accessible way to reach "S". Withholding the padding along with the
/// overlay matters as much: reserving a gutter for a rail that isn't drawn is 34pt of
/// nothing down the side of the list, at exactly the sizes with the least room to spare.
private struct AlphabetIndexRailModifier: ViewModifier {
    let entries: [AlphabetIndex.Entry]
    let proxy: ScrollViewProxy
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var showsRail: Bool { !entries.isEmpty && !dynamicTypeSize.isAccessibilitySize }

    func body(content: Content) -> some View {
        // The rail's own width plus its clearance, both from the rail itself. Reserving
        // less than the rail measures is not a smaller gutter, it is an overlap.
        content
            .padding(.trailing, showsRail
                     ? AlphabetIndexRail.reservedWidth + AlphabetIndexRail.clearance
                     : 0)
            .overlay(alignment: .trailing) {
                if showsRail {
                    AlphabetIndexRail(entries: entries) { entry in
                        proxy.scrollTo(entry.firstID, anchor: .top)
                    }
                    .padding(.vertical, 8)
                }
            }
    }
}
