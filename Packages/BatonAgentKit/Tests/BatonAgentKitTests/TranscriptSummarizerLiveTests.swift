import Foundation
import XCTest
@testable import BatonAgentKit
import BatonDocuments
import BatonSubsonicModels

/// The transcript summarizer against a real model, end to end, over the OpenAI-compatible path
/// the Settings → Remote model uses: `TranscriptSummarizer` → `HTTPModelClient` → Ollama's
/// `/v1/chat/completions`.
///
/// Opt-in, like `VoiceCasterLiveTests` and with the same variables: set `BATON_LIVE_OLLAMA_MODEL`
/// (and `BATON_LIVE_OLLAMA_URL` if it is not on this machine). It **skips** unless the model
/// answers a trivial prompt first, because a host that is up but still loading answers nonsense
/// (CLAUDE.md, *The conversation eval*).
final class TranscriptSummarizerLiveTests: XCTestCase {
    private func liveConfig() async throws -> RemoteControlSettings.NaturalLanguageConfig {
        guard let model = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_MODEL"] else {
            throw XCTSkip("set BATON_LIVE_OLLAMA_MODEL to run against a real model")
        }
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.provider = .openAICompatible
        config.baseURL = (ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434") + "/v1"
        config.model = model
        config.apiKey = ""

        let probe = try HTTPModelClient.request(for: TranscriptSummarizer.modelSource(for: config),
                                                system: "Answer with one word.", user: "Say OK.", apiKey: nil,
                                                timeout: 120, temperature: nil)
        guard let answer = try? await HTTPModelClient.send(probe, provider: .openAICompatible),
              answer.lowercased().contains("ok") else {
            throw XCTSkip("\(model) at \(config.baseURL) did not answer a trivial prompt; not measurable")
        }
        return config
    }

    func testSummarizesARealTranscriptIntoSectionsAndAnOverview() async throws {
        let config = try await liveConfig()
        let first = "Today we are talking about backups for a home server. My guest lost a RAID array last year "
            + "when two disks failed in the same week, and she had no copy anywhere else."
        let second = "After that she set up a nightly copy to a friend's house over a VPN, and tests a restore "
            + "every month, because a backup you have never restored is only a hope."
        let transcript = Transcript(trackID: "live", segments: [
            .init(start: 0, end: 300, text: first), .init(start: 300, end: 600, text: second),
        ])

        let started = Date()
        let summary = try await TranscriptSummarizer.summarize(transcript, config: config, windowSeconds: 300)
        let seconds = Date().timeIntervalSince(started)

        XCTAssertEqual(summary.sections.count, 2, "one section per window")
        XCTAssertTrue(summary.sections.allSatisfy { !$0.text.isEmpty }, "no section may be blank")
        XCTAssertFalse(summary.overview.isEmpty)
        XCTAssertEqual(summary.model, config.model)
        print("LIVE summary in \(Int(seconds)) s: \(summary.sections.map(\.title)) / \(summary.overview)")
    }
}
