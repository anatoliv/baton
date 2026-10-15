import BatonDocuments
import BatonSubsonicKit
import Foundation
import Testing
@testable import Baton

/// The Mac's book synthesizer is the hosts in Settings → Speech, and it passes a chapter's
/// expressive style through to the package (M8.7). The package's own tests pin what the style
/// does to the request (`PronunciationAndStyleTests`: a styled Chatterbox request goes to
/// `/tts` with `exaggeration` and `cfg_weight`); these pin the Mac's side of it.
@MainActor
@Suite("Configured speech synthesizer")
struct ConfiguredSpeechSynthesizerTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = ThrowawayDefaults.name("speech-synth")
        let defaults = UserDefaults(suiteName: suite)!
        let saved = SpeechConfig.defaults
        SpeechConfig.defaults = defaults
        defer {
            SpeechConfig.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        try body(defaults)
    }

    @Test("Both engines come from Settings, and a blank host is left out")
    func enginesFollowSettings() throws {
        try withDefaults { _ in
            SpeechConfig.kokoroBaseURL = "http://kokoro.test:8880"
            SpeechConfig.chatterboxBaseURL = "http://chatterbox.test:8183"
            let engines = ConfiguredSpeechSynthesizer.engines()
            #expect(engines["kokoro"] == URL(string: "http://kokoro.test:8880"))
            #expect(engines["chatterbox"] == URL(string: "http://chatterbox.test:8183"))

            SpeechConfig.chatterboxBaseURL = "   "
            #expect(ConfiguredSpeechSynthesizer.engines()["chatterbox"] == nil)
            #expect(ConfiguredSpeechSynthesizer.engines()["kokoro"] != nil)
        }
    }

    @Test("A style for an engine with no host fails as a missing host, not a crash")
    func styledRequestWithoutHostIsPermanent() async throws {
        try await withDefaultsAsync {
            SpeechConfig.kokoroBaseURL = "http://kokoro.test:8880"
            SpeechConfig.chatterboxBaseURL = ""
            let synthesizer: any SpeechSynthesizing = ConfiguredSpeechSynthesizer()
            do {
                _ = try await synthesizer.synthesize(text: "Hello.", voice: "chatterbox:Abigail.wav", speed: nil,
                                                     style: SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3))
                Issue.record("a Chatterbox voice without a host should not synthesize")
            } catch let error as SynthesisError {
                guard case .permanent(let why) = error else { Issue.record("expected a permanent failure, got \(error)"); return }
                #expect(why.contains("chatterbox"))
            }
        }
    }

    private func withDefaultsAsync(_ body: () async throws -> Void) async rethrows {
        let suite = ThrowawayDefaults.name("speech-synth")
        let defaults = UserDefaults(suiteName: suite)!
        let saved = SpeechConfig.defaults
        SpeechConfig.defaults = defaults
        defer {
            SpeechConfig.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
    }
}
