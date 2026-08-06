import AVFAudio
import SwiftUI
import WatchConnectivity

/// Baton on the wrist — standalone playback over the same shared engine as the Mac
/// and iPhone (the thing only NaviBeat ships today). The server config arrives from
/// the paired iPhone over WatchConnectivity's encrypted channel; after that the
/// watch talks to Navidrome directly and plays through its own audio session
/// (Bluetooth headphones — watchOS refuses long-form audio to the speaker).
@main
struct BatonWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            if model.isConfigured {
                WatchRootView(model: model)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.title2)
                    Text("Open Baton on your iPhone to set up the watch.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }
}

/// The watch's tiny composition root: the shared engine + library + the config
/// receiver. No downloads store yet — v1 streams (offline episodes follow).
@MainActor
@Observable
final class WatchModel {
    let music = StreamingPlaybackController()
    let musicLibrary = MusicLibraryStore()
    @ObservationIgnored private var configReceiver: WatchConfigReceiver?

    var isConfigured: Bool { NavidromeConfig.isConfigured }

    init() {
        let receiver = WatchConfigReceiver { [weak self] in
            Task { @MainActor in
                self?.musicLibrary.refreshConnection()
                await self?.musicLibrary.loadStarred()
            }
        }
        configReceiver = receiver
        receiver.activate()

        // Downloads survive the wrist app being suspended, and resume after a
        // relaunch — the same background session the phone uses.
        let engine = BackgroundDownloadEngine()
        MusicDownloadStore.shared.backgroundEngine = engine
        engine.restoreOutstandingTasks()
    }

    /// Starts playback after the watch audio session is live. watchOS refuses
    /// long-form audio to the built-in speaker, so activation is asynchronous:
    /// it presents the route picker when no headphones are connected, and
    /// playback begins only once a real output exists.
    func play(_ songs: [NavidromeSong], from index: Int, label: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        session.activate { [weak self] activated, _ in
            guard activated else { return }
            Task { @MainActor in
                self?.music.play(songs, startAt: index, source: .init(label: label, kind: .liked))
            }
        }
    }
}

/// Receives the server config the iPhone pushes via `updateApplicationContext`
/// (encrypted transport, delivered even when this app was not running).
final class WatchConfigReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let onConfigured: @Sendable () -> Void

    init(onConfigured: @escaping @Sendable () -> Void) {
        self.onConfigured = onConfigured
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        apply(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        apply(context)
    }

    private func apply(_ context: [String: Any]) {
        guard let url = context["serverURL"] as? String, !url.isEmpty,
              let user = context["username"] as? String,
              let secret = context["secret"] as? String,
              let modeRaw = context["authMode"] as? String,
              let mode = NavidromeAuthMode(rawValue: modeRaw)
        else { return }
        let done = onConfigured
        Task { @MainActor in
            NavidromeConfig.save(urlString: url, username: user, secret: secret, authMode: mode)
            done()
        }
    }
}
