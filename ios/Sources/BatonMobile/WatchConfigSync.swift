import Foundation
import WatchConnectivity

/// Pushes the server config to the paired watch over WatchConnectivity's encrypted
/// applicationContext — delivered even while the watch app isn't running, so the
/// watch is ready the first time it opens.
final class WatchConfigSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConfigSync()

    func activateAndPush() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    @MainActor
    private func push() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              let server = NavidromeConfig.activeServer() else { return }
        let secret = NavidromeKeychain.secret(account: NavidromeConfig.keychainAccount(for: server.id)) ?? ""
        guard !secret.isEmpty else { return }
        try? WCSession.default.updateApplicationContext([
            "serverURL": server.urlString,
            "username": server.username,
            "secret": secret,
            "authMode": server.authMode.rawValue,
        ])
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.push() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push() }
    }
}
