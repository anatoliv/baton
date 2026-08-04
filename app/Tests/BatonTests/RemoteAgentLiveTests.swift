import XCTest
@testable import Baton

/// Live agent checks against a real model endpoint. **Skipped unless configured**,
/// so the normal suite stays offline, deterministic, and free.
///
/// The scripted tests in `RemoteAgentTests` prove Baton's control flow. They
/// cannot prove the two things that only a real provider can answer: that the
/// request body is one it accepts, and that a *multi-turn* transcript carrying
/// tool calls and their results survives the round trip. Those fail loudly in
/// production and silently in unit tests, which is the worst combination.
///
/// Enable it by writing `~/.baton-live-agent.json`, then deleting it afterwards:
///
///     umask 077 && cat > ~/.baton-live-agent.json <<EOF
///     {"base":"http://127.0.0.1:8000/v1","model":"chat",
///      "key":"$(security find-generic-password -s io.tonebox.secrets -a baton.remote.nl.apiKey -w)"}
///     EOF
///     ./scripts/test.sh -only-testing:BatonTests/RemoteAgentLiveTests
///     rm -f ~/.baton-live-agent.json
///
/// A file rather than an environment variable for two reasons: environment
/// variables do not reach an app-hosted test process (neither a plain `export`
/// nor Xcode's `TEST_RUNNER_` prefix, which is for UI-test runners), and a key
/// passed on a command line is visible in `ps` to anyone on the machine.
@MainActor
final class RemoteAgentLiveTests: XCTestCase {
    private struct Live {
        var config: RemoteControlSettings.NaturalLanguageConfig
    }

    private func live() throws -> Live {
        let path = NSHomeDirectory() + "/.baton-live-agent.json"
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: path),
            "live model not configured — see the doc comment"
        )

        guard let data = FileManager.default.contents(atPath: path),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let base = json["base"], let key = json["key"]
        else {
            throw XCTSkip("live config at \(path) is unreadable or missing base/key")
        }

        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.isAgentEnabled = true
        config.baseURL = base
        config.apiKey = key
        config.model = json["model"] ?? "chat"
        config.provider = (json["provider"] == "anthropic") ? .anthropic : .openAICompatible
        return Live(config: config)
    }

    /// A stand-in for the real library that reproduces the exact bug this work
    /// exists to fix: the literal words find nothing, and the same music is
    /// there under a different name. Real genre names, taken from a real
    /// library, so the model faces the problem it will actually face.
    private func libraryToolRunner(
        record: @escaping @MainActor (RemoteToolCall) -> Void
    ) -> RemoteAgent.ToolRunner {
        { call in
            record(call)
            switch call.name {
            case "music_search":
                guard case let .string(query)? = call.arguments["query"] else { return ("{}", false) }
                let q = query.lowercased()
                if q.contains("chill") || q.contains("lounge") || q.contains("ambient") || q.contains("relax") {
                    return (#"""
                    {"songs":[{"id":"s1","title":"Deep Rooftop Chillout","artist":"Unknown","duration_seconds":11168},
                    {"id":"s2","title":"RELAX LOUNGE CHILLOUT","artist":"Unknown","duration_seconds":23845}],
                    "albums":[],"artists":[]}
                    """#, false)
                }
                return (#"{"songs":[],"albums":[],"artists":[]}"#, false)
            case "music_list_genres":
                return (#"""
                {"genres":[{"name":"Music","song_count":5487},{"name":"Trance","song_count":107},
                {"name":"Electronic","song_count":105},{"name":"Gothic","song_count":68},
                {"name":"New Wave","song_count":68},{"name":"Eurodance","song_count":40},
                {"name":"House","song_count":38},{"name":"Ambient","song_count":22}]}
                """#, false)
            case "music_liked":
                return (#"{"songs":[{"id":"l1","title":"Evermore (Original Mix)","artist":"DIDO","rating":5}],"total_liked_songs":65}"#, false)
            case "music_play", "music_build_mix", "music_queue_add", "music_start_radio":
                return (#"{"playing":{"title":"Deep Rooftop Chillout","artist":"Unknown"},"queued":2}"#, false)
            default:
                return ("{}", false)
            }
        }
    }

    /// The headline case, end to end against a real model: the literal search
    /// finds nothing, and the agent has to notice and recover instead of
    /// reporting failure.
    func testItRecoversFromAnEmptySearchAgainstARealModel() async throws {
        let live = try live()
        var calls: [RemoteToolCall] = []

        let outcome = try await RemoteAgent.run(
            message: "find lazy music and play",
            history: [],
            playerContext: "Player state: nothing is playing right now.",
            config: live.config,
            tools: RemoteAgent.toolSchemas(),
            runTool: libraryToolRunner { calls.append($0) }
        )

        let trace = calls.map { call -> String in
            let arguments = call.arguments
                .map { "\($0.key)=\($0.value)" }
                .sorted().joined(separator: ",")
            return "\(call.name)(\(arguments))"
        }
        print("LIVE TRACE: \(trace.joined(separator: " → "))")
        print("LIVE REPLY: \(outcome.text)")
        if let choice = outcome.choice {
            print("LIVE ASKED: \(choice.rendered())")
        }

        // The mechanics, which are what this test can assert deterministically:
        // a real provider accepted a multi-turn transcript carrying tool calls
        // and their results, and the loop came back with something to say.
        XCTAssertFalse(outcome.text.isEmpty, "must always answer")
        XCTAssertFalse(calls.isEmpty, "an agent that calls nothing has not looked")

        // The behaviour under test. A search for the literal words is fine —
        // giving up after it is the bug. Either it found the music another way
        // or it asked; both beat "Nothing matched."
        let searched = calls.filter { $0.name == "music_search" }
        if searched.count == 1, calls.count == 1 {
            XCTFail("gave up after one empty search — the whole point was not to")
        }

        // "find lazy music **and play**" is a request to hear something. An
        // answer that describes playing without playing is the failure this
        // caught live, and it reads as success to anyone not watching the
        // speakers.
        let acted = calls.contains { ["music_play", "music_build_mix", "music_start_radio",
                                      "music_queue_add", "music_play_playlist"].contains($0.name) }
        XCTAssertTrue(acted || outcome.choice != nil, "promised playback without playing: \(trace)")
    }

    /// Multi-turn is the part a single-shot request never exercises: turn two
    /// must carry turn one's tool call *and* its result, in the dialect's exact
    /// shape, or the provider rejects the whole conversation.
    func testARealProviderAcceptsATranscriptCarryingToolResults() async throws {
        let live = try live()
        var turns = 0

        _ = try await RemoteAgent.run(
            message: "what genres do I have?",
            history: [
                .init(role: "user", text: "hello"),
                .init(role: "assistant", text: "Ready when you are."),
            ],
            playerContext: "Player state: nothing is playing right now.",
            config: live.config,
            tools: RemoteAgent.toolSchemas(),
            runTool: libraryToolRunner { _ in },
            turn: { messages, tools in
                turns += 1
                // Real round trip, with whatever transcript the loop has built.
                let step = try await RemoteAgent.requestTurn(
                    messages, tools: tools, config: live.config,
                    playerContext: "Player state: nothing is playing right now."
                )
                if turns > 1 {
                    // Getting here at all proves the provider accepted a
                    // transcript containing tool_use + tool_result blocks.
                    XCTAssertTrue(
                        messages.contains { $0.role == "tool_results" },
                        "the second turn must carry results"
                    )
                }
                return step
            }
        )
        XCTAssertGreaterThan(turns, 0)
    }
}
