import BatonShareKit
import Foundation
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Supplied by a reviewed integrity integration, never a bearer-only or synthetic default.
@MainActor
protocol NativeReactionPushIntegrity: AnyObject {
    func proof(deviceID: UUID, token: Data, topic: String, environment: String) async throws -> Data
}

@MainActor
@Observable
final class ReactionPushNotifications: NSObject {
    static let shared = ReactionPushNotifications()
    struct Activation {
        // Must match the actual signed/profile APNs topic/environment before injection.
        let topic: String
        let environment: String
        let integrity: any NativeReactionPushIntegrity
    }
    private var activation: Activation?
    private(set) var available = false
    private(set) var optedIn = BatonStorage.defaults.bool(forKey: "baton.share.reactionPush.optedIn")
    private(set) var failure: String?
    private var pendingOwnerList = false
    @ObservationIgnored private var ownerPresentationTask: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private weak var ownerListController: UIViewController?
    #endif
    #if os(macOS)
    private var ownerWindow: NSWindowController?
    #endif
    private var deviceID: UUID {
        let defaults = BatonStorage.defaults
        if let raw = defaults.string(forKey: "baton.share.reactionPush.deviceID"), let id = UUID(uuidString: raw) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: "baton.share.reactionPush.deviceID"); return id
    }
    @ObservationIgnored private var consentStorage: ReactionPushConsentCoordinator?
    private var consent: ReactionPushConsentCoordinator {
        if let consentStorage { return consentStorage }
        let value = makeConsent()
        consentStorage = value
        return value
    }
    // Construct under the class's MainActor, rather than a lazy-property initializer thunk.
    private func makeConsent() -> ReactionPushConsentCoordinator {
        ReactionPushConsentCoordinator(optedIn: optedIn,
        permission: {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                return (try? await center.requestAuthorization(options: [.alert])) == true
            }
            return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }, register: {
            #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            #elseif os(macOS)
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }, unregister: {
            #if os(iOS)
            UIApplication.shared.unregisterForRemoteNotifications()
            #elseif os(macOS)
            NSApplication.shared.unregisterForRemoteNotifications()
            #endif
        }, persist: { [weak self] value in
            self?.optedIn = value
            BatonStorage.defaults.set(value, forKey: "baton.share.reactionPush.optedIn")
        }, upload: { [weak self] token in
            guard let self, let activation = self.activation, self.available, self.optedIn,
                  let client = SongSharing.shared.existingClientForReactionPush() else { return }
            let proof = try await activation.integrity.proof(deviceID: self.deviceID, token: token,
                topic: activation.topic, environment: activation.environment)
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            let authorized = status == .authorized || status == .provisional
            self.consent.updateAuthorization(authorized)
            guard self.available, self.optedIn, authorized else { return }
            try await client.registerReactionDevice(deviceID: self.deviceID, token: token,
                topic: activation.topic, environment: activation.environment, proof: proof)
        }, remove: { [weak self] in
            guard let self else { return }
            BatonStorage.defaults.set(true, forKey: "baton.share.reactionPush.pendingOptOut")
            guard let client = SongSharing.shared.existingClientForReactionPush() else { return }
            try await client.unregisterReactionDevice(deviceID: self.deviceID)
            BatonStorage.defaults.set(false, forKey: "baton.share.reactionPush.pendingOptOut")
        })
    }

    // No shipping caller supplies this. Remote configuration cannot construct an integrity
    // provider or establish signed entitlement provenance by itself.
    func configure(_ reviewedActivation: Activation) { activation = reviewedActivation }

    func refreshAvailability() async {
        guard let activation, let client = SongSharing.shared.existingClientForReactionPush(),
              let config = try? await client.config(), config.enabled,
              config.reactionPush?.permits(topic: activation.topic, environment: activation.environment) == true
        else { available = false; consent.setAvailable(false); return }
        available = true; consent.setAvailable(true)
    }
    func setOptIn(_ value: Bool) async {
        failure = nil
        if value {
            await refreshAvailability()
            let enabled = available ? await consent.enableAfterExplicitAction() : false
            if !enabled {
                failure = "Reaction notifications are unavailable or permission was not granted."
            }
        } else {
            do { try await consent.disable() }
            catch { failure = "Notifications are off on this device. Server opt-out will be retried when Baton opens." }
        }
    }
    func foreground() async {
        await refreshAvailability()
        if !available { consent.setAvailable(false) }
        if BatonStorage.defaults.bool(forKey: "baton.share.reactionPush.pendingOptOut") {
            do { try await consent.disable() } catch { failure = "Server opt-out is still pending." }
        }
        if available && optedIn {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            consent.foreground(authorized: status == .authorized || status == .provisional)
        }
        requestOwnerListPresentation()
    }
    func didRegister(token: Data) {
        guard available, optedIn else { return }
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            consent.updateAuthorization(status == .authorized || status == .provisional)
            do { try await consent.receive(token: token); failure = nil }
            catch { failure = "Reaction notifications could not be registered. Try again when Baton opens." }
        }
    }
    func registrationFailed() { if optedIn { failure = "Reaction notifications could not be registered." } }

    /// No supplied key/URL/title is accepted. This opens an authenticated owner-list refresh,
    /// never a shared-song decoder or direct playback route.
    func handleOwnerRoute(_ data: Data) {
        guard optedIn, ReactionPushOwnerRoute.shareID(from: data) != nil else { return }
        pendingOwnerList = true
        Task { await SongSharing.shared.refresh() }
        requestOwnerListPresentation()
    }
    private func requestOwnerListPresentation() {
        guard pendingOwnerList, ownerPresentationTask == nil else { return }
        ownerPresentationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.ownerPresentationTask = nil }
            for _ in 0 ..< 20 {
                guard !Task.isCancelled, self.pendingOwnerList else { return }
                self.presentOwnerListIfPossible()
                if self.pendingOwnerList { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
            // Preserve the request if the app/scene is still transitioning; next foreground retries.
        }
    }
    private func presentOwnerListIfPossible() {
        guard pendingOwnerList else { return }
        #if os(iOS)
        if let ownerListController, ownerListController.presentingViewController != nil {
            pendingOwnerList = false; return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !presenter.isBeingDismissed, !presenter.isBeingPresented else { return }
        let controller = UIHostingController(rootView: ReactionPushOwnerListScreen(onDone: {}))
        controller.rootView = ReactionPushOwnerListScreen(onDone: { [weak controller] in controller?.dismiss(animated: true) })
        controller.modalPresentationStyle = .pageSheet
        ownerListController = controller
        presenter.present(controller, animated: true)
        #elseif os(macOS)
        if let ownerWindow { ownerWindow.showWindow(nil); ownerWindow.window?.makeKeyAndOrderFront(nil) }
        else {
            let controller = NSHostingController(rootView: ReactionPushOwnerListScreen(onDone: { [weak self] in self?.ownerWindow?.close() }))
            let window = NSWindow(contentViewController: controller)
            window.title = "Shared Links"; window.setContentSize(NSSize(width: 540, height: 560))
            ownerWindow = NSWindowController(window: window); ownerWindow?.showWindow(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
        pendingOwnerList = false
    }

    nonisolated static func routeData(_ info: [AnyHashable: Any]) -> Data? {
        guard let route = info["baton"] as? [String: Any], JSONSerialization.isValidJSONObject(route),
              let data = try? JSONSerialization.data(withJSONObject: route), data.count <= 4096,
              ReactionPushOwnerRoute.shareID(from: data) != nil else { return nil }
        return data
    }
}

private struct ReactionPushOwnerListScreen: View {
    let onDone: () -> Void
    var body: some View {
        NavigationStack {
            SharedLinksView().toolbar { Button("Done", action: onDone) }
        }.defaultAppStorage(BatonStorage.defaults)
    }
}

/// iOS has no speech-notification delegate; macOS routes through its existing one instead.
final class ReactionPushNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard ReactionPushNotifications.routeData(notification.request.content.userInfo) != nil else { return [] }
        return await ReactionPushNotifications.shared.optedIn ? [.banner] : []
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let data = ReactionPushNotifications.routeData(response.notification.request.content.userInfo) else { return }
        await ReactionPushNotifications.shared.handleOwnerRoute(data)
    }
}
