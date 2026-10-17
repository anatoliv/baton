import AppKit
import Foundation

/// Keeps the running Dock identity in step with macOS, independently of window themes.
@MainActor
final class BrandIcon {
    static let shared = BrandIcon()
    private var observer: (any NSObjectProtocol)?

    private init() {}

    func start() {
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
        apply()
    }

    private func apply() {
        // Read only macOS's global appearance key, independently of application defaults.
        let style = CFPreferencesCopyValue(
            "AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? String
        guard let icon = NSImage(named: style == "Dark" ? "DockIconDark" : "DockIconLight") else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
