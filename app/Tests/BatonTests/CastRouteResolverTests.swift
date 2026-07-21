import XCTest
@testable import Baton

/// F4 — unit tests for the pure casting route-resolver (docs/09 casting-gap finding).
/// No network / no SDK: the resolver merges per-provider route lists into one canonical,
/// deduped, single-selection, deterministically-sorted view.
final class CastRouteResolverTests: XCTestCase {
    private func route(_ id: String, _ name: String, _ kind: CastRoute.Kind,
                       available: Bool = true, selected: Bool = false) -> CastRoute {
        CastRoute(id: id, name: name, kind: kind, isAvailable: available, isSelected: selected)
    }

    func testEmptyResolvesToEmptyWithNoActiveRoute() {
        let resolved = CastRouteResolver.resolve([])
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertNil(CastRouteResolver.activeRoute(resolved))
    }

    func testDedupesById() {
        let resolved = CastRouteResolver.resolve([
            [route("x", "Kitchen", .sonos)],
            [route("x", "Kitchen (dup)", .sonos)],
        ])
        XCTAssertEqual(resolved.filter { $0.id == "x" }.count, 1, "same id must collapse to one route")
        XCTAssertEqual(resolved.first { $0.id == "x" }?.name, "Kitchen", "first occurrence wins the name")
    }

    func testDropsUnavailableRoutes() {
        let resolved = CastRouteResolver.resolve([[
            route("mac", "This Mac", .thisMac),
            route("gone", "Old Speaker", .sonos, available: false),
        ]])
        XCTAssertEqual(resolved.map(\.id), ["mac"], "unavailable devices are filtered out")
    }

    func testSortsThisMacFirstThenKindThenName() {
        let resolved = CastRouteResolver.resolve([[
            route("s", "Zeta", .sonos),
            route("c2", "beta", .chromecast),
            route("c1", "Alpha", .chromecast),
            route("mac", "This Mac", .thisMac),
            route("a", "Living Room", .airplay),
        ]])
        // thisMac, then airplay, then chromecast (Alpha < beta, case-insensitive), then sonos.
        XCTAssertEqual(resolved.map(\.id), ["mac", "a", "c1", "c2", "s"])
    }

    func testSelectsThisMacWhenNothingSelected() {
        let resolved = CastRouteResolver.resolve([[
            route("a", "Living Room", .airplay),
            route("mac", "This Mac", .thisMac),
        ]])
        XCTAssertEqual(CastRouteResolver.activeRoute(resolved)?.id, "mac",
                       "with nothing selected, playback stays on the Mac")
    }

    func testSelectsFirstWhenNoMacAndNothingSelected() {
        let resolved = CastRouteResolver.resolve([[
            route("s", "Bedroom", .sonos),
            route("a", "Living Room", .airplay),
        ]])
        // airplay sorts before sonos → "a" is first → it becomes the default selection.
        XCTAssertEqual(CastRouteResolver.activeRoute(resolved)?.id, "a")
    }

    func testCollapsesMultipleSelectionsToOne() {
        let resolved = CastRouteResolver.resolve([[
            route("a", "Living Room", .airplay, selected: true),
            route("s", "Bedroom", .sonos, selected: true),
        ]])
        XCTAssertEqual(resolved.filter(\.isSelected).count, 1, "exactly one route may be active")
        // First in sorted order (airplay before sonos) keeps the selection.
        XCTAssertEqual(CastRouteResolver.activeRoute(resolved)?.id, "a")
    }

    func testSelectionCarriesOverAcrossDuplicates() {
        // An unselected copy is seen first; a later selected copy of the same device must win.
        let resolved = CastRouteResolver.resolve([
            [route("x", "Patio", .chromecast, selected: false)],
            [route("x", "Patio", .chromecast, selected: true)],
        ])
        XCTAssertEqual(CastRouteResolver.activeRoute(resolved)?.id, "x",
                       "a duplicate marked selected selects the surviving route")
    }

    func testResolveIsDeterministic() {
        let groups = [[
            route("c2", "beta", .chromecast),
            route("c1", "beta", .chromecast), // identical name → id breaks the tie
            route("mac", "This Mac", .thisMac),
        ]]
        XCTAssertEqual(CastRouteResolver.resolve(groups).map(\.id),
                       CastRouteResolver.resolve(groups).map(\.id))
        XCTAssertEqual(CastRouteResolver.resolve(groups).map(\.id), ["mac", "c1", "c2"],
                       "equal names fall back to id order")
    }
}
