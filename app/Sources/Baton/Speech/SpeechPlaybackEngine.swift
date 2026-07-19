import AVFoundation
import Foundation
import Observation

/// Plays one-off spoken summaries (the `speak_summary` MCP tool), deliberately separate from
/// the music queue (`StreamingPlaybackController`) and the internet-radio engine — a spoken
/// alert is a transient utterance with no song id, duration, or queue. Modeled on
/// `RadioPlaybackEngine`, but uses `AVAudioPlayer` since the audio arrives as in-memory `Data`.
///
/// Also owns the transient in-app "banner" alert state (`pendingAlert`) that the UI observes
/// for `mode: "banner"` — a summary waiting for the user to press Play.
@MainActor
@Observable
final class SpeechPlaybackEngine {
    /// True while an utterance is actively playing.
    private(set) var isSpeaking = false
    /// A summary waiting for in-app confirmation (mode = "banner"): the text + what to play.
    private(set) var pendingAlert: Alert?

    /// What to actually play: synthesized audio from a self-hosted server (a temp WAV), or —
    /// when the server was unreachable — the raw text spoken by the built-in macOS voice.
    enum Utterance: Equatable {
        case file(URL)
        case native(String)
    }

    struct Alert: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let utterance: Utterance
        static func == (lhs: Alert, rhs: Alert) -> Bool { lhs.id == rhs.id }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: PlayerDelegate?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var synthDelegate: SynthDelegate?

    /// Play audio `data` immediately (mode = "auto", or on banner/notification confirmation).
    func play(data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            let delegate = PlayerDelegate { [weak self] in self?.isSpeaking = false }
            player.delegate = delegate
            self.player = player
            self.delegate = delegate
            isSpeaking = true
            player.play()
        } catch {
            speechLog.error("speech playback failed: \(error.localizedDescription)")
            isSpeaking = false
        }
    }

    /// Play audio previously written to a temp file (banner / notification confirmation).
    func play(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else {
            speechLog.error("speech temp file missing: \(fileURL.path, privacy: .public)")
            return
        }
        play(data: data)
    }

    /// Speak `text` with the built-in macOS voice — the offline fallback when a self-hosted
    /// TTS host is unreachable. No network, always available.
    func speakNative(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        // Prefer an enhanced/premium voice for the current locale if one is installed.
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        let delegate = SynthDelegate { [weak self] in self?.isSpeaking = false }
        synthesizer.delegate = delegate
        synthDelegate = delegate
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Play whichever kind of utterance a summary resolved to (server audio or native voice).
    func play(_ utterance: Utterance) {
        switch utterance {
        case let .file(url): play(fileURL: url)
        case let .native(text): speakNative(text)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - In-app banner (mode = "banner")
    func presentBanner(text: String, utterance: Utterance) {
        pendingAlert = Alert(text: text, utterance: utterance)
    }

    func confirmBanner() {
        guard let alert = pendingAlert else { return }
        pendingAlert = nil
        play(alert.utterance)
    }

    func dismissBanner() { pendingAlert = nil }
}

/// Bridges `AVSpeechSynthesizer`'s finish callback to a closure (native fallback path).
private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: @MainActor () -> Void
    init(onFinish: @escaping @MainActor () -> Void) { self.onFinish = onFinish }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let onFinish = self.onFinish
        MainActor.assumeIsolated { onFinish() }
    }
}

/// Bridges `AVAudioPlayer`'s completion callback to a closure. Not `@MainActor` (the delegate
/// protocol isn't), but `AVAudioPlayer` invokes it on the main run loop; the closure hops
/// back onto the main actor via the captured `@MainActor` engine method.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: @MainActor () -> Void
    init(onFinish: @escaping @MainActor () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let onFinish = self.onFinish // bind to a Sendable local so the closure doesn't capture self
        MainActor.assumeIsolated { onFinish() }
    }
}
