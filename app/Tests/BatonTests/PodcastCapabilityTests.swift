import XCTest
@testable import Baton

/// Coverage for `PodcastCapabilityStore` — the gate that hides the Podcasts tab on servers
/// (like Navidrome) that don't implement the Subsonic podcast API. Focuses on error
/// classification and the per-server persisted verdict; the network probe itself is exercised
/// via the client tests.
@MainActor
final class PodcastCapabilityTests: XCTestCase {
    // MARK: - Classification

    /// HTTP 501 (Navidrome's answer for an unimplemented endpoint) and 404 mean "this server
    /// has no podcast API" — a durable verdict that hides the tab.
    func testHTTP501And404ClassifyAsUnsupported() {
        XCTAssertEqual(PodcastCapabilityStore.classify(NavidromeError.http(status: 501)), .unsupported)
        XCTAssertEqual(PodcastCapabilityStore.classify(NavidromeError.http(status: 404)), .unsupported)
    }

    /// Transient / unrelated failures must NOT hide the tab — they say nothing about whether
    /// the server supports podcasts, so classification returns nil (leave support unknown).
    func testTransientErrorsAreInconclusive() {
        XCTAssertNil(PodcastCapabilityStore.classify(NavidromeError.unauthorized))
        XCTAssertNil(PodcastCapabilityStore.classify(NavidromeError.transport("offline")))
        XCTAssertNil(PodcastCapabilityStore.classify(NavidromeError.decoding("bad json")))
        XCTAssertNil(PodcastCapabilityStore.classify(NavidromeError.http(status: 500)))
        // A real Subsonic protocol error reached the handler — surface it, don't hide the tab.
        XCTAssertNil(PodcastCapabilityStore.classify(NavidromeError.subsonic(code: 70, message: "Not found")))
        // A non-Navidrome error type is inconclusive too.
        XCTAssertNil(PodcastCapabilityStore.classify(URLError(.timedOut)))
    }

    // MARK: - record() persistence

    /// `record(.unsupported)` flips `support` and persists the verdict for the active server so
    /// a later session skips the network probe.
    func testRecordPersistsPerServerVerdict() async throws {
        let defaults = try makeDefaults()
        let serverID = try activateServer(in: defaults)
        let store = PodcastCapabilityStore(defaults: defaults)

        XCTAssertEqual(store.support, .unknown)
        store.record(.unsupported)
        XCTAssertEqual(store.support, .unsupported)

        // A fresh store for the same server reads the remembered verdict — no probe needed.
        let reborn = PodcastCapabilityStore(defaults: defaults)
        await reborn.probeIfNeeded()
        XCTAssertEqual(reborn.support, .unsupported)
        _ = serverID
    }

    /// `record(.unknown)` is a no-op — we never persist "don't know."
    func testRecordUnknownIsIgnored() throws {
        let defaults = try makeDefaults()
        _ = try activateServer(in: defaults)
        let store = PodcastCapabilityStore(defaults: defaults)
        store.record(.unknown)
        XCTAssertEqual(store.support, .unknown)
    }

    /// W-36 / POD-08: an "unsupported" verdict expires after the TTL so a server that later
    /// gains podcast support is re-probed instead of hidden forever.
    func testUnsupportedVerdictExpires() throws {
        let defaults = try makeDefaults()
        let serverID = try activateServer(in: defaults)
        PodcastCapabilityStore.now = { Date(timeIntervalSince1970: 1_000_000) }
        defer { PodcastCapabilityStore.now = { Date() } }
        let store = PodcastCapabilityStore(defaults: defaults)
        store.record(.unsupported) // stamped at 1_000_000
        XCTAssertEqual(store.persisted(for: serverID), false, "within TTL the verdict is remembered")
        PodcastCapabilityStore.now = { Date(timeIntervalSince1970: 1_000_000 + 8 * 86_400) }
        XCTAssertNil(store.persisted(for: serverID), "past TTL the unsupported verdict is re-probed")
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> UserDefaults {
        let suite = "io.tonebox.tests.podcast.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Points `NavidromeConfig` at a throwaway server so `activeServerID()` returns a stable id
    /// the capability store can key on. Restores the previous config store on teardown.
    private func activateServer(in defaults: UserDefaults) throws -> UUID {
        let previous = NavidromeConfig.defaults
        NavidromeConfig.defaults = defaults
        addTeardownBlock { NavidromeConfig.defaults = previous }
        let entry = NavidromeConfig.addServer(
            displayName: "Home",
            urlString: "https://music.example.com",
            username: "joe",
            secret: "sesame",
            authMode: .tokenSalt
        )
        return entry.id
    }
}
