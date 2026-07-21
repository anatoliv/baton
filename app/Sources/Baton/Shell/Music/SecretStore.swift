import Foundation

/// An injectable at-rest secret store, so components that persist credentials don't write them as
/// plaintext and stay unit-testable without touching the real login Keychain. The production
/// default is the Keychain (via `NavidromeKeychain`); tests inject an in-memory store. This is the
/// secret-store seam the webhook store and the composition root reference.
@MainActor
protocol SecretStore {
    /// The stored secret for `key`, or nil if absent.
    func secret(for key: String) -> String?
    /// Store `value` for `key`; a nil value deletes it.
    func setSecret(_ value: String?, for key: String)
}

/// Keychain-backed secret store — the app default. Under XCTest, `NavidromeKeychain` auto-routes to
/// an in-memory store, so this is already test-safe; tests may still inject
/// `InMemorySecretStore` for explicit isolation.
struct KeychainSecretStore: SecretStore {
    func secret(for key: String) -> String? { NavidromeKeychain.secret(account: key) }

    func setSecret(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            NavidromeKeychain.setSecret(value, account: key)
        } else {
            NavidromeKeychain.deleteSecret(account: key)
        }
    }
}

/// In-memory secret store for tests — never touches the Keychain.
final class InMemorySecretStore: SecretStore {
    private var store: [String: String] = [:]
    init() {}
    func secret(for key: String) -> String? { store[key] }
    func setSecret(_ value: String?, for key: String) {
        if let value, !value.isEmpty { store[key] = value } else { store[key] = nil }
    }
}
