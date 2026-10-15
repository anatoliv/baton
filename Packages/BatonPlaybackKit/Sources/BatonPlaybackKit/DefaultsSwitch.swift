import BatonSubsonicKit
import Foundation
import Observation

/// A yes/no preference read **live**: whoever holds one sees a change the moment it is stored,
/// from Settings or from anywhere else, with no relaunch.
///
/// Written for `baton.documents.enabled`, whose readers each called a static
/// `isEnabled()` once and kept the answer: the File menu, the Clippings view and the launch-time
/// start of the book renderer all needed a relaunch to notice the Settings toggle. `@AppStorage`
/// is not used for it because a key with dots in it is a key path to key-value observing, so a
/// change stored elsewhere does not reach a dotted `@AppStorage`; this listens to
/// `UserDefaults.didChangeNotification` for its own defaults instead and rereads the one key.
///
/// An absent key reads as `defaultValue`, so "on unless turned off" stays true on a fresh install.
@MainActor
@Observable
public final class DefaultsSwitch {
    /// The stored value, or the default when nothing is stored.
    public private(set) var isOn: Bool

    @ObservationIgnored public let key: String
    @ObservationIgnored private let defaultValue: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var handlers: [@MainActor (Bool) -> Void] = []
    @ObservationIgnored private var token: ObserverToken?

    public init(key: String, defaultValue: Bool, defaults: UserDefaults = BatonStorage.defaults) {
        self.key = key
        self.defaultValue = defaultValue
        self.defaults = defaults
        isOn = Self.read(key, defaultValue, defaults)
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            // Posted on whichever thread stored the change: at once on the main thread, so a
            // reader sees the new value straight after the write, else by a hop.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.reread() }
            } else {
                Task { @MainActor in self?.reread() }
            }
        }
        token = ObserverToken(observer)
    }

    /// Run `handler` with the new value each time it changes (not for the value at the start).
    public func onChange(_ handler: @escaping @MainActor (Bool) -> Void) {
        handlers.append(handler)
    }

    /// Read the key again, and tell the handlers when the answer moved.
    public func reread() {
        let now = Self.read(key, defaultValue, defaults)
        guard now != isOn else { return }
        isOn = now
        for handler in handlers { handler(now) }
    }

    private static func read(_ key: String, _ defaultValue: Bool, _ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Removes the observer when the switch goes, from a plain class so the main-actor switch
    /// needs no `deinit` of its own.
    private final class ObserverToken: @unchecked Sendable {
        let observer: NSObjectProtocol
        init(_ observer: NSObjectProtocol) { self.observer = observer }
        deinit { NotificationCenter.default.removeObserver(observer) }
    }
}
