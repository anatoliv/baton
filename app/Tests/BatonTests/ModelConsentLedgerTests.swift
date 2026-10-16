import BatonAgentKit
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// The consent ledger for cloud model sources (M4.6): stored per source and kind of content in
/// this Mac's preferences, revocable, read by the router, and the reason a document surface
/// gives when it skipped a cloud source.
final class ModelConsentLedgerTests: XCTestCase {
    private let anthropic = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com",
                                        model: "claude-opus-5", contextTokens: 8_192)
    private let ollama = ModelSource(name: "qwen3:8b on this Mac", provider: .ollama, baseURL: "http://127.0.0.1:11434",
                                     model: "qwen3:8b", contextTokens: 8_192)

    func testGrantRevokeAndDeclineAreRecordedPerKind() {
        let defaults = ThrowawayDefaults.make("consent-ledger")
        let ledger = ModelConsentLedger(defaults: defaults)
        XCTAssertFalse(ledger.allows(anthropic, .excerpt))
        XCTAssertFalse(ledger.hasAnswered(anthropic, .excerpt))

        ledger.grant(anthropic, .excerpt)
        XCTAssertTrue(ledger.allows(anthropic, .excerpt))
        XCTAssertFalse(ledger.allows(anthropic, .chapter), "chapters are their own question")
        XCTAssertTrue(ModelConsentLedger(defaults: defaults).allows(anthropic, .excerpt), "kept across a relaunch")
        XCTAssertEqual(defaults.stringArray(forKey: ModelConsentLedger.grantedKey), ["anthropic|api.anthropic.com#excerpt"])

        ledger.revoke(anthropic, .excerpt)
        XCTAssertFalse(ledger.allows(anthropic, .excerpt))
        XCTAssertTrue(ledger.hasAnswered(anthropic, .excerpt), "a revoked switch is an answer: the sheet does not ask again")

        ledger.decline(anthropic, .chapter)
        XCTAssertFalse(ledger.allows(anthropic, .chapter))
        XCTAssertTrue(ledger.hasAnswered(anthropic, .chapter))
        ledger.grant(anthropic, .chapter)
        ledger.decline(anthropic, .chapter)
        XCTAssertTrue(ledger.allows(anthropic, .chapter), "\"Not now\" never takes back an earlier \"Always\"")

        ledger.reset()
        XCTAssertFalse(ledger.hasAnswered(anthropic, .excerpt))
        XCTAssertNil(defaults.object(forKey: ModelConsentLedger.grantedKey))
    }

    func testLocalSourcesNeedNothingAndWriteNothing() {
        let defaults = ThrowawayDefaults.make("consent-local")
        let ledger = ModelConsentLedger(defaults: defaults)
        XCTAssertTrue(ledger.allows(ollama, .chapter))
        ledger.grant(ollama, .chapter)
        ledger.revoke(ollama, .excerpt)
        XCTAssertNil(defaults.object(forKey: ModelConsentLedger.grantedKey))
        XCTAssertNil(defaults.object(forKey: ModelConsentLedger.declinedKey))
        XCTAssertTrue(ledger.allows(ollama, .excerpt), "revoking a local source changes nothing")
    }

    @MainActor
    func testTheLedgerIsNotInThePreferenceSyncContract() {
        XCTAssertFalse(PreferenceSync.syncedKeys.contains(ModelConsentLedger.grantedKey))
        XCTAssertFalse(PreferenceSync.syncedKeys.contains(ModelConsentLedger.declinedKey))
    }

    func testTheRouterUsesWhatTheLedgerAllows() {
        let ledger = ModelConsentLedger(defaults: ThrowawayDefaults.make("consent-router"))
        XCTAssertEqual(ModelRouter(sources: [anthropic], ledger: ledger).plan(for: .voiceSuggestion).usable, [])
        ledger.grant(anthropic, .excerpt)
        XCTAssertEqual(ModelRouter(sources: [anthropic], ledger: ledger).plan(for: .voiceSuggestion).usable.map(\.name), ["Anthropic"])
        XCTAssertEqual(ModelRouter(sources: [anthropic], ledger: ledger).plan(for: .recap).usable, [])
    }

    /// The voice suggestion with a cloud source the person allowed excerpts: it is asked, and
    /// named. Without consent it is skipped (`VoiceSuggestionsTests`).
    func testAnAllowedCloudSourceSuggestsTheNarrator() async {
        let calls = VoiceSuggestionsTests.FakeModel(reply: #"{"primary_voice":"bf_emma","alternates":["bm_george"],"rationale":"An English story."}"#)
        var consent = ModelConsent()
        consent.grant(anthropic, .excerpt)
        let document = ImportedDocument(sourceSHA256: "d", sourceKind: .pdf, title: "The Machine Stops", author: nil, language: "en",
                                        chapters: [DocumentChapter(index: 0, title: "One", paragraphs: ["Imagine a small room."])])
        let suggestion = await VoiceSuggestions.suggest(for: document, languageDefault: "kokoro:af_heart", sources: [anthropic],
                                                        consent: consent,
                                                        available: ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george"],
                                                        executor: calls.executor)
        XCTAssertEqual(calls.calls, ["Anthropic"])
        XCTAssertEqual(suggestion.source, "Anthropic")
        XCTAssertEqual(suggestion.primary, "kokoro:bf_emma")
    }

    func testTheSheetAsksOnlyWhenNothingLocalAnsweredAndThePersonHasNotAnswered() {
        let routing = VoiceSuggestions.Routing(sources: [ollama, anthropic], consent: ModelConsent(), executor: { _, _, _ in "" })
        XCTAssertEqual(VoiceSuggestions.sourceToAsk(fellBack: true, routing: routing, hasAnswered: { _ in false }), anthropic)
        XCTAssertNil(VoiceSuggestions.sourceToAsk(fellBack: false, routing: routing, hasAnswered: { _ in false }),
                     "a local model answered: nothing to ask")
        XCTAssertNil(VoiceSuggestions.sourceToAsk(fellBack: true, routing: routing, hasAnswered: { _ in true }),
                     "answered before (Not now, or a switch in Settings): not asked again")
        var allowed = routing
        allowed.consent.grant(anthropic, .excerpt)
        XCTAssertNil(VoiceSuggestions.sourceToAsk(fellBack: true, routing: allowed, hasAnswered: { _ in false }),
                     "already allowed: it was asked and failed, and asking again would not help")
    }

    func testTheProposalSaysWhichCloudSourceWasNotAllowed() {
        XCTAssertEqual(PronunciationEditing.noModelLine(router: ModelRouter(sources: [anthropic])),
                       "No model on this Mac or the Baton server, and sending excerpts to Anthropic is not allowed, so names are read as written. Add any below.")
        XCTAssertEqual(PronunciationEditing.noModelLine(router: ModelRouter(sources: [])),
                       "No model on this Mac or the Baton server, so names are read as written. Add any below.")
    }

    func testTheWordsNameTheProviderAndWhatIsSent() {
        let openAI = ModelSource(name: "api.openai.com", provider: .openAICompatible, baseURL: "https://api.openai.com/v1",
                                 model: "gpt", contextTokens: 8_192)
        XCTAssertEqual(CloudModelConsent.providerName(openAI), "OpenAI")
        XCTAssertEqual(CloudModelConsent.narratorQuestion(anthropic),
                       "Send the book's opening to Anthropic to suggest a narrator?")
        for content in ModelContent.allCases {
            let sentence = CloudModelConsent.whatIsSent(content, to: anthropic)
            XCTAssertTrue(sentence.contains("Anthropic"))
            XCTAssertTrue(sentence.contains("password or key taken out"), "says secrets are stripped")
            XCTAssertFalse(sentence.contains("—") || sentence.contains("–"), "no dashes in the copy")
        }
    }
}

/// The consent screen and the import sheet's ask (M4.6): which sources are listed, and what each
/// answer records.
final class CloudModelConsentSectionTests: XCTestCase {
    private func agent(base: String, provider: RemoteControlSettings.LLMProvider) -> RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.baseURL = base
        config.provider = provider
        config.model = "chat"
        return config
    }

    func testOnlyConfiguredCloudSourcesAreListedOncePerProviderAndHost() {
        XCTAssertEqual(CloudModelConsent.cloudSources(agent: agent(base: "https://api.anthropic.com", provider: .anthropic))
            .map(\.consentID), ["anthropic|api.anthropic.com"])
        XCTAssertEqual(CloudModelConsent.cloudSources(agent: agent(base: "http://10.0.0.8:8000/v1", provider: .openAICompatible)), [],
                       "the home server needs no consent, so it is not listed")
        let saved = ModelSource(name: "OpenAI", provider: .openAICompatible, baseURL: "https://api.openai.com/v1",
                                model: "other", contextTokens: 8_192)
        XCTAssertEqual(CloudModelConsent.cloudSources(agent: agent(base: "https://api.openai.com/v1", provider: .openAICompatible),
                                                      saved: [saved]).count, 1)
    }

    func testEachAnswerRecordsWhatItSays() {
        let source = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com",
                                 model: "claude", contextTokens: 8_192)
        let ledger = ModelConsentLedger(defaults: ThrowawayDefaults.make("consent-answers"))

        XCTAssertTrue(CloudModelConsent.record(.once, for: source, in: ledger), "suggest again")
        XCTAssertFalse(ledger.hasAnswered(source, .excerpt), "Allow once is never stored")

        XCTAssertFalse(CloudModelConsent.record(.notNow, for: source, in: ledger), "the default stays")
        XCTAssertTrue(ledger.hasAnswered(source, .excerpt))
        XCTAssertFalse(ledger.allows(source, .excerpt))

        XCTAssertTrue(CloudModelConsent.record(.always, for: source, in: ledger))
        XCTAssertTrue(ledger.allows(source, .excerpt))
        XCTAssertFalse(ledger.allows(source, .chapter), "the narrator question never allows chapters")
    }
}
