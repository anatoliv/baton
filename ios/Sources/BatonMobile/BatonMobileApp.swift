import SwiftUI
import UIKit

/// Exists for exactly one callback: iOS relaunching us to deliver background
/// download events. The stored handler is called by the engine once the session's
/// queued delegate events have replayed.
final class BatonAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadEngine.sessionIdentifier else { return completionHandler() }
        // UIKit's handler isn't @Sendable-annotated; it must be called on the main
        // thread, which is exactly where the engine invokes it.
        let box = UncheckedSendableBox(completionHandler)
        MusicDownloadStore.shared.backgroundEngine?.backgroundCompletionHandler = { box.value() }
    }
}

@main
struct BatonMobileApp: App {
    @UIApplicationDelegateAdaptor(BatonAppDelegate.self) private var appDelegate
    @State private var model: MobileModel
    init() {
        // No-op unless the user opted in AND a DSN is baked into this build.
        CrashReporting.startIfEnabled()
        let model = MobileModel()
        _model = State(initialValue: model)
        // Expose the composition root to Siri/Shortcuts intents (in-process).
        AppServicesHolder.model = model
    }
    var body: some Scene {
        WindowGroup {
            RootTabView(model: model)
                // Setup is a gate, not a tab: with neither a server nor the demo
                // there is nothing any other screen could show.
                .fullScreenCover(isPresented: Binding(
                    get: { model.showsSetup },
                    set: { model.showsSetup = $0 }
                )) {
                    OnboardingView(onConnected: {
                        model.showsSetup = false
                        model.endDemo()
                        Task { await model.warmLibrary() }
                    }, onTryDemo: {
                        model.startDemo()
                    })
                }
                .task { await model.restoreSession() }
                .onOpenURL { url in
                    Task { await route(url) }
                }
        }
    }

    /// baton:// deep-link routing. Kept deliberately small: play a song, or play an
    /// album — the two links the widgets and the agent need first.
    @MainActor
    private func route(_ url: URL) async {
        guard url.scheme == "baton", NavidromeConfig.isConfigured else { return }
        let id = url.lastPathComponent
        switch url.host() {
        case "play" where !id.isEmpty:
            if let song = try? await NavidromeConfig.makeClient().getSong(id: id) {
                model.music.play([song], source: .init(label: song.title, kind: .song, id: id))
            }
        case "album" where !id.isEmpty:
            let songs = await model.musicLibrary.albumSongs(id: id)
            if !songs.isEmpty {
                model.music.play(songs, source: .init(label: "Album", kind: .album, id: id))
            }
        default:
            break
        }
    }
}


/// Carries a main-thread-only closure across a @Sendable boundary. Safe here because
/// the engine calls it via the main actor.
private struct UncheckedSendableBox: @unchecked Sendable {
    let value: () -> Void
    init(_ value: @escaping () -> Void) { self.value = value }
}
