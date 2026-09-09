import BatonSubsonicKit
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
        // No-op unless the user opted in and release packaging supplied one complete,
        // immutable provider configuration. Initialization runs off the UI thread.
        CrashReporting.startIfEnabled()
        // The default URLCache is 512KB in memory — about four covers. Raised before the
        // first request goes out, or the setting arrives after the cache it was meant to
        // size.
        ArtworkCache.configureURLCache()
        LegacyKeyMigration.run()
        // Stamp the version a fresh install started on. Without this the What's New marker
        // stayed empty for the life of the install, so the automatic sheet could never fire
        // on any later update — which is every App Store install of 1.0.
        WhatsNewView.stampInstalledVersion()
        let model = MobileModel()
        _model = State(initialValue: model)
        // Expose the composition root to Siri/Shortcuts intents (in-process).
        AppServicesHolder.model = model
        // Wire the shared transport intents to the live engine. They are declared in
        // Sources/Shared so the widget can *offer* them; only the app can *do* them.
        TransportIntentHandler.resume = { [weak model] in model?.music.resume() }
        TransportIntentHandler.pause = { [weak model] in model?.music.pause() }
        TransportIntentHandler.togglePlayPause = { [weak model] in
            guard let model else { return }
            model.music.isPlaying ? model.music.pause() : model.music.resume()
        }
        TransportIntentHandler.next = { [weak model] in model?.music.next() }
        TransportIntentHandler.previous = { [weak model] in model?.music.previous() }
        TransportIntentHandler.toggleLike = { [weak model] in
            guard let model, let song = model.music.nowPlaying else { return }
            Task { await model.musicLibrary.toggleLike(song) }
        }
    }
    var body: some Scene {
        WindowGroup {
            RootTabView(model: model)
                // Every `@AppStorage` below here reads the domain `BatonStorage` resolved: the
                // app's own normally, a throwaway suite when launched with `-baton.defaultsSuite`.
                // On the phone the container is already isolated per install, so this matters less
                // than on the Mac — but the two apps share these views, and a rule that holds on
                // one platform only is the kind that drifts.
                .defaultAppStorage(BatonStorage.defaults)
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
                // The keep-awake preference only means anything if it survives a relaunch
                // — a toggle that resets whenever the app restarts is a suggestion.
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled =
                        BatonStorage.defaults.bool(forKey: "baton.display.keepAwake")
                }
                .onOpenURL { url in
                    Task { await route(url) }
                }
        }
    }

    /// Acts on a `baton://` link. What the link *means* is decided by `BatonDeepLink`,
    /// which is a pure function and tested as one; `MobileModel.open` carries it out and
    /// reports what happened, so a link that cannot be honoured says so instead of leaving
    /// the app sitting there looking as though nothing was tapped.
    @MainActor
    private func route(_ url: URL) async {
        // A link this app does not claim is not a failure worth a message: it was never
        // ours, and something else on the phone may still handle it.
        guard let link = BatonDeepLink(url: url) else { return }
        model.linkFailure = await model.open(link).message
    }
}


/// Carries a main-thread-only closure across a @Sendable boundary. Safe here because
/// the engine calls it via the main actor.
private struct UncheckedSendableBox: @unchecked Sendable {
    let value: () -> Void
    init(_ value: @escaping () -> Void) { self.value = value }
}
