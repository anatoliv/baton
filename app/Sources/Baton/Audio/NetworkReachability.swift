import Foundation
import Network

/// Lightweight network-path observer used to gate expensive background work (the gapless
/// prefetch) on connection type. Reports whether the current path is **metered** — expensive
/// (cellular / personal hotspot) or constrained (Low Data Mode) — so the player can skip
/// downloading the next track ahead of time when the user is on a limited connection.
///
/// A main-actor snapshot updated from `NWPathMonitor`'s background callback.
@MainActor
final class NetworkReachability {
    static let shared = NetworkReachability()

    private(set) var isExpensive = false
    private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.tonebox.network-reachability")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                self?.isExpensive = expensive
                self?.isConstrained = constrained
            }
        }
        monitor.start(queue: queue)
    }

    /// True when the connection is metered/limited and heavy prefetch should be avoided.
    var isMetered: Bool { isExpensive || isConstrained }
}
