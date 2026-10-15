import UIKit

/// Private generated Debug test host only. No normal Baton model, delegates,
/// background session, widget bridge, preferences or credential store is linked.
@main
@MainActor
final class AppAttestPhysicalHost: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard (try? PhysicalAttestProbeStorage.suite()) != nil else { return false }
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
