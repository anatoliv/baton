import Foundation

/// F4 — the output-routing foundation (docs/09 finding: "AirPlay-only is the most
/// conspicuous gap"). This is the **pure, transport-agnostic** seam every casting
/// provider plugs into. It ships now; the live providers (AirPlay wrapper, Chromecast,
/// Sonos, UPnP/DLNA) are the staged arc specified in docs/10.
///
/// Nothing here touches the network or an SDK — a `CastProvider` discovers devices and
/// hands the resolver a list of `CastRoute`s; the resolver merges the lists from every
/// provider into one clean, deduped, single-selection view the UI (or an MCP
/// `music_list_outputs` tool) can render. Pure ⇒ fully unit-testable.

/// A single audio-output destination surfaced by some provider.
struct CastRoute: Identifiable, Hashable, Sendable {
    /// The transport a route reaches its device over. `sortIndex` gives the display order:
    /// the local Mac first, then AirPlay, then the network-cast families.
    enum Kind: String, Sendable, CaseIterable {
        case thisMac, airplay, chromecast, sonos, upnp

        var sortIndex: Int {
            switch self {
            case .thisMac: return 0
            case .airplay: return 1
            case .chromecast: return 2
            case .sonos: return 3
            case .upnp: return 4
            }
        }

        /// Human label for the group heading in a route list.
        var displayName: String {
            switch self {
            case .thisMac: return "This Mac"
            case .airplay: return "AirPlay"
            case .chromecast: return "Chromecast"
            case .sonos: return "Sonos"
            case .upnp: return "UPnP / DLNA"
            }
        }
    }

    /// Provider-stable identity for the device (e.g. an AirPlay uid or a Cast device id).
    let id: String
    let name: String
    let kind: Kind
    /// Whether the device is currently reachable. Unavailable routes are dropped by the resolver.
    var isAvailable: Bool = true
    /// Whether audio is currently routed here. The resolver guarantees exactly one selected
    /// route across the whole set (see `resolve`).
    var isSelected: Bool = false
}

/// The provider contract each transport implements (AirPlay, Chromecast, …). Kept here so
/// the shape is defined alongside the resolver; concrete providers are the staged arc.
protocol CastProvider {
    var kind: CastRoute.Kind { get }
    /// Begin discovering devices (mDNS `_googlecast._tcp`, SSDP, an `AVRoutePickerView`'s
    /// state, …). Idempotent.
    func startDiscovery() async
    /// The devices currently known to this provider.
    func routes() -> [CastRoute]
    /// Route audio to `route`. Throws if the device rejects the hand-off.
    func select(_ route: CastRoute) async throws
    /// Stop discovery / tear down browsers.
    func endDiscovery()
}

/// Pure merge/normalize logic over the routes several providers report.
enum CastRouteResolver {
    /// Merge per-provider route lists into one canonical, display-ready list:
    ///  1. **De-dupe by id** — the first occurrence wins its name/kind, but selection carries
    ///     over (a duplicate marked selected selects the survivor).
    ///  2. **Drop unavailable** devices.
    ///  3. **Sort** — local Mac first, then by transport family, then case-insensitive name,
    ///     then id (a stable, deterministic final tiebreak).
    ///  4. **Guarantee exactly one selected** route when the list is non-empty: if none is
    ///     selected, pick "This Mac" (else the first); if several are, keep only the first.
    static func resolve(_ groups: [[CastRoute]]) -> [CastRoute] {
        // 1 + selection-carry-over: keep first-seen per id, OR-ing the selected flag.
        var orderedIDs: [String] = []
        var byID: [String: CastRoute] = [:]
        for route in groups.flatMap({ $0 }) {
            if var existing = byID[route.id] {
                if route.isSelected { existing.isSelected = true; byID[route.id] = existing }
            } else {
                byID[route.id] = route
                orderedIDs.append(route.id)
            }
        }

        // 2: drop unavailable.
        var routes = orderedIDs.compactMap { byID[$0] }.filter(\.isAvailable)
        guard !routes.isEmpty else { return [] }

        // 3: deterministic sort.
        routes.sort { a, b in
            if a.kind.sortIndex != b.kind.sortIndex { return a.kind.sortIndex < b.kind.sortIndex }
            let an = a.name.lowercased(), bn = b.name.lowercased()
            if an != bn { return an < bn }
            return a.id < b.id
        }

        // 4: normalize to exactly one selection.
        let selectedIndices = routes.indices.filter { routes[$0].isSelected }
        if selectedIndices.isEmpty {
            let defaultIndex = routes.firstIndex { $0.kind == .thisMac } ?? routes.startIndex
            routes[defaultIndex].isSelected = true
        } else if selectedIndices.count > 1 {
            for i in selectedIndices.dropFirst() { routes[i].isSelected = false }
        }
        return routes
    }

    /// The single active route in an already-resolved list, if any.
    static func activeRoute(_ resolved: [CastRoute]) -> CastRoute? {
        resolved.first { $0.isSelected }
    }
}
