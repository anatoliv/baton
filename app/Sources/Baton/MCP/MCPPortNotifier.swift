import Foundation
import UserNotifications

/// Posts the macOS user notification for an MCP port move ("Port 8787 was in use. Baton is on
/// 8788. Update your MCP client, or use mcp.json."). Same authorization dance as
/// `SpeechNotifier`; a denied or undetermined-and-refused status simply drops it, since the
/// Settings pane carries the same notice and is the durable copy.
///
/// Not `@MainActor`: `UNUserNotificationCenter` is thread-safe, and the server calls this off
/// a detached task so a slow authorization prompt never blocks the bind.
enum MCPPortNotifier {
    static let categoryID = "baton.mcp.port-moved"

    static func post(_ notice: BatonMCPPortNotice) async {
        await SpeechNotifier.requestAuthorizationIfNeeded()
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Baton MCP port changed"
        content.body = notice.message
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(identifier: "\(categoryID).\(notice.bound)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
