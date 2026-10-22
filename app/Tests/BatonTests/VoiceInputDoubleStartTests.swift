import Foundation
import Testing
@testable import Baton

/// C3-12: `start()` awaits two permission requests. A second tap in that
/// window started a second engine and took a second focus token over the first, so one
/// microphone was never stopped and the music stayed suspended; a stop() in that window was a
/// no-op and the start went on to open the microphone anyway.
///
/// The microphone request always answers no here, so no test ever reaches the real hardware.
@Suite("Voice input double start")
@MainActor
struct VoiceInputDoubleStartTests {
    /// A permission request the test answers when it chooses.
    @MainActor final class HeldRequest {
        private(set) var calls = 0
        private var waiting: [CheckedContinuation<Bool, Never>] = []
        func ask() async -> Bool {
            calls += 1
            return await withCheckedContinuation { waiting.append($0) }
        }
        func answer(_ granted: Bool) { waiting.forEach { $0.resume(returning: granted) }; waiting = [] }
        var isWaiting: Bool { !waiting.isEmpty }
    }

    private func settle(until condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("A second start while the first is asking for permission does nothing")
    func secondStartWhileAskingIsIgnored() async {
        let music = MusicModel(environment: .testing)
        let speech = HeldRequest()
        var microphoneRequests = 0
        let voice = VoiceInput(controller: music.music,
                               requestSpeechAuthorization: { await speech.ask() },
                               requestMicrophonePermission: { microphoneRequests += 1; return false })
        let first = Task { await voice.start() }
        await settle { speech.isWaiting }
        await voice.start()   // the second tap
        #expect(speech.calls == 1, "the second start must not run a second permission pass")
        speech.answer(true)
        await first.value
        #expect(microphoneRequests == 1)
        #expect(voice.state != .listening)
    }

    @Test("A stop while start is asking for permission cancels the start")
    func stopWhileAskingCancelsTheStart() async {
        let music = MusicModel(environment: .testing)
        let speech = HeldRequest()
        var microphoneRequests = 0
        let voice = VoiceInput(controller: music.music,
                               requestSpeechAuthorization: { await speech.ask() },
                               requestMicrophonePermission: { microphoneRequests += 1; return false })
        let start = Task { await voice.start() }
        await settle { speech.isWaiting }
        voice.stop()
        speech.answer(true)
        await start.value
        #expect(microphoneRequests == 0, "a cancelled start must not go on to ask for the microphone")
        #expect(voice.state == .idle)
    }
}
