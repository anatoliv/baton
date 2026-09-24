import Foundation

// MARK: - Port scan

/// Decides which ports the MCP listener tries, and in what order, before any socket is opened.
///
/// Pure: the probe that says whether a port is free is injected, so the order, the sibling
/// skip and the "nothing free" case are all testable without binding anything. The server
/// passes a real `NWListener` bind as the probe.
public enum BatonMCPPortScan {
    /// The default MCP ports of the sibling apps that share this machine: Tonebox (8765),
    /// Threadstow (8784) and Seedbed (8789). The upward walk steps over them so Baton does not
    /// take a port a sibling is about to start on. The user's own preferred port is never
    /// skipped: if they typed 8789 on purpose, they get 8789.
    public static let siblingDefaultPorts: Set<UInt16> = [8765, 8784, 8789]

    /// The ports to try, in order: `preferred` first, then upward, skipping `skipping`,
    /// until `count` candidates are collected. Stops early at the top of the port range.
    public static func candidates(
        preferred: UInt16,
        count: Int = BatonMCPConstants.portScanRange,
        skipping: Set<UInt16> = siblingDefaultPorts
    ) -> [UInt16] {
        guard count > 0 else { return [] }
        var out: [UInt16] = [preferred]
        var next = UInt32(preferred) + 1
        while out.count < count, next <= UInt32(UInt16.max) {
            let port = UInt16(next)
            if !skipping.contains(port) { out.append(port) }
            next += 1
        }
        return out
    }

    /// The first candidate `isFree` accepts, or nil when none is.
    public static func firstFree(
        preferred: UInt16,
        count: Int = BatonMCPConstants.portScanRange,
        skipping: Set<UInt16> = siblingDefaultPorts,
        isFree: (UInt16) async -> Bool
    ) async -> UInt16? {
        for port in candidates(preferred: preferred, count: count, skipping: skipping) {
            if await isFree(port) { return port }
        }
        return nil
    }

    /// The last port the scan would try, for the "nothing free" message.
    public static func lastCandidate(
        preferred: UInt16,
        count: Int = BatonMCPConstants.portScanRange,
        skipping: Set<UInt16> = siblingDefaultPorts
    ) -> UInt16 {
        candidates(preferred: preferred, count: count, skipping: skipping).last ?? preferred
    }

    /// Reads the user's preferred port out of `defaults`, falling back to the default port
    /// when nothing is stored or the stored value is not a usable port.
    public static func preferredPort(from defaults: UserDefaults) -> UInt16 {
        guard let raw = defaults.object(forKey: BatonMCPConstants.preferredPortDefaultsKey) as? Int,
              let port = UInt16(exactly: raw),
              BatonMCPConstants.validPortRange.contains(port)
        else { return BatonMCPConstants.defaultPort }
        return port
    }
}

/// The server bound a port other than the one the user asked for. Shown in Settings and posted
/// as a macOS user notification, so a client configured with a fixed URL gets told why it
/// stopped connecting instead of failing silently.
public struct BatonMCPPortNotice: Equatable, Sendable {
    /// The port the user (or the default) asked for.
    public let preferred: UInt16
    /// The port the listener actually bound.
    public let bound: UInt16

    public init(preferred: UInt16, bound: UInt16) {
        self.preferred = preferred
        self.bound = bound
    }

    /// The sentence the user reads. Customer-facing: no dashes.
    public var message: String {
        "Port \(preferred) was in use. Baton is on \(bound). Update your MCP client, or use mcp.json."
    }
}
