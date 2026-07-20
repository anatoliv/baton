import AppKit
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

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyCheckForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

/// `CommandGroup` that adds "Check for Updates…" to the app menu, in the
/// standard macOS slot directly under "About Baton" (`.appInfo`). Disabled
/// until a real update channel is published (signing key + live feed),
/// matching the Settings pane, checking would only ever fail otherwise.
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
