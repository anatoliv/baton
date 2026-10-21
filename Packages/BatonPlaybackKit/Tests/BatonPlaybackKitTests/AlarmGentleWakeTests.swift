#if os(iOS) || os(macOS)
import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// Gentle wake: the option is kept with the alarm, the sound the system rings is
/// faded into the file (rising over its first 20 seconds, full after), and Baton's player rises
/// from quiet to the person's volume over 30 seconds, never above it, ending when they change it.
@MainActor
final class AlarmGentleWakeTests: XCTestCase {
    private var dir: URL!
    private var controllers: [StreamingPlaybackController] = []
    private let song = NavidromeSong(id: "song-1", title: "Variatio 4", artist: "Kimiko Ishizaka")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-tbx-1000000445-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controllers.forEach { $0.stop() }
        controllers = []
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: The option

    func testGentleWakeIsKeptWithTheAlarmAndOffByDefault() throws {
        let defaults = ThrowawayDefaults.make("gentle.persist")
        let store = AlarmStore(defaults: defaults)
        let plain = BatonAlarm(hour: 6, minute: 30, choice: .song(song))
        XCTAssertFalse(plain.gentleWake, "off by default")
        store.save(plain)
        store.save(BatonAlarm(hour: 7, minute: 0, choice: .song(song), gentleWake: true))
        let reloaded = AlarmStore(defaults: defaults)
        XCTAssertEqual(reloaded.alarms.map(\.gentleWake), [false, true], "saved and read back across a launch")
    }

    /// An alarm saved by 0.20.12 / 1.5.7 has no `gentleWake` key: it reads as off and nothing
    /// else about it is lost.
    func testAnAlarmSavedBeforeGentleWakeReadsAsOff() throws {
        let alarm = BatonAlarm(hour: 7, minute: 15, repeatDays: [2, 4], label: "Run", snoozeEnabled: false,
                               choice: .song(song), gentleWake: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(alarm)) as? [String: Any])
        XCTAssertEqual(json["gentleWake"] as? Bool, true)
        json["gentleWake"] = nil
        let old = try JSONDecoder().decode(BatonAlarm.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.gentleWake)
        var expected = alarm
        expected.gentleWake = false
        XCTAssertEqual(old, expected)
    }

    func testTheSheetSavesEditsAndResetsGentleWake() throws {
        let store = AlarmStore(defaults: ThrowawayDefaults.make("gentle.sheet"))
        let setup = AlarmQuickSetup(mode: .alarm, preselected: .song(song))
        XCTAssertFalse(setup.gentleWake, "a new alarm starts with it off")
        setup.gentleWake = true
        let saved = try XCTUnwrap(setup.saveAlarm(in: store))
        XCTAssertTrue(store.alarm(id: saved.id)?.gentleWake == true)
        setup.newAlarm()
        XCTAssertFalse(setup.gentleWake)
        setup.edit(saved)
        XCTAssertTrue(setup.gentleWake, "editing shows the alarm's own setting")
        setup.gentleWake = false
        setup.saveAlarm(in: store)
        XCTAssertEqual(store.alarm(id: saved.id)?.gentleWake, false)
    }

    /// The occurrence that goes off carries the alarm's setting; a timer never has it.
    func testTheFireCarriesGentleWakeAndATimerNeverDoes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let store = AlarmStore(defaults: ThrowawayDefaults.make("gentle.fire"), calendar: { cal })
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 6, minute: 0))!
        store.save(BatonAlarm(hour: 7, minute: 0, choice: .song(song), gentleWake: true), now: start)
        store.startTimer(duration: 60, choice: .song(song), now: start)
        let fires = store.due(at: start.addingTimeInterval(3600))
        XCTAssertEqual(fires.map(\.kind), [.timer, .alarm])
        XCTAssertEqual(fires.map(\.gentleWake), [false, true])
    }

    // MARK: The curve and the player's rise

    func testTheCurveRisesFromMinus30dBToFullAndNeverAbove() {
        XCTAssertEqual(GentleWake.gain(elapsed: 0, ramp: 30), pow(10, -30.0 / 20), accuracy: 1e-9)
        XCTAssertEqual(20 * log10(GentleWake.gain(elapsed: 15, ramp: 30)), -15, accuracy: 1e-9, "even in decibels")
        var last = 0.0
        for tenth in 0 ... 400 {
            let g = GentleWake.gain(elapsed: Double(tenth) / 10, ramp: 30)
            XCTAssertGreaterThanOrEqual(g, last)
            XCTAssertLessThanOrEqual(g, 1)
            last = g
        }
        XCTAssertLessThan(GentleWake.gain(elapsed: 29.9, ramp: 30), 1)
        XCTAssertEqual(GentleWake.gain(elapsed: 30, ramp: 30), 1)
    }

    /// With an injected clock: the floor while the stream buffers, then 30 seconds of rise from
    /// the moment it plays, then full and finished.
    func testTheRampWaitsForPlaybackThenRisesOverThirtySeconds() {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        var playing = false
        var applied: [Float] = []
        let ramp = AlarmVolumeRamp(now: { now }, isPlaying: { playing }) { applied.append($0) }
        XCTAssertEqual(Double(applied.last!), GentleWake.floorGain, accuracy: 1e-6, "quiet at once")
        now += 5
        XCTAssertTrue(ramp.step())
        XCTAssertEqual(Double(applied.last!), GentleWake.floorGain, accuracy: 1e-6, "still buffering: still quiet")
        playing = true
        XCTAssertTrue(ramp.step())
        XCTAssertEqual(ramp.phase, .rising(from: now))
        let risingFrom = applied.count
        for _ in 0 ..< 29 {
            now += 1
            XCTAssertTrue(ramp.step())
        }
        let rise = Array(applied[risingFrom...])
        XCTAssertEqual(rise.count, 29)
        XCTAssertEqual(rise, rise.sorted(), "rises every second")
        XCTAssertLessThan(rise.last!, 1, "not full before 30 s")
        now += 1
        XCTAssertFalse(ramp.step(), "finished at 30 s")
        XCTAssertEqual(applied.last, 1)
        XCTAssertTrue(applied.allSatisfy { $0 <= 1 })
        XCTAssertFalse(ramp.step(), "a finished ramp applies nothing more")
    }

    func testTheRampGivesUpIfThePlayerNeverStarts() {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        var applied: [Float] = []
        let ramp = AlarmVolumeRamp(now: { now }, isPlaying: { false }) { applied.append($0) }
        now += GentleWake.waitForPlaybackSeconds - 1
        XCTAssertTrue(ramp.step())
        now += 1
        XCTAssertFalse(ramp.step())
        XCTAssertEqual(applied.last, 1, "the volume is left at the person's level")
    }

    private nonisolated static func tone(in dir: URL, named name: String, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("\(name).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    private func controller() -> StreamingPlaybackController {
        let c = StreamingPlaybackController(streamURLProvider: { URL(string: $0)! }, coverArtURLProvider: { _ in nil },
                                            defaults: UserDefaults(suiteName: ThrowawayDefaults.name("tbx445.ramp"))!,
                                            systemNowPlaying: false)
        c.gaplessEnabled = false
        c.crossfadeSeconds = 0
        controllers.append(c)
        return c
    }

    private func playingController() throws -> (StreamingPlaybackController, NavidromeSong) {
        let url = try Self.tone(in: dir, named: "wake", seconds: 60)
        let track = NavidromeSong(id: url.absoluteString, title: "Wake", artist: "Baton")
        let c = controller()
        c.play([track])
        waitUntil { c.isPlaying }
        XCTAssertTrue(c.isPlaying)
        return (c, track)
    }

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 8) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// The player's own envelope rises with the clock and the person's volume is never touched,
    /// so the output is never above it.
    func testThePlayerRisesToThePersonsVolumeAndNoHigher() throws {
        let (player, _) = try playingController()
        player.setVolume(percent: 64)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        player.startWakeRamp(now: { now }, tick: nil)
        XCTAssertTrue(player.isWakeRamping)
        XCTAssertEqual(Double(player.wakeEnvelope), GentleWake.floorGain, accuracy: 1e-6)
        player.stepWakeRamp() // playing already: the rise starts now
        var levels: [Float] = []
        for _ in 0 ..< 30 {
            now += 1
            player.stepWakeRamp()
            levels.append(player.wakeEnvelope)
            XCTAssertEqual(player.volumePercent, 64, "the person's volume is not moved")
        }
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertTrue(levels.allSatisfy { $0 <= 1 })
        XCTAssertEqual(levels.last, 1)
        XCTAssertFalse(player.isWakeRamping, "finished after 30 seconds")
    }

    /// The person moving the volume, muting, or pausing ends the rise at their level.
    func testThePersonsVolumeChangeEndsTheRise() throws {
        let (player, _) = try playingController()
        player.setVolume(percent: 50)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        player.startWakeRamp(now: { now }, tick: nil)
        player.stepWakeRamp()
        now += 10
        player.stepWakeRamp()
        XCTAssertLessThan(player.wakeEnvelope, 1)
        player.setVolume(percent: 30)
        XCTAssertFalse(player.isWakeRamping)
        XCTAssertEqual(player.wakeEnvelope, 1)
        XCTAssertEqual(player.volumePercent, 30, "their new level stands")
        now += 5
        XCTAssertFalse(player.stepWakeRamp(), "nothing moves it afterwards")
        XCTAssertEqual(player.wakeEnvelope, 1)

        player.startWakeRamp(now: { now }, tick: nil)
        player.toggleMute()
        XCTAssertFalse(player.isWakeRamping)
        XCTAssertEqual(player.wakeEnvelope, 1)
        player.toggleMute()

        player.startWakeRamp(now: { now }, tick: nil)
        player.pause()
        XCTAssertFalse(player.isWakeRamping, "Stop and Snooze pause the music, which ends the rise")
    }

    /// Stop or Snooze a few seconds in: the music fades out from the quiet level it had reached,
    /// with no jump to full volume inside the pause's fade; playing again is at the person's level.
    func testPausingDuringTheRiseFadesOutFromWhereItWas() throws {
        let (player, _) = try playingController()
        player.setVolume(percent: 80)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        player.startWakeRamp(now: { now }, tick: nil)
        player.stepWakeRamp()
        now += 3
        player.stepWakeRamp()
        let reached = player.wakeEnvelope
        XCTAssertLessThan(reached, 0.1)
        waitUntil({ abs(player.avDeckVolumeForTesting - 0.8 * reached) < 0.01 }, seconds: 2)
        let heard = player.avDeckVolumeForTesting
        XCTAssertEqual(heard, 0.8 * reached, accuracy: 0.01, "the deck plays the rise's level")
        player.pause()
        XCTAssertFalse(player.isWakeRamping)
        XCTAssertEqual(player.wakeEnvelope, reached, "held, not raised, while the pause fades")
        var loudest = player.avDeckVolumeForTesting
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            loudest = max(loudest, player.avDeckVolumeForTesting)
        }
        XCTAssertLessThanOrEqual(loudest, heard + 0.001, "nothing louder than the rise had reached during the pause")
        player.resume()
        XCTAssertEqual(player.wakeEnvelope, 1, "playing again is at the person's volume")
    }

    /// A station chosen for a gentle alarm: quiet until audio flows, given up after a minute if it
    /// never does; the person's volume or mute sets the level; Pause holds it and playing again
    /// lets it go.
    func testTheRadioEngineRisesAndIsEndedTheSameWay() {
        let engine = RadioPlaybackEngine(startRendering: { _ in }, pauseRendering: { _ in })
        engine.setVolume(percent: 70)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        engine.startWakeRamp(now: { now }, tick: nil)
        XCTAssertTrue(engine.isWakeRamping)
        XCTAssertEqual(Double(engine.wakeEnvelope), GentleWake.floorGain, accuracy: 1e-6)
        now += 30
        XCTAssertTrue(engine.stepWakeRamp(), "no audio yet: still waiting, still quiet")
        XCTAssertEqual(Double(engine.wakeEnvelope), GentleWake.floorGain, accuracy: 1e-6)
        now += 30
        XCTAssertFalse(engine.stepWakeRamp(), "a station that never starts gives the rise up")
        XCTAssertEqual(engine.wakeEnvelope, 1)

        engine.startWakeRamp(now: { now }, tick: nil)
        engine.setVolume(percent: 40)
        XCTAssertFalse(engine.isWakeRamping)
        XCTAssertEqual(engine.wakeEnvelope, 1)

        engine.startWakeRamp(now: { now }, tick: nil)
        engine.setMuted(true)
        XCTAssertFalse(engine.isWakeRamping)
        XCTAssertEqual(engine.wakeEnvelope, 1)
        engine.setMuted(false)

        engine.startWakeRamp(now: { now }, tick: nil)
        engine.pause()
        XCTAssertFalse(engine.isWakeRamping)
        XCTAssertLessThan(engine.wakeEnvelope, 1, "held through the pause's fade")
        engine.resume()
        XCTAssertEqual(engine.wakeEnvelope, 1)
    }

    /// The center asks for the station's rise only for a gentle alarm.
    func testAGentleRadioAlarmRaisesTheStation() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let store = AlarmStore(defaults: ThrowawayDefaults.make("gentle.radio"), calendar: { cal })
        let center = AlarmCenter(store: store, player: controller())
        var tuned = 0, raised = 0
        center.playRadio = { _ in tuned += 1 }
        center.rampRadio = { raised += 1 }
        var now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 6, minute: 0))!
        center.now = { now }
        let station = AlarmChoice.radio(.init(id: "r1", name: "Morning", streamURL: "https://example.invalid/s"))
        store.save(BatonAlarm(hour: 7, minute: 0, choice: station, gentleWake: true), now: now)
        store.save(BatonAlarm(hour: 8, minute: 0, choice: station), now: now)
        now = now.addingTimeInterval(3600)
        center.handle(store.due(at: now), fromSystem: false)
        XCTAssertEqual([tuned, raised], [1, 1])
        center.stopRinging()
        now = now.addingTimeInterval(3600)
        center.handle(store.due(at: now), fromSystem: false)
        XCTAssertEqual([tuned, raised], [2, 1], "a plain alarm tunes in at the person's volume")
        center.stopRinging()
    }

    /// The rise runs by itself in real time when not driven by a test (a short one here).
    func testTheRiseRunsByItself() throws {
        let (player, _) = try playingController()
        player.startWakeRamp(duration: 0.6, tick: .milliseconds(50))
        waitUntil({ !player.isWakeRamping }, seconds: 5)
        XCTAssertFalse(player.isWakeRamping)
        XCTAssertEqual(player.wakeEnvelope, 1)
    }

    private final class FakeSystem: AlarmSystemBridge {
        func sync(_ store: AlarmStore) async {}
        func silence(id: UUID) {}
        func authorize() async -> Bool { true }
    }

    /// A gentle alarm going off starts the rise; a plain one and a timer do not; Stop ends it.
    func testAGentleAlarmGoingOffRaisesTheVolumeAndAPlainOneDoesNot() throws {
        let url = try Self.tone(in: dir, named: "alarm", seconds: 60)
        let track = NavidromeSong(id: url.absoluteString, title: "Alarm", artist: "Baton")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let player = controller()
        let store = AlarmStore(defaults: ThrowawayDefaults.make("gentle.center"), calendar: { cal })
        let center = AlarmCenter(store: store, player: player)
        center.system = FakeSystem()
        var now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 6, minute: 0))!
        center.now = { now }
        store.save(BatonAlarm(hour: 7, minute: 0, choice: .song(track), gentleWake: true), now: now)
        store.save(BatonAlarm(hour: 8, minute: 0, choice: .song(track)), now: now)

        now = now.addingTimeInterval(3600)
        center.handle(store.due(at: now), fromSystem: false)
        XCTAssertTrue(player.isWakeRamping, "the gentle 7:00 alarm rises")
        XCTAssertLessThan(player.wakeEnvelope, 1)
        center.stopRinging()
        XCTAssertFalse(player.isWakeRamping, "Stop ends the rise")

        now = now.addingTimeInterval(3600)
        center.handle(store.due(at: now), fromSystem: false)
        XCTAssertFalse(player.isWakeRamping, "the plain 8:00 alarm plays at the person's volume")
        XCTAssertEqual(player.wakeEnvelope, 1, "the level Stop held is let go when the next track loads")
        center.stopRinging()

        store.startTimer(duration: 1, choice: .song(track), now: now)
        now = now.addingTimeInterval(2)
        center.handle(store.due(at: now), fromSystem: false)
        XCTAssertFalse(player.isWakeRamping, "a timer has no Gentle wake")
        center.stopRinging()
    }

    // MARK: The faded sound file

    /// A steady tone at a known level, so the clip's envelope is the fade alone.
    private nonisolated static func steadyTone(in dir: URL, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("steady.wav")
        let rate = 22_050.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for n in 0 ..< Int(buffer.frameLength) { samples[n] = 0.5 * sin(2 * .pi * 440 * Float(n) / Float(rate)) }
        try file.write(from: buffer)
        return url
    }

    /// RMS of each `window`-second stretch of a sound file, in dB relative to full scale.
    private func rmsDB(_ url: URL, window: Double = 1) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let size = Int(file.processingFormat.sampleRate * window)
        return stride(from: 0, to: Int(buffer.frameLength) - size + 1, by: size).map { start in
            var sum = 0.0
            for n in start ..< start + size { sum += Double(samples[n] * samples[n]) }
            return 10 * log10(max(sum / Double(size), 1e-12))
        }
    }

    /// The clip a gentle alarm rings: its own file name, Linear PCM, at most 29 seconds; each
    /// second louder than the last over the first 20 (about 30 dB in all), and full level for
    /// the rest, the same level as the plain clip of the same track.
    func testAGentleAlarmsClipRisesOverTwentySecondsThenHoldsFullLevel() async throws {
        let source = try Self.steadyTone(in: dir, seconds: 40)
        let sounds = dir.appendingPathComponent("Sounds")
        let clips = AlarmClipStore(directory: sounds, defaults: ThrowawayDefaults.make("gentle.clip"),
                                   hasChime: true, hasGentleChime: true, timeout: .seconds(30))
        clips.resolve = { _ in source }
        let store = AlarmStore(defaults: ThrowawayDefaults.make("gentle.clip.store"))
        var alarm = BatonAlarm(hour: 7, minute: 0, choice: .song(song), gentleWake: true)
        store.save(alarm)
        XCTAssertEqual(clips.soundName(for: alarm.id, gentle: true), AlarmClipStore.gentleChime,
                       "the faded chime until the clip is made")
        let changed = await clips.prepare(store)
        XCTAssertTrue(changed)
        let gentleURL = sounds.appendingPathComponent("baton-alarm-\(alarm.id.uuidString).gentle.caf")
        XCTAssertEqual(clips.soundName(for: alarm.id, gentle: true), gentleURL.lastPathComponent)
        let info = try XCTUnwrap(AlarmClipStore.clipInfo(at: gentleURL))
        XCTAssertTrue(info.isLinearPCM)
        XCTAssertLessThanOrEqual(info.seconds, 29.05)
        XCTAssertGreaterThan(info.seconds, 28.9)

        let gentle = try rmsDB(gentleURL)
        XCTAssertGreaterThanOrEqual(gentle.count, 28, "29 seconds, whole seconds measured")
        let rise = Array(gentle[0 ..< 20])
        for (a, b) in zip(rise, rise.dropFirst()) { XCTAssertGreaterThan(b, a + 1, "louder every second of the rise") }
        let full = gentle[21 ..< 28]
        let fullLevel = full.reduce(0, +) / Double(full.count)
        XCTAssertEqual(fullLevel, 20 * log10(0.5 / 2.squareRoot()), accuracy: 0.5, "the tone's own level")
        for second in full { XCTAssertEqual(second, fullLevel, accuracy: 0.2, "held at full level after the rise") }
        XCTAssertEqual(fullLevel - gentle[0], 28.5, accuracy: 2, "starts about 30 dB down")

        // Switched off: the plain clip at full level from the start, and the faded one removed.
        alarm.gentleWake = false
        store.save(alarm)
        _ = await clips.prepare(store)
        let plainURL = sounds.appendingPathComponent("baton-alarm-\(alarm.id.uuidString).caf")
        XCTAssertEqual(clips.soundName(for: alarm.id, gentle: false), plainURL.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gentleURL.path))
        let plain = try rmsDB(plainURL)
        XCTAssertEqual(plain[0], fullLevel, accuracy: 0.5)
        XCTAssertEqual(plain[25], fullLevel, accuracy: 0.5)
    }

    /// Without the faded chime bundled, a gentle alarm with no clip rings the plain chime.
    func testAGentleAlarmWithoutTheFadedChimeRingsThePlainOne() {
        let clips = AlarmClipStore(directory: dir, defaults: ThrowawayDefaults.make("gentle.nochime"),
                                   hasChime: true, hasGentleChime: false)
        XCTAssertEqual(clips.soundName(for: UUID(), gentle: true), AlarmClipStore.chime)
    }

    private static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The bundled faded chime, the fallback for a gentle alarm: the same file in both apps,
    /// Linear PCM under 30 seconds; by phrase, louder through the 20-second rise and then at the
    /// plain chime's level.
    func testTheBundledGentleChimeRisesThenMatchesThePlainChime() throws {
        let phone = Self.repo.appendingPathComponent("ios/Resources/BatonAlarmChimeGentle.caf")
        let mac = Self.repo.appendingPathComponent("app/Sources/Baton/Resources/BatonAlarmChimeGentle.caf")
        XCTAssertEqual(try Data(contentsOf: phone), try Data(contentsOf: mac), "one file in both apps")
        let info = try XCTUnwrap(AlarmClipStore.clipInfo(at: phone))
        XCTAssertTrue(info.isLinearPCM)
        XCTAssertLessThan(info.seconds, 30)
        // The bell figure repeats every 3 seconds, so compare phrase by phrase.
        let gentle = try rmsDB(phone, window: 3)
        let plain = try rmsDB(Self.repo.appendingPathComponent("ios/Resources/BatonAlarmChime.caf"), window: 3)
        XCTAssertEqual(gentle.count, 9)
        let rise = Array(gentle[0 ..< 7])
        for (a, b) in zip(rise, rise.dropFirst()) { XCTAssertGreaterThan(b, a + 2, "louder phrase by phrase") }
        XCTAssertLessThan(gentle[0], plain[1] - 20, "the first phrase is quiet")
        XCTAssertEqual(gentle[7], plain[1], accuracy: 0.3, "full level after the rise")
        XCTAssertEqual(gentle[8], plain[1], accuracy: 0.3)
    }
}
#endif
