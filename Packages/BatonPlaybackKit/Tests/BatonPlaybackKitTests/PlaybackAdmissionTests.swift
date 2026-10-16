import BatonDSP
import BatonSubsonicKit
import BatonSubsonicModels
import XCTest
@testable import BatonPlaybackKit
#if os(macOS)
import CoreAudio
#endif

@MainActor
private final class AdmissionDeck: PlaybackDeck {
    var onClock: (@MainActor (TimeInterval, TimeInterval, Bool) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var record: (String) -> Void = { _ in }
    func load(song: NavidromeSong, url: URL, startingAt offset: TimeInterval, autoplay: Bool,
              headers: [String: String], supportsTimeOffset: Bool) { record(autoplay ? "load-playing" : "load-paused") }
    func pause() { record("pause") }
    func pauseImmediately() { record("pause-immediately") }
    func resume() { record("resume") }
    func seek(to seconds: TimeInterval) {}
    func stop() {}
    func applyLevel(volumePercent: Int, isMuted: Bool, envelope: Float) {}
    func applyLoudness(mode: StreamingPlaybackController.LoudnessMode, preampDB: Double) {}
    func setPlaybackRate(_ rate: Float) {}
    func setStallTimeout(_ seconds: Double) {}
    func applyEQ(bands: [EQBand], enabled: Bool) {}
    func startMetering(into snapshot: LevelSnapshot) {}
    func stopMetering() {}
    func suspendMetering() {}
    func resumeMetering() {}
    #if os(macOS)
    @discardableResult func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool { true }
    var currentOutputDeviceID: AudioDeviceID? { nil }
    #endif
}

@MainActor
final class PlaybackAdmissionTests: XCTestCase {
    func testReceivedHandoffSilencesDeckBeforeReturningAndKeepsQueueAndPlayhead() {
        let name = ThrowawayDefaults.name("handoff")
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = StreamingPlaybackController(streamURLProvider: { _ in
            URL(string: "http://127.0.0.1:1/synthetic")!
        }, defaults: defaults, systemNowPlaying: false)
        let deck = AdmissionDeck()
        var rendering = false
        var events: [String] = []
        deck.record = { event in
            events.append(event)
            if event == "load-playing" || event == "resume" { rendering = true }
            if event == "pause-immediately" { rendering = false }
        }
        controller.engineDeckProvider = { deck }
        let songs = [NavidromeSong(id: "synthetic", title: "Synthetic", duration: 60)]
        controller.play(songs)
        deck.onClock?(17, 60, false)
        controller.onPause = { XCTAssertFalse(rendering); events.append("paused") }
        events.removeAll()
        controller.pauseForPlaybackHandoff()
        XCTAssertFalse(rendering, "handoff must silence output before the received player can start")
        XCTAssertEqual(events, ["pause-immediately", "paused"])
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.queue, songs)
        XCTAssertEqual(controller.currentTime, 17)
        deck.onEnded?()
        deck.onFailure?("late synthetic failure")
        XCTAssertEqual(events, ["pause-immediately", "paused"], "queued callbacks cannot reclaim received audio")
        XCTAssertEqual(controller.currentTime, 17)
        XCTAssertEqual(controller.queue, songs)
        controller.onPause = nil
        controller.resume()
        XCTAssertTrue(rendering)
        XCTAssertEqual(controller.currentTime, 17, "handoff must not rewind the library")
        controller.pauseForPlaybackHandoff()
    }

    func testRadioHandoffCancelsPendingFadeBeforeReturningAndAllowsExplicitResume() async {
        var rendering = false
        var pauses = 0
        let radio = RadioPlaybackEngine(startRendering: { _ in rendering = true },
            pauseRendering: { _ in rendering = false; pauses += 1 })
        radio.resume() // injected renderer makes no sound and loads no URL
        radio.pause()
        XCTAssertTrue(rendering, "ordinary Pause retains its deferred fade")
        XCTAssertTrue(radio.isTransportFadingForTesting)
        radio.pauseForPlaybackHandoff()
        XCTAssertFalse(rendering)
        XCTAssertEqual(pauses, 1)
        XCTAssertFalse(radio.isTransportFadingForTesting)
        radio.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(rendering)
        XCTAssertEqual(pauses, 1, "the superseded fade must not pause the later owner")
        radio.pauseForPlaybackHandoff()
    }

    func testRadioAdmissionCoexistsWithHostHookAndReleasesOnlyOwnedObservers() {
        let name = ThrowawayDefaults.name("radioadmission")
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = StreamingPlaybackController(defaults: defaults, systemNowPlaying: false)
        var events: [String] = []
        var receiverPlaying = true
        controller.onPlaybackStarting = { events.append("host") }
        let owned = controller.observePlaybackAdmission { receiverPlaying = false; events.append("received-stop") }
        let radio = RadioPlaybackEngine(startRendering: { _ in
            XCTAssertFalse(receiverPlaying, "radio rendering started before the received player relinquished audio")
            events.append("radio-render")
        })
        radio.onPlaybackStarting = { controller.admitPlayback() }
        radio.resume()
        XCTAssertEqual(events, ["host", "received-stop", "radio-render"])
        controller.releasePlaybackAdmission(owned)
        let other = controller.observePlaybackAdmission { events.append("other") }
        controller.releasePlaybackAdmission(owned) // stale release cannot remove another registration
        events.removeAll()
        radio.resume()
        XCTAssertEqual(events, ["host", "other", "radio-render"])
        controller.releasePlaybackAdmission(other)
        controller.onPlaybackStarting = nil
        radio.stop()
    }

    func testHostRelinquishesReceivedAudioBeforeLoadAndMidTrackResume() {
        let suiteName = ThrowawayDefaults.name("admission")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = StreamingPlaybackController(streamURLProvider: { _ in
            URL(string: "http://127.0.0.1:1/synthetic")!
        }, defaults: defaults, systemNowPlaying: false)
        let deck = AdmissionDeck()
        var events: [String] = []
        var receiverPlaying = true
        controller.onPlaybackStarting = { receiverPlaying = false; events.append("admit") }
        controller.engineDeckProvider = { events.append("resolve"); return deck }
        deck.record = { event in
            if event == "load-playing" || event == "resume" {
                XCTAssertFalse(receiverPlaying, "library rendering started before the other player relinquished audio")
            }
            events.append(event)
        }
        controller.play([NavidromeSong(id: "synthetic", title: "Synthetic", duration: 60)])
        XCTAssertEqual(events, ["admit", "resolve", "load-playing"])
        events.removeAll()
        controller.pause()
        XCTAssertEqual(events, ["pause"], "pausing must not admit another playback owner")
        receiverPlaying = true
        events.removeAll()
        controller.resume()
        XCTAssertEqual(events, ["admit", "resume"], "resume must be covered even when track-start notification is already spent")
        controller.stop()
    }
}
