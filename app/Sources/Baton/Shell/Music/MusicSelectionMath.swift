import Foundation

/// Pure selection logic for the music Songs collection, extracted from the view so it
/// can be unit-tested without SwiftUI or AppKit. The view keeps the AppKit bit (reading
/// the Shift modifier from the live `NSEvent`) and delegates the set math here.
enum MusicSelectionMath {
    /// The new selection + anchor after clicking `id`.
    ///
    /// - Plain click (`shift == false`): toggle `id` in/out of the selection.
    /// - Shift-click (`shift == true`) with a valid anchor: **add** the contiguous range
    ///   from the anchor to `id` (inclusive), in either direction. Ranges only ever add,
    ///   matching Finder/Music: Shift never deselects.
    /// - Shift-click with no anchor (or an anchor no longer visible): falls back to a
    ///   plain toggle so the click is never lost.
    ///
    /// The anchor always moves to the just-clicked `id`.
    static func afterClick(
        id: String,
        orderedIDs: [String],
        selection: Set<String>,
        anchor: String?,
        shift: Bool
    ) -> (selection: Set<String>, anchor: String?) {
        var next = selection
        if shift,
           let anchor,
           let anchorIndex = orderedIDs.firstIndex(of: anchor),
           let clickedIndex = orderedIDs.firstIndex(of: id)
        {
            let lower = min(anchorIndex, clickedIndex)
            let upper = max(anchorIndex, clickedIndex)
            next.formUnion(orderedIDs[lower ... upper])
        } else if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        return (next, id)
    }

    /// Which of `selected` songs to toggle for a batch Like button, and whether the
    /// button is currently in "unlike all" mode. When every selected song is already
    /// liked the button unlikes them all; otherwise it likes only the ones not yet liked
    /// (so a mixed selection becomes all-liked in one press, without flipping the rest).
    static func likeTargets(
        selected: [String],
        likedIDs: Set<String>
    ) -> (toToggle: [String], unlikeAll: Bool) {
        let unlikeAll = !selected.isEmpty && selected.allSatisfy { likedIDs.contains($0) }
        let toToggle = selected.filter { unlikeAll ? likedIDs.contains($0) : !likedIDs.contains($0) }
        return (toToggle, unlikeAll)
    }
}
