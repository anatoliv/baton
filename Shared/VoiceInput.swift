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

    #if DEBUG
    /// Suppresses the speech-recognition permission dialog under UI test. See `start()`.
    static let skipSpeechAuthorizationArgument = "-uitestSkipSpeechAuthorization"

    /// True in **any** test run, unit or UI — not merely when a launch argument was passed.
    ///
    /// The launch argument alone was not enough, and the way it failed is worth keeping.
    /// `VoiceInputCrashTests` calls `start()` three times to exercise the dispatch-isolation
    /// crash fix. Those are *unit* tests, so they never see a UI test's launch arguments —
    /// and each call raised the speech-permission dialog inside the test host. The dialog
    /// is drawn by SpringBoard and outlives the suite that raised it, so every UI test
    /// scheduled afterwards ran behind a modal alert nobody could tap.
    ///
    /// That is what produced a "twenty-one minute iPad hang" which was neither a hang nor
    /// about the iPad: running the unit suite and the UI suite in one invocation was the
    /// only thing that mattered. The same invocation on a freshly erased iPhone did it too,
    /// and a UI test run on its own passed on both. Ordering, not platform.
    static var isUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains(skipSpeechAuthorizationArgument)
    }
    #endif

    /// Starts listening. Music pauses (audio focus), the session flips to
    /// play-and-record, and partial results stream into `transcript`.
    func start() async {
        guard state != .listening else { return }
        transcript = ""

        // `@Sendable`, and it is load-bearing.
        //
        // This class is `@MainActor`, so a closure written here inherits main-actor
        // isolation — but `requestAuthorization` calls back on TCC's XPC queue. Swift's
        // runtime then checks the executor, finds the wrong one, and traps:
        // `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue
        // [com.apple.main-thread]`. That is a hard crash, not a warning, and it is what
        // happened every time anyone tapped the microphone. `@Sendable` opts the closure
        // out of inheriting the isolation, which is the truth of where it runs.
        #if DEBUG
        // UI tests must never be able to raise this dialog. `simctl privacy` cannot
        // pre-grant speech recognition — it is not among the services that command knows —
        // and the alert is drawn by SpringBoard, app-modal, so it blocks every subsequent
        // tap no matter which screen is behind it.
        //
        // That is not hypothetical. On iPad, where the layout differs, a stray tap reached
        // the Friend tab's microphone; the dialog went up on the setup screen and three
        // tests then burned their timeouts behind it, twenty-one minutes of what looked
        // exactly like a hang. Mirrors `-uitestBypassBiometrics`; never in a release build.
        if Self.isUnderTest {
            state = .denied("Speech recognition is disabled under test.")
            return
        }
        #endif

        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
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
            // Shaping the audio session is an iOS concern. macOS has no `AVAudioSession` at
            // all — the system arbitrates input and output itself, and an app that wants the
            // microphone simply asks for it. Everything below this guard is identical on
            // both platforms, which is why this file is shared rather than duplicated.
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
            #endif

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // Same reason: the tap runs on the audio thread, never the main one.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.request = request
            state = .listening

            // And again: the recogniser reports on its own queue. The hop to the main
            // actor below is deliberate and sufficient — inheriting isolation here would
            // trap before ever reaching it.
            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
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
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            voiceLog.error("session restore failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        if let token = focusToken {
            _ = controller.releaseAudioFocus(token)
            focusToken = nil
        }
    }
}
