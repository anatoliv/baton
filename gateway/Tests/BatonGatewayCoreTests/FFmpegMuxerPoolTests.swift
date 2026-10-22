import Foundation
import XCTest
@testable import BatonGatewayCore

/// ffmpeg runs for as long as a chapter takes to encode. Waiting for it on a cooperative-pool
/// thread held that thread for the whole run, so a few chapters at once left nothing to run the
/// gateway's other work on. The wait now happens on a thread of its own.
final class FFmpegMuxerPoolTests: XCTestCase {
    func testEncodesWaitingOnFFmpegLeaveTheCooperativePoolFree() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ffmpeg-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Stands in for an ffmpeg that takes a while: it ignores its arguments and sleeps.
        let slow = directory.appendingPathComponent("slow-ffmpeg")
        try "#!/bin/sh\nsleep 2\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let muxer = FFmpegMuxer(executable: slow.path)
        let wav = directory.appendingPathComponent("in.wav")
        let runs = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)

        let started = Date()
        let encodes = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0 ..< runs {
                    group.addTask {
                        try await muxer.encode(wav: wav, to: directory.appendingPathComponent("\(index).m4a"),
                                               bitrate: 64000, channels: 1, tags: [:])
                    }
                }
                try await group.waitForAll()
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        // A job for the pool while every encode is still waiting on its ffmpeg.
        let answered = await Task.detached { Date() }.value
        XCTAssertLessThan(answered.timeIntervalSince(started), 1.5,
                          "\(runs) ffmpeg waits must not occupy the pool's threads")
        try await encodes.value
    }
}
