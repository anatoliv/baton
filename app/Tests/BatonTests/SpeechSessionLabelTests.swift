import Foundation
import Testing
@testable import Baton

/// Locks the "which agent is talking" behaviour for spoken summaries.
///
/// The point of the feature: several agents run at once, `SpeechPlaybackEngine`
/// already queues their utterances so they take turns, but taking turns doesn't
/// tell you *whose* work finished. A session label supplies that — while staying
/// quiet when the same agent speaks twice in a row.
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

    // MARK: - When the prefix is spoken

    @Test("The label is spoken when the speaker changes")
    func prefixOnSpeakerChange() {
        let labels = SpeechSessionLabels()
        let spoken = labels.announce(text: "Env labels shipped.", label: "global-services")
        #expect(spoken == "global-services. Env labels shipped.")
    }

    @Test("A run of updates from the same agent is not prefixed every time")
    func noPrefixForRepeatSpeaker() {
        // The anti-annoyance rule: hearing the same name before six consecutive
        // updates is noise.
        let labels = SpeechSessionLabels()
        _ = labels.announce(text: "Starting.", label: "repo-a")
        let second = labels.announce(text: "Halfway.", label: "repo-a")
        #expect(second == "Halfway.")
    }

    @Test("Alternating agents each get announced")
    func alternatingSpeakersBothAnnounced() {
        let labels = SpeechSessionLabels()
        #expect(labels.announce(text: "one", label: "repo-a") == "repo-a. one")
        #expect(labels.announce(text: "two", label: "repo-b") == "repo-b. two")
        #expect(labels.announce(text: "three", label: "repo-a") == "repo-a. three")
    }

    @Test("With no label the text is untouched")
    func unlabelledIsUnchanged() {
        let labels = SpeechSessionLabels()
        #expect(labels.announce(text: "Just this.", label: nil) == "Just this.")
    }

    @Test("An unlabelled summary does not reset who spoke last")
    func unlabelledDoesNotClearLastSpeaker() {
        // Otherwise one anonymous summary in the middle would make the next
        // same-agent summary re-announce itself for no reason.
        let labels = SpeechSessionLabels()
        _ = labels.announce(text: "one", label: "repo-a")
        _ = labels.announce(text: "anonymous", label: nil)
        #expect(labels.announce(text: "two", label: "repo-a") == "two")
    }

    @Test("A label already ending in a period doesn't get a doubled one")
    func noDoubledPunctuation() {
        #expect(SpeechSessionLabels.prefixed(label: "repo-a.", text: "done") == "repo-a. done")
        #expect(SpeechSessionLabels.prefixed(label: "repo-a", text: "  done  ") == "repo-a. done")
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
