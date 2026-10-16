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
        if identifier == BackgroundShareUploadEngine.sessionIdentifier {
            SongSharing.shared.handleBackgroundUploadEvents(completion: completionHandler)
            return
        }
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
    @Environment(\.scenePhase) private var scenePhase
    init() {
        // No-op unless the user opted in and release packaging supplied one complete,
        // immutable provider configuration. Initialization runs off the UI thread.
        CrashReporting.startIfEnabled()
        // The default URLCache is 512KB in memory — about four covers. Raised before the
        // first request goes out, or the setting arrives after the cache it was meant to
        // size.
        ArtworkCache.configureURLCache()
        LegacyKeyMigration.run()
        Task { await SongSharing.shared.restoreBackgroundUploads() }
        // Stamp the version a fresh install started on. Without this the What's New marker
        // stayed empty for the life of the install, so the automatic sheet could never fire
        // on any later update — which is every App Store install of 1.0.
        WhatsNewView.stampInstalledVersion()
        #if DEBUG
        // ShareInboxUITests: the share sheet is another app's and cannot be driven from a UI
        // test, so the extension's own writer leaves the share in the real App Group inbox here,
        // before the first activation picks it up. Environment only.
        if let text = ProcessInfo.processInfo.environment["uitestSharedText"], !text.isEmpty {
            _ = try? PendingShareInbox.shared?.writeText(text, originalName: "Shared Pages.txt")
        }
        #endif
        let model = MobileModel()
        _model = State(initialValue: model)
        // The refresh iOS grants while the app is closed, so "Chapter 1 is ready" can arrive
        // with the phone in a pocket (M5.4). Registered before the app finishes launching, as
        // BGTaskScheduler requires.
        MobileDocuments.registerRefresh(collect: { [weak model] in await model?.collectBooks() },
                                        moreToCome: { [weak model] in model?.books.hasUncollected ?? false })
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
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    Task { await SongSharing.shared.restoreBackgroundUploads() }
                }
                // The keep-awake preference only means anything if it survives a relaunch
                // — a toggle that resets whenever the app restarts is a suggestion.
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled =
                        BatonStorage.defaults.bool(forKey: "baton.display.keepAwake")
                }
                .onOpenURL { url in
                    Task { await route(url) }
                }
                // A book that arrived while the phone was away comes down the next time it is
                // looked at, not on a timer; the background refresh covers the pocket.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.collectBooks() }
                }
                // Something shared to "Baton" from another app waits in the App Group inbox,
                // since a share extension cannot open the app; the oldest opens here.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    #if DEBUG
                    if phase == .background { UITestShareWhenAway.writeOnce() }
                    #endif
                    // The import screen's watch runs whichever screen is up. Away from the
                    // foreground it slows to once a minute: while music keeps Baton alive, chapter 1
                    // still comes down promptly and is announced.
                    if phase == .background { model.books.enterBackground() }
                    if phase == .active { model.books.enterForeground() }
                    guard phase == .active, model.pendingDocumentImport == nil, MobileDocuments.isEnabled(),
                          let shared = MobileDocuments.claimSharedImport() else { return }
                    model.offerImport(shared)
                }
                // The import screen itself is presented by `RootTabView`, in the one sheet it
                // shares with What's New, so the two never race at launch.
        }
    }

    /// Acts on a `baton://` link. What the link *means* is decided by `BatonDeepLink`,
    /// which is a pure function and tested as one; `MobileModel.open` carries it out and
    /// reports what happened, so a link that cannot be honoured says so instead of leaving
    /// the app sitting there looking as though nothing was tapped.
    @MainActor
    private func route(_ url: URL) async {
        // A document from Files, Mail or the share sheet ("Open in Baton"): the import screen,
        // when the feature is on. Copied first, because the handed-over file is ours to read
        // only for a moment (M5.2).
        if url.isFileURL, MobileDocuments.isEnabled(), MobileDocuments.canImport(url) {
            do { model.offerImport(try MobileDocuments.stage(url)) } catch {
                model.linkFailure = "The file could not be opened: \(error.localizedDescription)"
            }
            return
        }
        // A link this app does not claim is not a failure worth a message: it was never
        // ours, and something else on the phone may still handle it.
        guard let link = BatonDeepLink(url: url) else { return }
        model.linkFailure = await model.open(link).message
    }
}


#if DEBUG
/// ImportOverSheetUITests: a share that arrives while Baton is away, the way the share
/// extension leaves one when someone shares from another app with Baton's player still open. The
/// test opens a screen, goes Home and comes back, and the real activation pickup finds it. Written
/// by the extension's own writer on the first trip to the background, once per launch.
/// Environment only.
@MainActor
enum UITestShareWhenAway {
    static let key = "uitestSharedTextWhenAway"
    private static var written = false
    static func writeOnce() {
        guard !written, let text = ProcessInfo.processInfo.environment[key], !text.isEmpty else { return }
        written = true
        _ = try? PendingShareInbox.shared?.writeText(text, originalName: "Shared While Away.txt")
    }
}
#endif

/// Carries a main-thread-only closure across a @Sendable boundary. Safe here because
/// the engine calls it via the main actor.
private struct UncheckedSendableBox: @unchecked Sendable {
    let value: () -> Void
    init(_ value: @escaping () -> Void) { self.value = value }
}
