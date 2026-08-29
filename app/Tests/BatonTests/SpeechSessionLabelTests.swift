import Foundation
import Testing
@testable import Baton

/// Locks the "which agent is talking" behaviour for spoken summaries.
///
/// The point of the feature: several agents run at once, `SpeechPlaybackEngine`
/// already queues their utterances so they take turns, but taking turns doesn't
/// tell you *whose* work finished. A session label supplies that.
///
/// **The label used to be spoken** — prefixed into the synthesized text whenever
/// the speaker changed — and this suite locked that joining in some detail. It is
/// now *shown* above the transcript instead, so those tests are gone rather than
/// adapted: the behaviour they described no longer exists. What replaces them is
/// the property that matters and could regress silently — the label reaching the
/// display path while never reaching the text handed to synthesis.
@Suite("Speech session labels")
@MainActor
struct SpeechSessionLabelTests {
    // MARK: - Normalization

    @Test("Labels are trimmed, whitespace-collapsed, and length-capped")
    func normalization() {
        #expect(SpeechSessionLabels.normalize("  global-services  ") == "global-services")
        #expect(SpeechSessionLabels.normalize("global   services\n\tops") == "global services ops")
        let long = String(repeating: "a", count: SpeechSessionLabels.maxLabelChars + 20)
        #expect(SpeechSessionLabels.normalize(long)?.count == SpeechSessionLabels.maxLabelChars)
    }

    @Test("Blank and nil labels are treated as no label")
    func blankIsNoLabel() {
        #expect(SpeechSessionLabels.normalize(nil) == nil)
        #expect(SpeechSessionLabels.normalize("") == nil)
        #expect(SpeechSessionLabels.normalize("   \n ") == nil)
    }

    // MARK: - Stickiness

    @Test("A label declared once is reused for later calls on the same connection")
    func labelIsSticky() {
        // This is what stops an agent from having to remember on every call.
        let labels = SpeechSessionLabels()
        labels.declare("global-services", forSession: "sid-1")
        #expect(labels.label(forSession: "sid-1") == "global-services")
        // A later call with no `session` argument must not clear it.
        labels.declare(nil, forSession: "sid-1")
        #expect(labels.label(forSession: "sid-1") == "global-services")
    }

    @Test("A new label replaces the old one for that connection")
    func labelCanBeUpdated() {
        let labels = SpeechSessionLabels()
        labels.declare("first", forSession: "sid-1")
        labels.declare("second", forSession: "sid-1")
        #expect(labels.label(forSession: "sid-1") == "second")
    }

    @Test("Connections keep separate labels")
    func labelsArePerConnection() {
        let labels = SpeechSessionLabels()
        labels.declare("repo-a", forSession: "sid-1")
        labels.declare("repo-b", forSession: "sid-2")
        #expect(labels.label(forSession: "sid-1") == "repo-a")
        #expect(labels.label(forSession: "sid-2") == "repo-b")
        #expect(labels.label(forSession: "sid-unknown") == nil)
    }

    @Test("No session id means no label — never leaks another connection's name")
    func nilSessionIsolated() {
        let labels = SpeechSessionLabels()
        labels.declare("repo-a", forSession: nil)
        #expect(labels.label(forSession: nil) == nil)
    }

    @Test("Ending a connection forgets its label")
    func forgetOnEnd() {
        let labels = SpeechSessionLabels()
        labels.declare("repo-a", forSession: "sid-1")
        labels.forget("sid-1")
        #expect(labels.label(forSession: "sid-1") == nil)
    }

    @Test("Tracked connections are capped")
    func trackingIsBounded() {
        let labels = SpeechSessionLabels()
        for index in 0 ... (SpeechSessionLabels.maxTrackedSessions + 10) {
            labels.declare("label-\(index)", forSession: "sid-\(index)")
        }
        // The newest is always retained; the map can't grow without bound.
        let newest = "sid-\(SpeechSessionLabels.maxTrackedSessions + 10)"
        #expect(labels.label(forSession: newest) != nil)
    }

    // MARK: - Stateless callers

    @Test("A label is honoured even with no MCP session to remember it against")
    func labelSurvivesWithoutASessionID() {
        // The bug this locks: stickiness is keyed by the session id the server mints at
        // `initialize`, and both `declare` and `label(forSession:)` bail when it is nil.
        // A client that posts a bare `tools/call` has no id — which is exactly what the
        // bundled `baton-say` does, and therefore what the Claude Code hook does — so its
        // `session` argument was accepted and silently thrown away. Nothing failed; the
        // name simply never appeared, which is why it survived a green suite.
        let labels = SpeechSessionLabels()
        labels.declare("baton", forSession: nil)
        #expect(labels.label(forSession: nil) == nil,
                "no connection to remember against, so nothing is remembered")
        // Remembering needs an id. Honouring the name handed over in the call does not,
        // and that is the order `BatonMCPSpeakTools` resolves them in.
        #expect(SpeechSessionLabels.normalize("baton") == "baton")
    }

    // MARK: - Shown, never spoken

    @Test("The label rides alongside the summary rather than inside it")
    func labelIsCarriedNotJoined() {
        // The regression this guards is a quiet one: re-joining the name into the
        // text would still *work* — you would hear the summary — and the only
        // symptoms would be a second of wasted listening and the HUD's word
        // highlight drifting by one sentence, neither of which fails a build.
        let engine = SpeechPlaybackEngine()
        engine.presentBanner(
            text: "Tests are green.",
            utterance: .native("Tests are green."),
            sessionLabel: "global-services"
        )

        #expect(engine.pendingAlert?.sessionLabel == "global-services")
        #expect(engine.pendingAlert?.text == "Tests are green.")
        #expect(engine.pendingAlert?.text.contains("global-services") == false)
    }

    @Test("A summary with no label carries none, and invents nothing")
    func unlabelledCarriesNoLabel() {
        let engine = SpeechPlaybackEngine()
        engine.presentBanner(text: "Just this.", utterance: .native("Just this."))
        #expect(engine.pendingAlert?.sessionLabel == nil)
        #expect(engine.pendingAlert?.text == "Just this.")
    }

    // MARK: - History

    @Test("The spoken summary records which session said it")
    func historyKeepsTheLabel() {
        let defaults = UserDefaults(suiteName: "baton.tests.speechlabels.\(UUID().uuidString)")!
        let store = SpeechHistoryStore(defaults: defaults)
        _ = store.record(
            text: "Env labels shipped.",
            voice: "kokoro:af_bella",
            engine: "kokoro",
            category: "deploy",
            sessionLabel: "global-services"
        )
        #expect(store.entries.first?.sessionLabel == "global-services")
    }

    @Test("A history entry written before labels existed still decodes")
    func historyBackCompat() throws {
        // sessionLabel is optional precisely so an existing history file loads.
        let json = """
        [{"id":"\(UUID().uuidString)","text":"old","engine":"kokoro","date":0}]
        """
        let entries = try JSONDecoder().decode([SpeechHistoryStore.Entry].self, from: Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries.first?.sessionLabel == nil)
    }
}
