import XCTest
@testable import BatonPlaybackKit

/// The guard for the failure that made this test necessary.
///
/// `PreferenceSync.syncedKeys` carried `baton.agent.provider`, `.model`, `.baseURL` and
/// `.route` from the day sync shipped. The phone wrote them. The Mac wrote
/// `baton.remote.nl.provider` and friends, and read nothing else — so it was absent from a
/// contract it appeared to be part of. Sync ran, reported success, and moved four settings
/// between devices that could not both participate.
///
/// Nothing failed to compile. Nothing threw. A green test suite said the feature worked, and
/// the only way to see otherwise was to own both devices and notice a model name not
/// arriving. That is the shape of bug worth spending a source-scanning test on: the two ends
/// are written independently, and the only thing keeping them together is that they spell a
/// string the same way.
///
/// The rule enforced here: **a setting stored under `baton.agent.*` is either synced, or
/// listed below as deliberately not synced, with a reason.** Adding a key to one app and
/// forgetting the other now fails here instead of in someone's hands.
@MainActor
final class SyncContractDriftTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Keys under the shared namespace that are intentionally *not* synced.
    private static let exempt: [String: String] = [
        "baton.agent.gatewayURL": "the transport itself — syncing it through the gateway is circular",
        "baton.agent.gatewayToken": "a secret; Keychain-resident and carried by pairing instead",
        "baton.agent.apiKey": "a secret; Keychain-resident and carried by pairing instead",
        "baton.agent.verifiedFingerprint": "records that *this* device tested *its* endpoint",
    ]

    private func sharedNamespaceKeys(in relativePath: String) throws -> Set<String> {
        let url = root.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        let pattern = #""(baton\.agent\.[A-Za-z0-9_.]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        var found: Set<String> = []
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: source) else { return }
            found.insert(String(source[r]))
        }
        return found
    }

    /// Every `baton.agent.*` key either app stores must be synced or explicitly exempt.
    func testNeitherAppStoresASharedKeyThatIsNotSynced() throws {
        let sources = [
            "Packages/BatonAgentKit/Sources/BatonAgentKit/RemoteControlConfig.swift",
            "ios/Sources/BatonMobile/AgentConfig.swift",
        ]
        for path in sources {
            for key in try sharedNamespaceKeys(in: path) {
                if Self.exempt[key] != nil { continue }
                XCTAssertTrue(
                    PreferenceSync.syncedKeys.contains(key),
                    """
                    \(path) stores "\(key)", which is neither in PreferenceSync.syncedKeys nor \
                    listed as exempt. Either add it to the sync list, or add it to `exempt` \
                    here with the reason it should not travel.
                    """
                )
            }
        }
    }

    /// The mirror image: a key in the contract that neither app stores is dead weight, and
    /// worse, it reads as a supported setting. Every synced `baton.agent.*` key must be
    /// written by at least one app.
    func testEverySharedSyncedKeyIsActuallyStoredBySomeone() throws {
        let mac = try sharedNamespaceKeys(in: "Packages/BatonAgentKit/Sources/BatonAgentKit/RemoteControlConfig.swift")
        let phone = try sharedNamespaceKeys(in: "ios/Sources/BatonMobile/AgentConfig.swift")
        let macViews = try sharedNamespaceKeys(in: "app/Sources/Baton/Shell/Music/MacMusicFriendView.swift")
        let stored = mac.union(phone).union(macViews)

        for key in PreferenceSync.syncedKeys where key.hasPrefix("baton.agent.") {
            XCTAssertTrue(
                stored.contains(key),
                """
                "\(key)" is in PreferenceSync.syncedKeys but no app stores it. A key nothing \
                writes is carried between devices forever and looks like a supported setting.
                """
            )
        }
    }

    /// The specific regression, named. The Mac must participate in the friend's config keys —
    /// this is the assertion that fails if it ever goes back to its own spelling.
    func testTheMacParticipatesInTheFriendsSyncedConfig() throws {
        let mac = try sharedNamespaceKeys(in: "Packages/BatonAgentKit/Sources/BatonAgentKit/RemoteControlConfig.swift")
        for key in ["baton.agent.provider", "baton.agent.model", "baton.agent.baseURL"] {
            XCTAssertTrue(
                mac.contains(key),
                "the Mac no longer stores \"\(key)\" — the friend's setup has stopped syncing with the phone"
            )
        }
    }
}
