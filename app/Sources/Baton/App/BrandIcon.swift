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
        let style = UserDefaults(suiteName: UserDefaults.globalDomain)?
            .string(forKey: "AppleInterfaceStyle")
        guard let icon = NSImage(named: style == "Dark" ? "DockIconDark" : "DockIconLight") else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
