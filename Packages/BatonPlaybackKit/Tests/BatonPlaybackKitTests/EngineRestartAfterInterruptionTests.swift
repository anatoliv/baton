import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// Playing a node on a stopped engine must not be possible.
///
/// `AVAudioPlayerNode.play()` on a stopped engine raises an ObjC exception, and that
/// exception unwinding through Swift-concurrency frames corrupts the task allocator — so
/// the process aborts somewhere else entirely with a "freed pointer was not the last
/// allocation" that names none of this. It was found once by bisection.
///
/// The engine can be stopped without anyone here asking: an `AVAudioSession` interruption —
/// a phone call — stops it, and an interruption does not reliably post a configuration
/// change, so none of the restarts in `EngineAudioPipeline` need ever run. Every
/// `pipeline.play` caller was exposed, including the feeder, which is reached by tapping
/// any track at all. The mainstream path was: pause Baton, watch something in another app,
/// come back, tap a track.
///
/// The guard lives in `play` rather than on the resume path precisely so that all three
/// callers are covered by construction rather than by remembering.
@MainActor
final class EngineRestartAfterInterruptionTests: XCTestCase {

    private func makePipeline() throws -> EngineAudioPipeline {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        return try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
    }

    func testPlayRestartsAnEngineStoppedByAnInterruption() throws {
        let pipeline = try makePipeline()
        defer { pipeline.shutdown() }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        pipeline.prepareDeck(.a, format: format)

        // What a phone call does to us.
        pipeline.stopEngineForTesting()
        XCTAssertFalse(pipeline.isEngineRunningForTesting, "precondition: the engine is stopped")

        // The line that used to raise, from the same call the feeder makes on every track.
        pipeline.play(.a)

        XCTAssertTrue(
            pipeline.isEngineRunningForTesting,
            """
            play() left the engine stopped. Either it played a node on a stopped engine — \
            which raises, and takes the process down in an unrelated frame — or it refused \
            and the track is silent with no explanation.
            """
        )
    }

    /// The guard must not fire only once. An interruption can happen on every track.
    func testItSurvivesRepeatedInterruptions() throws {
        let pipeline = try makePipeline()
        defer { pipeline.shutdown() }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        pipeline.prepareDeck(.a, format: format)

        for round in 1 ... 3 {
            pipeline.stopEngineForTesting()
            pipeline.play(.a)
            XCTAssertTrue(pipeline.isEngineRunningForTesting,
                          "the engine stayed stopped on interruption \(round)")
        }
    }

    /// An unprepared deck must still be refused — the new restart must not have widened
    /// what `play` accepts.
    func testAnUnpreparedDeckIsStillRefused() throws {
        let pipeline = try makePipeline()
        defer { pipeline.shutdown() }

        pipeline.stopEngineForTesting()
        pipeline.play(.b)   // never prepared

        XCTAssertFalse(
            pipeline.isEngineRunningForTesting,
            "play() restarted the engine for a deck it then refused to play — the guard order is wrong"
        )
    }

    /// Metering must follow ownership, not attachment.
    ///
    /// The render tap was installed once per host and never removed — `stopMetering` had a
    /// single caller, `shutdown()`, which production never runs — so it analysed whatever
    /// the graph rendered, silence included, about forty times a second for the life of the
    /// process. `AudioLevelMonitor` idles carefully all the way off; this undercut it a
    /// layer below, where nothing was looking.
    ///
    /// Asserted on the source because the rule that matters is *where* it lives: on the
    /// `engineOwnsPlayback` transition rather than at the five places that assign it. Every
    /// engine bug found by ear in this project has been a rule spread across call sites and
    /// missed at one of them.
    func testMeteringIsTiedToTheOwnershipTransition() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BatonPlaybackKit/StreamingPlaybackController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let declaration = try XCTUnwrap(
            source.range(of: "private var engineOwnsPlayback = false {"),
            "engineOwnsPlayback no longer observes its own transitions — metering will run forever again"
        )
        let block = String(source[declaration.upperBound...].prefix(1800))
        XCTAssertTrue(block.contains("resumeMetering()"),
                      "taking ownership does not resume metering, so the bars will be dead")
        XCTAssertTrue(block.contains("suspendMetering()"),
                      "losing ownership does not suspend metering, so the tap analyses silence forever")
    }

}
