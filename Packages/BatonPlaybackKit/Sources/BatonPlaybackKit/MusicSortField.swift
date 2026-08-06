/// A sort field for the shared sort controls — each browse screen's sort enum
/// conforms so one control can render every screen's fields. Lives in the package
/// (not the UI layer) because the library store's sort enums conform to it.
public protocol MusicSortField: Identifiable, Hashable, CaseIterable {
    var label: String { get }
}
