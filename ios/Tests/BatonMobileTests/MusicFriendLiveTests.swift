import BatonPlaybackKit
import XCTest
@testable import BatonMobile

/// Music Friend, against a real model.
///
/// This feature had never been exercised on the phone. Every audit so far opened
/// `Settings → Music Friend`, saw a screen, and moved on — but the Friend tab only appears
/// once a connection test passes, so no run had ever configured a provider, sent a message,
/// or seen a tool fire. "The settings screen exists" was standing in for "the headline
/// feature works", which is the same mistake that had the equalizer's presets scored as
/// shipped while they changed nothing.
///
/// Opt-in through the same `~/.baton-live-agent.json` the Mac's `RemoteAgentLiveTests` uses
/// — no new secret, and nothing on a command line. Skips when the file is absent or the
/// provider is asleep, because someone else's downtime is not a broken build.
@MainActor
final class MusicFriendLiveTests: XCTestCase {
    private struct Live {
        let base: String
        let key: String
        let model: String
    }

    private func live() throws -> Live {
        // The simulator can read the host filesystem, which is what makes this possible
        // without shipping a key into the test bundle. `NSHomeDirectory()` is no use here —
        // inside the simulator that is the app's sandbox, not the person's home — but the
        // simulator exports the real one as `SIMULATOR_HOST_HOME`. This was a hardcoded
        // `/Users/you/…`, which published a name and worked on exactly one machine.
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let path = "\(home)/.baton-live-agent.json"
        try XCTSkipIf(!FileManager.default.isReadableFile(atPath: path),
                      "no live agent config — skipping")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let base = json["base"], let key = json["key"]
        else { throw XCTSkip("live config unreadable") }
        try skipUnlessReachable(base)
        return Live(base: base, key: key, model: json["model"] ?? "chat")
    }

    private func skipUnlessReachable(_ base: String) throws {
        guard let url = URL(string: base) else { throw XCTSkip("bad base URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = response != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 8)
        try XCTSkipIf(!reachable, "live provider isn't answering — skipping rather than failing")
    }

    private func configured(_ live: Live) -> MobileModel {
        let model = MobileModel()
        model.agentConfig.route = .direct
        model.agentConfig.provider = .openAICompatible
        model.agentConfig.baseURL = live.base
        model.agentConfig.apiKey = live.key
        model.agentConfig.model = live.model
        return model
    }

    // MARK: - It answers at all

    func testTheFriendAnswersAnOrdinaryQuestion() async throws {
        let live = try live()
        let model = configured(live)

        let reply = try await model.agent.send("hello, who are you?")

        XCTAssertFalse(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "an empty reply is indistinguishable from a broken feature")
    }

    /// The point of the friend is that its hands are the player. A reply that merely
    /// *describes* playing something is the failure mode the Mac's eval was built to catch.
    func testAskingForMusicReachesTheTools() async throws {
        let live = try live()
        let model = configured(live)
        model.startDemo()

        let reply = try await model.agent.send("play something")

        XCTAssertGreaterThan(reply.toolCallsMade, 0,
                             "asking for music must call a tool, not just talk about it — got: \(reply.text)")
    }

    // MARK: - The gate in front of the tab

    /// The tab is hidden until a configuration has been tested, and the fingerprint is what
    /// makes that honest: change the model or the key and the tab must disappear until it
    /// is proven again, or the app is offering a feature against settings nobody verified.
    func testTheFriendTabStaysHiddenUntilTheConfigurationIsProven() throws {
        let live = try live()
        let model = configured(live)

        XCTAssertFalse(model.agentConfig.isReady, "untested configuration must not unlock the tab")
        model.agentConfig.markVerified()
        XCTAssertTrue(model.agentConfig.isReady)

        model.agentConfig.model = "something-else"
        XCTAssertFalse(model.agentConfig.isReady,
                       "editing the configuration must retire the tab until it is tested again")
    }

    func testAnUnconfiguredFriendRefusesRatherThanHanging() async throws {
        let model = MobileModel()
        model.agentConfig.baseURL = ""
        model.agentConfig.apiKey = ""

        do {
            _ = try await model.agent.send("play something")
            XCTFail("an unconfigured agent must throw, not silently do nothing")
        } catch {
            // Any error is fine; hanging or succeeding is not.
        }
    }
}
