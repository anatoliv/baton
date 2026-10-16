import Foundation

public struct ReactionPushAdvertisement: Codable, Equatable, Sendable {
    public var version: Int
    public var topics: [String: String]
    public init(version: Int, topics: [String: String]) { self.version = version; self.topics = topics }
    public func permits(topic: String, environment: String) -> Bool {
        version == 1 && topics.count <= 4 && topics[topic] == environment && ["sandbox", "production"].contains(environment)
    }
}

public enum ReactionPushOwnerRoute {
    /// Only the generic owner-list route. Reject unknown keys, especially content keys/URLs.
    public static func shareID(from data: Data) -> String? {
        guard data.count <= 4096, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(json.keys) == ["v", "route", "shareID"],
              let decoded = try? JSONDecoder().decode(Route.self, from: data),
              decoded.v == 1, decoded.route == "shared-links", ShareLink.isValidID(decoded.shareID) else { return nil }
        return decoded.shareID
    }
    private struct Route: Decodable { let v: Int; let route: String; let shareID: String }
}

/// Native-independent permission/token state. A remote advertisement alone cannot enable
/// collection: callers require reviewed signing configuration AND a real integrity provider.
@MainActor
public final class ReactionPushConsentCoordinator {
    public private(set) var optedIn: Bool
    public private(set) var available = false
    private var generation = 0
    private var authorized = false
    private let permission: @MainActor () async -> Bool
    private let register: @MainActor () -> Void
    private let unregister: @MainActor () -> Void
    private let persist: @MainActor (Bool) -> Void
    private let upload: @MainActor (Data) async throws -> Void
    private let remove: @MainActor () async throws -> Void

    public init(optedIn: Bool = false, permission: @escaping @MainActor () async -> Bool,
                register: @escaping @MainActor () -> Void, unregister: @escaping @MainActor () -> Void,
                persist: @escaping @MainActor (Bool) -> Void,
                upload: @escaping @MainActor (Data) async throws -> Void,
                remove: @escaping @MainActor () async throws -> Void) {
        self.optedIn = optedIn; self.permission = permission; self.register = register
        self.unregister = unregister; self.persist = persist; self.upload = upload; self.remove = remove
    }
    public func setAvailable(_ value: Bool) {
        available = value
        if !value { generation += 1; authorized = false; unregister() }
    }
    @discardableResult public func enableAfterExplicitAction() async -> Bool {
        guard available else { return false }
        generation += 1; let attempt = generation
        guard await permission(), generation == attempt, available else { return false }
        authorized = true; optedIn = true; persist(true); register(); return true
    }
    public func updateAuthorization(_ value: Bool) {
        if authorized && !value { generation += 1 }
        authorized = value
    }
    public func foreground(authorized: Bool) {
        updateAuthorization(authorized)
        guard optedIn, available, authorized else { unregister(); return }
        register() // APNs supplies a fresh token; never restore raw token bytes from disk.
    }
    public func receive(token: Data) async throws {
        guard optedIn, available, authorized, (1 ... 1024).contains(token.count) else { return }
        let attempt = generation
        try await upload(token)
        // A late registration cannot silently undo a user's opt-out.
        if attempt != generation, !optedIn || !authorized || !available { try await remove() }
    }
    public func disable() async throws {
        generation += 1; authorized = false; optedIn = false; persist(false); unregister()
        try await remove()
    }
}
