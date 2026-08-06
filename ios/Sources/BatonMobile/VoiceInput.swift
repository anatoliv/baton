import AVFoundation
import Foundation
import Observation
import OSLog
import Speech

private let voiceLog = Logger(subsystem: "io.tonebox.baton", category: "VoiceInput")

/// Push-to-talk speech recognition for the music friend. On-device recognition
/// where the language supports it (nothing leaves the phone), with playback ducked
/// through the engine's own audio-focus token protocol — the same mechanism MCP
/// clients use on the Mac — so music pauses while you speak and resumes after.
@MainActor
@Observable
final class VoiceInput {
    enum State: Equatable {
        case idle
        case listening
        case denied(String)
    }

    private(set) var state: State = .idle
    /// Live partial transcript while listening — shown in the input field.
    private(set) var transcript = ""

    @ObservationIgnored private let controller: StreamingPlaybackController
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var focusToken: StreamingPlaybackController.AudioFocusToken?

    init(controller: StreamingPlaybackController) {
        self.controller = controller
    }

    var isListening: Bool { state == .listening }

    /// Starts listening. Music pauses (audio focus), the session flips to
    /// play-and-record, and partial results stream into `transcript`.
    func start() async {
        guard state != .listening else { return }
        transcript = ""

        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speechAuthorized else {
            state = .denied("Speech recognition isn't allowed — enable it in Settings → Privacy.")
            return
        }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard micAllowed else {
            state = .denied("Microphone access isn't allowed — enable it in Settings → Privacy.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            state = .denied("Speech recognition isn't available right now.")
            return
        }

        // Pause the music through the focus protocol so stopping restores it —
        // including the generation guard against racing user taps.
        focusToken = controller.acquireAudioFocusSuspend(owner: "voice-input")

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.request = request
            state = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if isFinal || failed { self.finishListening() }
                }
            }
        } catch {
            voiceLog.error("voice start failed: \(error.localizedDescription, privacy: .public)")
            releaseFocusAndRestoreSession()
            state = .denied("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    /// Stops listening and returns the final transcript (empty when nothing was heard).
    @discardableResult
    func stop() -> String {
        guard state == .listening else { return transcript }
        request?.endAudio()
        finishListening()
        return transcript
    }

    private func finishListening() {
        guard engine != nil || task != nil else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        task?.cancel()
        engine = nil
        request = nil
        task = nil
        releaseFocusAndRestoreSession()
        if state == .listening { state = .idle }
    }

    private func releaseFocusAndRestoreSession() {
        // Back to the playback shape BEFORE releasing focus, so an auto-resume
        // plays through the right session.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            voiceLog.error("session restore failed: \(error.localizedDescription, privacy: .public)")
        }
        if let token = focusToken {
            _ = controller.releaseAudioFocus(token)
            focusToken = nil
        }
    }
}
