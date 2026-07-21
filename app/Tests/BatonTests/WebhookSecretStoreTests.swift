import XCTest
@testable import Baton

/// W-51 / SEC-19: webhook header values (which can carry an Authorization secret) are stored in the
/// injectable SecretStore, never in the plaintext defaults plist, and re-injected on load.
@MainActor
final class WebhookSecretStoreTests: XCTestCase {
    private func store(_ defaults: UserDefaults, _ secrets: InMemorySecretStore) -> WebhookActionStore {
        WebhookActionStore(defaults: defaults, secrets: secrets, send: { _ in 200 })
    }

    private func action(headerValue: String) -> WebhookAction {
        var a = WebhookAction(name: "Notify", urlTemplate: "https://hooks.example.com/x")
        a.headers = [.init(name: "Authorization", value: headerValue)]
        return a
    }

    func testHeaderValueGoesToTheSecretStoreNotPlaintextDefaults() {
        let defaults = UserDefaults(suiteName: "wh-\(UUID().uuidString)")!
        let secrets = InMemorySecretStore()
        let s = store(defaults, secrets)
        let a = action(headerValue: "Bearer super-secret-token")
        s.upsert(a)

        let blob = try! XCTUnwrap(defaults.data(forKey: "tonebox.webhookActions"))
        let json = String(decoding: blob, as: UTF8.self)
        XCTAssertFalse(json.contains("super-secret-token"), "the token must NOT be in the cleartext defaults plist")

        let key = "tonebox.webhook.header.\(a.headers[0].id.uuidString)"
        XCTAssertEqual(secrets.secret(for: key), "Bearer super-secret-token", "the token lives in the secret store")
    }

    func testReloadReinjectsHeaderValue() {
        let defaults = UserDefaults(suiteName: "wh-\(UUID().uuidString)")!
        let secrets = InMemorySecretStore()
        let a = action(headerValue: "Bearer tok")
        store(defaults, secrets).upsert(a)

        // A fresh store over the same defaults + secrets rehydrates the header value for editing/sending.
        let reloaded = store(defaults, secrets)
        XCTAssertEqual(reloaded.actions.first?.headers.first?.value, "Bearer tok")
    }

    func testDeleteRemovesHeaderSecret() {
        let defaults = UserDefaults(suiteName: "wh-\(UUID().uuidString)")!
        let secrets = InMemorySecretStore()
        let s = store(defaults, secrets)
        let a = action(headerValue: "v")
        s.upsert(a)
        let key = "tonebox.webhook.header.\(a.headers[0].id.uuidString)"
        XCTAssertNotNil(secrets.secret(for: key))
        s.delete(a)
        XCTAssertNil(secrets.secret(for: key), "deleting the action clears its header secret")
    }
}
