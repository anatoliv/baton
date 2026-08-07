import Foundation

/// Which Library rows show, and in what order.
///
/// The Library was a fixed eight-row list, which is the average of everyone's needs and
/// nobody's actual ones — someone who never uses Radio still scrolled past it daily, and
/// someone living in Playlists couldn't put it first. Apple Music and Amperfy both make
/// this list editable; now Baton's is too.
///
/// The layout is stored as two lists of raw ids rather than anything cleverer, and the
/// merge rule is the part that matters: **a section this build knows about but the saved
/// layout doesn't gets appended, visible**. Otherwise every new feature ships hidden from
/// everyone who ever touched Edit — which is how "nobody found the Folders screen"
/// happens two releases from now.
enum LibrarySection: String, CaseIterable, Identifiable {
    case liked, playlists, artists, genres, history, downloads, podcasts, radio, folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liked: "Liked"
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .genres: "Genres"
        case .history: "History"
        case .downloads: "Downloads"
        case .podcasts: "Podcasts"
        case .radio: "Radio"
        case .folders: "Folders"
        }
    }

    var symbol: String {
        switch self {
        case .liked: "heart"
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .genres: "guitars"
        case .history: "clock.arrow.circlepath"
        case .downloads: "arrow.down.circle"
        case .podcasts: "mic"
        case .radio: "dot.radiowaves.left.and.right"
        case .folders: "folder"
        }
    }
}

@MainActor
@Observable
final class LibraryLayout {
    static let orderKey = "baton.library.order"
    static let hiddenKey = "baton.library.hidden"

    private(set) var order: [LibrarySection]
    private(set) var hidden: Set<LibrarySection>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = Self.resolve(saved: defaults.stringArray(forKey: Self.orderKey) ?? [])
        hidden = Set((defaults.stringArray(forKey: Self.hiddenKey) ?? [])
            .compactMap(LibrarySection.init(rawValue:)))
    }

    /// What the Library actually lists.
    var visible: [LibrarySection] { order.filter { !hidden.contains($0) } }

    /// Saved order first (dropping ids this build no longer knows), then anything new
    /// appended visible — see the type comment for why appended-visible is load-bearing.
    static func resolve(saved: [String]) -> [LibrarySection] {
        var out = saved.compactMap(LibrarySection.init(rawValue:))
        for section in LibrarySection.allCases where !out.contains(section) {
            out.append(section)
        }
        return out
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setVisible(_ section: LibrarySection, _ visible: Bool) {
        if visible { hidden.remove(section) } else { hidden.insert(section) }
        // Hiding everything leaves a blank tab with no way to understand why. Keep at
        // least one row, and make it the one that was just about to vanish.
        if hidden.count == LibrarySection.allCases.count { hidden.remove(section) }
        persist()
    }

    func isVisible(_ section: LibrarySection) -> Bool { !hidden.contains(section) }

    private func persist() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }
}
