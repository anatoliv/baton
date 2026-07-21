import Foundation
import OSLog
import ServiceManagement

/// Launch-at-login control, backed by `SMAppService.mainApp` (the modern, sandbox-safe replacement
/// for the deprecated `SMLoginItemSetEnabled`). Registering adds Baton to the user's login items so
/// its menu-bar controller is available right after boot; unregistering removes it.
enum LoginItem {
    private static let log = Logger(subsystem: "io.tonebox.baton", category: "login-item")

    /// Whether Baton is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether the OS lets us change this (a user can disable it in System Settings → General →
    /// Login Items, which we must not fight). `.requiresApproval` means the user has to approve it.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister the login item. Throws if the OS rejects the change (e.g. the user
    /// turned it off in System Settings); the caller surfaces that rather than silently flipping.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            log.notice("registered as a login item")
        } else {
            try SMAppService.mainApp.unregister()
            log.notice("unregistered as a login item")
        }
    }
}
