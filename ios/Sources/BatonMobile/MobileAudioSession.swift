import AVFoundation
import BatonShareKit
import BatonPlaybackKit
import Foundation
import OSLog

private let sessionLog = Logger(subsystem: "io.tonebox.baton", category: "AudioSession")

/// Owns the `AVAudioSession` lifecycle for the phone — the one piece of playback
/// plumbing macOS never needed. The rules here are adapted (with thanks) from
/// Vibrdrome's MIT-licensed `AudioSession.swift`, which encodes four separately
/// shipped bug fixes; each is preserved as a comment on the rule it produced.
@MainActor
final class MobileAudioSession {
    /// How much audio the system asks for per render callback.
    ///
    /// Left at the default, iOS wakes the render thread roughly ninety times a second for
    /// the entire listening session — and wake-up frequency weighs heavily in what the
    /// system counts as energy use. Baton is long-form playback: nothing here is
    /// latency-critical the way a synth or a game is, so asking for a larger slice trades
    /// something we do not need for something a phone very much does.
    ///
    /// ~46 ms is about 2048 frames at 44.1 kHz — roughly a quarter of the wake-ups. It is a
    /// *preference*: the system may give less, and asking for the maximum would make
    /// transport actions feel sluggish, since pause and seek cannot take effect sooner than
    /// the buffer already in flight.
    ///
    /// macOS deliberately has no counterpart here. Its equivalent is the device's own
    /// buffer frame size, which is shared by every app on that device — the same objection
    /// that made us replace the in-app AirPlay picker with per-app routing. A music player
    /// does not get to re-tune the sound card for everyone else.
    static let preferredIOBufferDuration: TimeInterval = 0.046

    /// True while an interruption (call, Siri, alarm) has playback paused and we
    /// intend to resume when it ends.
    private var wasPlayingBeforeInterruption = false
    /// The controller's transport stamp just after an interruption paused it. A later stamp
    /// means the person played, paused or skipped since.
    private var pausedByInterruptionAt: Int?

    private let controller: StreamingPlaybackController
    private var observers: [NSObjectProtocol] = []
    private var receivedOwnership = ReceivedAudioOwnership()
    private var admissionObserver: UUID?
    private var receivedCallback: (@MainActor (ReceivedAudioEvent) -> Void)?

    /// The audio server died and took every audio object with it. Anything the app built
    /// on top of CoreAudio — an `AVAudioEngine` above all — is now a dead handle that
    /// will neither play nor report an error, and must be discarded and rebuilt.
    ///
    /// AVPlayer recovers from this largely by itself, which is why the phone never needed
    /// the hook before. Owning the render graph is what makes it ours to handle: this is
    /// one of the concrete costs of the engine on iOS, not an abstraction.
    var onMediaServicesReset: (@MainActor () -> Void)?

    init(controller: StreamingPlaybackController) {
        self.controller = controller
        admissionObserver = controller.observePlaybackAdmission { [weak self] in self?.libraryWillStart() }
    }

    deinit {
        let token = admissionObserver
        Task { @MainActor [weak controller] in
            if let token { controller?.releasePlaybackAdmission(token) }
        }
    }

    /// Configures the category once. Deliberately does NOT activate the session at
    /// launch — activating on cold launch interrupts whatever the user is already
    /// listening to (Spotify, a podcast) before they've asked Baton to play anything.
    /// Activation happens lazily in `activateForPlayback()`.
    func configure() {
        do {
            // `.longFormAudio` is what gets the app promoted to the system Now Playing
            // slot (and surfaces it in CarPlay's audio apps) rather than being treated
            // as a transient sound source.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(Self.preferredIOBufferDuration)
        } catch {
            sessionLog.error("session configure failed: \(error.localizedDescription, privacy: .public)")
        }
        installObservers()
    }

    /// Activates the session right before playback starts. Safe to call repeatedly.
    func activateForPlayback() {
        libraryWillStart()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            sessionLog.error("setActive failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Uses the configured long-form session; failure is returned to the receiving UI.
    /// No strong owner/receiver cycle: callers provide weak callbacks and release on stop.
    func activateForReceivedPlayback(_ callback: @escaping @MainActor (ReceivedAudioEvent) -> Void) throws -> (@MainActor () -> Void) {
        receivedCallback?(.libraryStarting)
        try AVAudioSession.sharedInstance().setActive(true)
        let token = receivedOwnership.begin()
        receivedCallback = callback
        wasPlayingBeforeInterruption = false
        return { [weak self] in
            guard let self, self.receivedOwnership.release(token) else { return }
            self.receivedCallback = nil
        }
    }

    private func libraryWillStart() {
        let callback = receivedCallback
        receivedCallback = nil
        receivedOwnership.libraryWillStart()
        callback?(.libraryStarting)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        // Extract the Sendable scalars BEFORE hopping to the actor — the userInfo
        // dictionary itself is not Sendable (same pattern the shared engine uses for
        // its KVO callbacks).
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeRaw: type, optionsRaw: options) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reasonRaw: reason) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        })
    }

    /// Media services were reset: the category is gone with everything else, so re-declare
    /// it before anyone tries to play, then let the host rebuild whatever it owns.
    ///
    /// Deliberately does NOT resume. The session is inactive and every audio object is
    /// stale; resuming here would race the host's rebuild. Playback stops and waits for
    /// the user, which is the honest outcome of the audio server dying underneath us.
    private func handleMediaServicesReset() {
        sessionLog.error("media services were reset, rebuilding audio")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            sessionLog.error("setCategory after reset failed: \(error.localizedDescription, privacy: .public)")
        }
        receivedCallback?(.mediaServicesReset)
        wasPlayingBeforeInterruption = false
        onMediaServicesReset?()
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let raw = typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            receivedCallback?(.interrupted)
            if controller.isPlaying {
                wasPlayingBeforeInterruption = true
                controller.pause()
                pausedByInterruptionAt = controller.stateGeneration
            } else if controller.stateGeneration != pausedByInterruptionAt {
                // A second .began with no .ended between (Siri over a call) finds playback
                // already paused by the first, and keeps "it was playing".
                // Unless the person played or paused since: then it is their pause, and a
                // .began whose .ended never came must not resume it later.
                wasPlayingBeforeInterruption = false
            }
        case .ended:
            guard receivedOwnership.allowsLibraryResume else {
                wasPlayingBeforeInterruption = false
                return
            }
            // Siri/Messages announcements over CarPlay often end an interruption
            // WITHOUT the .shouldResume flag even though resuming is exactly what the
            // user expects — so fall back to "were we playing before". (Vibrdrome's
            // fourth shipped fix; without it CarPlay goes silent after every
            // announcement until the user taps play.)
            //
            // And only then: .shouldResume says the interruption is over, not that the
            // person wanted Baton playing. On its own it started a track they had paused
            // before the call (TBX-1000000480 B-3).
            if wasPlayingBeforeInterruption {
                activateForPlayback()
                controller.resume()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let raw = reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones unplugged / AirPods in the case: pause, but ONLY when the
            // outputs are genuinely gone — a CarPlay or Bluetooth renegotiation also
            // reports oldDeviceUnavailable mid-handoff, and pausing there produces
            // spurious stops (another of Vibrdrome's field fixes).
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            let genuinelyGone = outputs.isEmpty || outputs.allSatisfy { $0.portType == .builtInSpeaker }
            if genuinelyGone {
                receivedCallback?(.routeRemoved)
                if controller.isPlaying { controller.pause() }
            }
        default:
            break
        }
    }
}
