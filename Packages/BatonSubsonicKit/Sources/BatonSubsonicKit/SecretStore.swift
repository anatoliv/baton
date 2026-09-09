import Foundation
import BatonSubsonicModels

/// An injectable at-rest secret store, so components that persist credentials don't write them as
/// plaintext and stay unit-testable without touching the real login Keychain. The production
/// default is the Keychain (via `NavidromeKeychain`); tests inject an in-memory store. This is the
/// secret-store seam the webhook store and the composition root reference.
@MainActor
public protocol SecretStore {
    /// The stored secret for `key`, or nil if absent.
    func secret(for key: String) -> String?
    /// Store `value` for `key`; a nil value deletes it.
    func setSecret(_ value: String?, for key: String)
    /// Whether `key`'s secret is present, absent, or could not be read at all.
    ///
    /// `secret(for:)` returns `String?`, and a caller holding only that cannot tell "you never
    /// saved one" from "the Keychain is locked". Collapsing the two is how a locked Keychain
    /// turned every webhook header value into `""`, which the next `persist()` wrote back —
    /// and an empty write here *deletes* the item. So a lock destroyed the secrets it could
    /// not read. `NavidromeKeychain.SecretAvailability` is the same distinction the Navidrome
    /// side already draws; this is the seam that lets other stores ask it too.
    func availability(for key: String) -> NavidromeKeychain.SecretAvailability
}

public extension SecretStore {
    /// The honest default for a store that cannot fail to read — an in-memory dictionary, a
    /// test double. Overridden by the Keychain-backed store, which genuinely can.
    func availability(for key: String) -> NavidromeKeychain.SecretAvailability {
        secret(for: key) == nil ? .missing : .present
    }
}

/// Keychain-backed secret store — the app default. Under XCTest, `NavidromeKeychain` auto-routes to
/// an in-memory store, so this is already test-safe; tests may still inject
/// `InMemorySecretStore` for explicit isolation.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func secret(for key: String) -> String? { NavidromeKeychain.secret(account: key) }

    public func availability(for key: String) -> NavidromeKeychain.SecretAvailability {
        NavidromeKeychain.availability(account: key)
    }

    public func setSecret(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            NavidromeKeychain.setSecret(value, account: key)
        } else {
            NavidromeKeychain.deleteSecret(account: key)
        }
    }
}

/// In-memory secret store for tests — never touches the Keychain.
public final class InMemorySecretStore: SecretStore {
    private var store: [String: String] = [:]
    public init() {}
    public func secret(for key: String) -> String? { store[key] }
    public func setSecret(_ value: String?, for key: String) {
        if let value, !value.isEmpty { store[key] = value } else { store[key] = nil }
    }
}
