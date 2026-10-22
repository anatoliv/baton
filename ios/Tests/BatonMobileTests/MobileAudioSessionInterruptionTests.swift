import AVFoundation
import BatonSubsonicKit
import XCTest
@testable import BatonMobile
@testable import BatonPlaybackKit

/// What a call, Siri or an alarm leaves behind when it ends.
///
/// The system's `.shouldResume` says the interruption is over, not that the person wanted
/// Baton playing. A track they had paused before the phone rang started on its own when
/// the call ended. Only playback the interruption itself paused may
/// come back.
@MainActor
final class MobileAudioSessionInterruptionTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("interruption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = ThrowawayDefaults.name("baton.interruption.tests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAPausedTrackStaysPausedWhenACallEndsWithShouldResume() async throws {
        let (controller, session) = try await playingRig()
        controller.pause()
        XCTAssertEqual(controller.state, .paused, "precondition: the person paused it")

        try await interrupt(endingWith: .shouldResume)

        XCTAssertEqual(controller.state, .paused, """
            the call ended and the track the person had paused started playing on its own
            """)
        _ = session
    }

    func testPlaybackTheCallPausedResumesWhenItEnds() async throws {
        let (controller, session) = try await playingRig()

        try await interrupt(endingWith: .shouldResume)

        XCTAssertEqual(controller.state, .playing, "the call paused this, so its end brings it back")
        controller.pause()
        _ = session
    }

    /// CarPlay announcements often end without `.shouldResume`; playing before still resumes.
    func testPlaybackTheCallPausedResumesWithoutTheFlag() async throws {
        let (controller, session) = try await playingRig()

        try await interrupt(endingWith: [])

        XCTAssertEqual(controller.state, .playing, "the CarPlay fallback was lost")
        controller.pause()
        _ = session
    }

    /// Two interruptions began before either ended (Siri over a call): the second found the
    /// track already paused by the first and overwrote "it was playing" with false, so the end
    /// left it paused.
    func testPlaybackResumesAfterTwoBeginningsAndOneEnd() async throws {
        let (controller, session) = try await playingRig()

        post(.began, options: nil)
        try await Task.sleep(for: .milliseconds(100))
        post(.began, options: nil)
        try await Task.sleep(for: .milliseconds(100))
        post(.ended, options: .shouldResume)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(controller.state, .playing, "the second interruption made it forget it was playing")
        controller.pause()
        _ = session
    }

    /// iOS may send a .began with no .ended. If the person then plays and pauses themselves,
    /// the next interruption's end must not resume their pause on the old flag.
    func testAPauseOfTheirOwnAfterALostEndStaysPaused() async throws {
        let (controller, session) = try await playingRig()

        post(.began, options: nil)   // its .ended never comes
        try await Task.sleep(for: .milliseconds(100))
        controller.resume()
        for _ in 0 ..< 40 where controller.state != .playing { try await Task.sleep(for: .milliseconds(50)) }
        controller.pause()
        XCTAssertEqual(controller.state, .paused, "precondition: the person paused it")

        try await interrupt(endingWith: .shouldResume)

        XCTAssertEqual(controller.state, .paused, "a lost .ended left a flag that resumed the person's own pause")
        _ = session
    }

    // MARK: - Helpers

    /// A controller playing a silent local file, with the phone's session rules attached.
    private func playingRig() async throws -> (StreamingPlaybackController, MobileAudioSession) {
        let wav = directory.appendingPathComponent("silence.wav")
        try Self.silentWAV(seconds: 20).write(to: wav)
        let controller = StreamingPlaybackController(
            streamURLProvider: { _ in wav },
            defaults: UserDefaults(suiteName: suiteName),
            systemNowPlaying: false
        )
        controller.crossfadeSeconds = 0
        controller.autoplayEnabled = false
        let session = MobileAudioSession(controller: controller)
        session.configure()
        controller.play([NavidromeSong(id: "silence", title: "Silence", artist: "Tests")])
        for _ in 0 ..< 100 where controller.state != .playing {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controller.state, .playing, "precondition: the silent track plays")
        return (controller, session)
    }

    private func interrupt(endingWith options: AVAudioSession.InterruptionOptions) async throws {
        post(.began, options: nil)
        try await Task.sleep(for: .milliseconds(100))
        post(.ended, options: options)
        try await Task.sleep(for: .milliseconds(300))
    }

    private func post(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions?) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if let options { info[AVAudioSessionInterruptionOptionKey] = options.rawValue }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    /// 16-bit mono PCM at 44.1 kHz, all zeros, so nothing is heard while the tests run.
    private static func silentWAV(seconds: Int) -> Data {
        let rate: UInt32 = 44_100
        let bytes = UInt32(seconds) * rate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }
}
