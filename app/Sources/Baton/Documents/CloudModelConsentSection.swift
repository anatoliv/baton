import BatonAgentKit
import BatonDocuments
import BatonSubsonicKit
import Foundation
import SwiftUI

/// The person's say over book text and cloud models on this Mac (M4.6): the ledger the router
/// reads, and the words every surface uses for it, so the import sheet, the recap and Settings
/// describe one rule the same way.
enum CloudModelConsent {
    /// The ledger in this Mac's own preferences (a probe's suite under `-baton.defaultsSuite`).
    static func ledger(_ defaults: UserDefaults = BatonStorage.defaults) -> ModelConsentLedger {
        ModelConsentLedger(defaults: defaults)
    }

    /// The provider as a person knows it: "Anthropic", or the host of an OpenAI-compatible one.
    static func providerName(_ source: ModelSource) -> String {
        if source.provider == .anthropic { return "Anthropic" }
        if let host = source.baseURL.flatMap({ URL(string: $0)?.host }) {
            return host == "api.openai.com" ? "OpenAI" : host
        }
        return source.name
    }

    /// The cloud sources document features could use on this Mac: today the music friend's
    /// model when it is a hosted one. Saved sources are local by construction
    /// (`LocalModelSources`). One entry per provider and host, since that is what consent is
    /// recorded against.
    static func cloudSources(agent: RemoteControlSettings.NaturalLanguageConfig,
                             saved: [ModelSource] = []) -> [ModelSource] {
        var seen = Set<String>()
        return (saved + VoiceSuggestions.sources(agent: agent, ollamaModel: nil))
            .filter { !$0.isLocal && seen.insert($0.consentID).inserted }
    }

    /// Record the import sheet's answer for the narrator suggestion. Returns whether to suggest
    /// again with the source allowed: "Always" is stored, "Allow once" is not (the sheet keeps
    /// it for itself), "Not now" is stored and the default voice stays.
    static func record(_ answer: CloudModelConsentAsk.Answer, for source: ModelSource,
                       in ledger: ModelConsentLedger) -> Bool {
        let content = ModelTask.voiceSuggestion.content
        switch answer {
        case .notNow:
            ledger.decline(source, content)
            return false
        case .always:
            ledger.grant(source, content)
            return true
        case .once:
            return true
        }
    }

    /// "sending excerpts to Anthropic is not allowed", for a line that says why a source was
    /// not asked.
    static func notAllowedClause(_ source: ModelSource, _ content: ModelContent) -> String {
        "sending \(content == .chapter ? "chapters" : "excerpts") to \(providerName(source)) is not allowed"
    }

    /// The switch's title for each kind of content.
    static func title(_ content: ModelContent) -> String {
        switch content {
        case .excerpt: "Short excerpts"
        case .chapter: "Chapters"
        }
    }

    /// One plain sentence of what goes to that source when the switch is on.
    static func whatIsSent(_ content: ModelContent, to source: ModelSource) -> String {
        let provider = providerName(source)
        switch content {
        case .excerpt:
            return "The book's opening to suggest a narrator, and the names a voice might stumble on, go to \(provider) as short excerpts with anything that looks like a password or key taken out first."
        case .chapter:
            return "The chapters you have already heard go to \(provider) to write a recap, with anything that looks like a password or key taken out first. Nothing past where you are is sent."
        }
    }

    /// The import sheet's question, the first time only a cloud source could suggest a narrator.
    static func narratorQuestion(_ source: ModelSource) -> String {
        "Send the book's opening to \(providerName(source)) to suggest a narrator?"
    }

    static func narratorQuestionDetail(_ source: ModelSource) -> String {
        "Nothing on this Mac or the Baton server could suggest one. \(providerName(source)) would get a short excerpt from the start of the book and the list of voices, with anything that looks like a password or key taken out first. Always also lets short excerpts go there to propose how names are said. You can change this any time in Settings, Agents."
    }
}

/// Settings → Agents → **Book text and cloud models** (M4.6): each configured cloud source, a
/// switch per kind of content, and one sentence of what goes when it is on. Models on this
/// Mac, the home server and Apple Intelligence never appear here: they need no consent.
///
/// Shown while documents are on (`baton.documents.enabled`), like the rest of document
/// clippings.
struct CloudModelConsentSection: View {
    var defaults: UserDefaults = BatonStorage.defaults
    /// Read on appear rather than per redraw: the agent's settings live in the Keychain and
    /// preferences, and this list only changes when the person edits them elsewhere.
    @State private var sources: [ModelSource] = []
    @State private var documentsEnabled = true
    /// Bumped after every change so the switches re-read the ledger.
    @State private var revision = 0

    private var ledger: ModelConsentLedger { CloudModelConsent.ledger(defaults) }

    var body: some View {
        Group {
            if documentsEnabled {
                Section {
                    if sources.isEmpty {
                        Text("No cloud model is set up, so book text stays on this Mac and the Baton server.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(sources, id: \.consentID) { source in
                            ForEach(ModelContent.allCases, id: \.self) { content in
                                Toggle(isOn: allowed(source, content)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(CloudModelConsent.title(content)) to \(CloudModelConsent.providerName(source))")
                                        Text(CloudModelConsent.whatIsSent(content, to: source))
                                            .font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .accessibilityIdentifier("cloud-consent-\(source.provider.rawValue)-\(content.rawValue)")
                            }
                        }
                    }
                    Button("Forget My Answers") {
                        ledger.reset()
                        revision += 1
                    }
                    .help("Turn everything off here, and let the import sheet ask again")
                } header: {
                    Text("Book text and cloud models")
                } footer: {
                    Text("Models on this Mac, on your Baton server and Apple Intelligence never need asking, because the book stays on your own machines. A cloud model gets only what is switched on here, and only from this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            documentsEnabled = DocumentLibrary.isEnabled(in: defaults)
            sources = CloudModelConsent.cloudSources(agent: RemoteControlSettings().naturalLanguage)
        }
    }

    private func allowed(_ source: ModelSource, _ content: ModelContent) -> Binding<Bool> {
        Binding(
            get: { _ = revision; return ledger.allows(source, content) },
            set: { on in
                if on { ledger.grant(source, content) } else { ledger.revoke(source, content) }
                revision += 1
            })
    }
}

/// The import sheet's first-use ask (M4.6): shown once nothing local suggested a narrator and a
/// cloud source could, until the person answers. "Allow once" lets this book's narrator
/// suggestion through and records nothing; "Always" and "Not now" go in the ledger.
struct CloudModelConsentAsk: View {
    enum Answer { case once, always, notNow }

    let source: ModelSource
    let answer: (Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CloudModelConsent.narratorQuestion(source)).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(CloudModelConsent.narratorQuestionDetail(source))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { answer(.notNow) }
                Spacer()
                Button("Allow Once") { answer(.once) }
                Button("Always") { answer(.always) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("cloud-consent-ask")
    }
}
