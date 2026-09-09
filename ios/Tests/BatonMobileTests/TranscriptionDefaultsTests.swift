import BatonSpeech
import Foundation
import Testing
@testable import BatonMobile

/// What Transcription looks like on a phone nobody has configured yet.
///
/// The Whisper host defaulted to `http://127.0.0.1:8001`, which on a Mac is a fair guess and
/// on a phone is the phone. It rendered in Settings as a value somebody had saved, and it
/// made `isTranscriptionConfigured` true the moment the feature was switched on, so the
/// sheet offered a Transcribe button that could only fail (I-F14).
@Suite("Transcription defaults", .serialized)
struct TranscriptionDefaultsTests {
    /// Runs the body against a suite nothing has ever written to, so "fresh install" means
    /// fresh install, then removes it.
    private func withFreshDefaults(_ body: () throws -> Void) throws {
        let name = "ws7.speech.\(UUID().uuidString)"
        let fresh = try #require(UserDefaults(suiteName: name))
        let previous = SpeechConfig.defaults
        SpeechConfig.defaults = fresh
        defer {
            SpeechConfig.defaults = previous
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        try body()
    }

    @Test("The Whisper host is empty on a fresh install, not the phone itself")
    func hostIsEmptyByDefault() throws {
        try withFreshDefaults {
            #expect(SpeechConfig.whisperBaseURL.isEmpty,
                    "shipped host was \(SpeechConfig.whisperBaseURL)")
        }
    }

    @Test("Transcription is not configured on a fresh install, even once enabled")
    func notConfiguredOnAFreshInstall() throws {
        try withFreshDefaults {
            #expect(SpeechConfig.isTranscriptionConfigured == false)
            // The half that mattered: switching the feature on must not be enough. Without
            // a host there is nowhere to send the audio, and the sheet has to say so.
            SpeechConfig.transcriptionEnabled = true
            #expect(SpeechConfig.isTranscriptionConfigured == false,
                    "an enabled feature with no host is not configured")
        }
    }

    @Test("A host the user actually types is what makes it configured")
    func typingAHostConfiguresIt() throws {
        try withFreshDefaults {
            SpeechConfig.transcriptionEnabled = true
            SpeechConfig.whisperBaseURL = "http://whisper.example:8001"
            #expect(SpeechConfig.isTranscriptionConfigured)
        }
    }
}
