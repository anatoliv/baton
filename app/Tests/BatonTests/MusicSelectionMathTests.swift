import Testing
@testable import Baton

struct MusicSelectionMathTests {
    let ids = ["a", "b", "c", "d", "e"]

    // MARK: - afterClick (plain toggle)

    @Test("Plain click on an unselected item selects it and moves the anchor")
    func plainSelects() {
        let r = MusicSelectionMath.afterClick(id: "c", orderedIDs: ids, selection: [], anchor: nil, shift: false)
        #expect(r.selection == ["c"])
        #expect(r.anchor == "c")
    }

    @Test("Plain click on a selected item deselects it")
    func plainDeselects() {
        let r = MusicSelectionMath.afterClick(id: "c", orderedIDs: ids, selection: ["c"], anchor: "a", shift: false)
        #expect(r.selection == [])
        #expect(r.anchor == "c")
    }

    // MARK: - afterClick (shift range)

    @Test("Shift-click selects the forward range from the anchor, inclusive")
    func shiftForwardRange() {
        let r = MusicSelectionMath.afterClick(id: "d", orderedIDs: ids, selection: ["b"], anchor: "b", shift: true)
        #expect(r.selection == ["b", "c", "d"])
        #expect(r.anchor == "d")
    }

    @Test("Shift-click selects the backward range too (anchor after the click)")
    func shiftBackwardRange() {
        let r = MusicSelectionMath.afterClick(id: "a", orderedIDs: ids, selection: ["d"], anchor: "d", shift: true)
        #expect(r.selection == ["a", "b", "c", "d"])
        #expect(r.anchor == "a")
    }

    @Test("Shift-range only adds — it never deselects existing items")
    func shiftOnlyAdds() {
        let r = MusicSelectionMath.afterClick(id: "c", orderedIDs: ids, selection: ["a", "b"], anchor: "b", shift: true)
        #expect(r.selection == ["a", "b", "c"])
    }

    @Test("Shift-click with no anchor falls back to a plain toggle")
    func shiftNoAnchor() {
        let r = MusicSelectionMath.afterClick(id: "c", orderedIDs: ids, selection: [], anchor: nil, shift: true)
        #expect(r.selection == ["c"])
    }

    @Test("Shift-click with an anchor no longer visible falls back to a toggle")
    func shiftStaleAnchor() {
        let r = MusicSelectionMath.afterClick(id: "c", orderedIDs: ids, selection: [], anchor: "zzz", shift: true)
        #expect(r.selection == ["c"])
        #expect(r.anchor == "c")
    }

    // MARK: - likeTargets

    @Test("Mixed selection likes only the not-yet-liked songs")
    func likeMixed() {
        let (toToggle, unlikeAll) = MusicSelectionMath.likeTargets(selected: ["a", "b", "c"], likedIDs: ["b"])
        #expect(unlikeAll == false)
        #expect(Set(toToggle) == ["a", "c"])
    }

    @Test("All-liked selection unlikes every song")
    func unlikeAll() {
        let (toToggle, unlikeAll) = MusicSelectionMath.likeTargets(selected: ["a", "b"], likedIDs: ["a", "b"])
        #expect(unlikeAll == true)
        #expect(Set(toToggle) == ["a", "b"])
    }

    @Test("Empty selection toggles nothing")
    func likeEmpty() {
        let (toToggle, unlikeAll) = MusicSelectionMath.likeTargets(selected: [], likedIDs: ["a"])
        #expect(unlikeAll == false)
        #expect(toToggle.isEmpty)
    }
}
