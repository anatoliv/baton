import AppKit
import OSLog
import Sparkle
import SwiftUI

/// Thin wrapper around Sparkle's standard updater so SwiftUI can drive the
/// "Check for Updates" button and the "Automatically check" toggle.
///
/// Created lazily (on first access), and only ever reached from UI that is
/// gated on `UpdateChannel.isConfiguredFromBundle`, so the SPUUpdater is never
/// started with a placeholder key at launch. Baton's Settings window is a plain
/// window (not floating), so no window-level coordination is needed, unlike
/// Tonebox's floating Settings.
@MainActor
@Observable
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    let controller: SPUStandardUpdaterController
    @ObservationIgnored private let eventLogger = UpdaterEventLogger()

    /// Last update check outcome, surfaced in About → Diagnostics so a broken appcast URL is
    /// visible to the user AND the developer instead of failing silently.
    private(set) var lastCheckDate: Date?
    private(set) var lastCheckResult: String?
    private(set) var lastError: String?

    private init() {
        eventLogger.onEvent = { _ in } // replaced below once self exists
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: eventLogger,
            userDriverDelegate: nil
        )
        eventLogger.onEvent = { [weak self] event in
            guard let self else { return }
            self.lastCheckDate = Date()
            switch event {
            case let .foundValid(version):
                self.lastCheckResult = "Update available: \(version)"
                self.lastError = nil
            case .upToDate:
                self.lastCheckResult = "Up to date"
                self.lastError = nil
            case let .failed(message):
                self.lastCheckResult = "Check failed"
                self.lastError = message
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyCheckForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

/// Bridges Sparkle's `SPUUpdaterDelegate` callbacks to a log line (`Log.updates`) and a single
/// `onEvent` closure, so update outcomes are recorded rather than silently swallowed. Kept as a
/// distinct `NSObject` because `SparkleUpdater` is a value-semantics `@Observable`, not an NSObject.
///
final class UpdaterEventLogger: NSObject, SPUUpdaterDelegate {
    /// A normalized update outcome the UI can render.
    enum Event {
        case foundValid(String)
        case upToDate
        case failed(String)
    }

    private static let log = Logger(subsystem: "io.tonebox.baton", category: "updates")
    @MainActor var onEvent: (Event) -> Void = { _ in }

    private func emit(_ event: Event) {
        Task { @MainActor in self.onEvent(event) }
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Self.log.notice("appcast loaded: \(appcast.items.count) item(s)")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.log.notice("found update: \(item.displayVersionString, privacy: .public)")
        emit(.foundValid(item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Self.log.notice("no update found — up to date")
        emit(.upToDate)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle reports "user cancelled" as an abort; don't surface that as a failure.
        let nsError = error as NSError
        if nsError.code == Int(Sparkle.SUError.installationCanceledError.rawValue) { return }
        Self.log.error("update aborted: \(error.localizedDescription, privacy: .public)")
        emit(.failed(error.localizedDescription))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.log.error("update download failed: \(error.localizedDescription, privacy: .public)")
        emit(.failed(error.localizedDescription))
    }
}

/// `CommandGroup` that adds "Check for Updates…" to the app menu, in the
/// standard macOS slot directly under "About Baton" (`.appInfo`). Enabled once
/// the update channel is live (signing key + https feed + auto-checks), which it
/// is as of 0.1.0 — `isConfiguredFromBundle` gates it, so it stays disabled only
/// in an unconfigured build where checking would fail anyway.
struct UpdatesMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                SparkleUpdater.shared.checkForUpdates()
            }
            .disabled(!UpdateChannel.isConfiguredFromBundle)
        }
    }
}
