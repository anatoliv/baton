import Foundation

/// The bundled demo library's names, as the UI tests expect to find them on screen.
///
/// The UI-test target runs in its own process and can't import the app, so these are
/// copies of what `DemoLibrary` publishes. Copies are unavoidable; *scattered* copies
/// aren't — renaming the demo content from "Baton Demo / First Light" to the Goldberg
/// Variations broke three tests in three files at once, and every one of them was the
/// same fact written out again.
///
/// Keep in step with `ios/Sources/BatonMobile/DemoLibrary.swift`.
enum DemoFixtures {
    static let album = "Goldberg Variations"
    static let artist = "Kimiko Ishizaka"
    static let firstTrack = "Variatio 4"

    /// A prefix that must return results when typed into a search field. Deliberately
    /// short enough to survive a title being reworded.
    static let searchTerm = "Variatio"
}
