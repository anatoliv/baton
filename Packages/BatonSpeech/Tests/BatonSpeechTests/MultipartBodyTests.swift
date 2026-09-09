import XCTest
@testable import BatonSpeech

/// Staging a transcription upload on disk.
///
/// Two things have to hold at once and they pull against each other. The bytes must match the
/// multipart form the servers already accept, exactly, because a stray CRLF or a lost boundary
/// breaks every transcription rather than one. And the body must be assembled without ever
/// holding the audio in memory, because the stated use case is a 90 minute podcast on a phone.
/// So: the streamed writer is checked byte for byte against the in-memory reference, and then
/// measured for what it costs in RAM. (S-F23)
final class MultipartBodyTests: XCTestCase {
    private let fields: [(name: String, value: String)] = [
        ("model", "whisper-1"),
        ("response_format", "verbose_json"),
        ("vad_filter", "true"),
    ]

    /// A directory of this test's own, so listing what was staged is cheap and exact. The
    /// shared temporary directory on a working Mac can hold hundreds of thousands of entries
    /// (583,401 on the machine this was written on, 14 s to list), which is not a thing to put
    /// inside an assertion.
    private var stagingDirectory: URL!

    override func setUpWithError() throws {
        stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-speech-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
    }

    private func temporaryFile(bytes: Int, chunk: Int = 1 << 20) throws -> URL {
        let url = stagingDirectory
            .appendingPathComponent("baton-speech-test-\(UUID().uuidString).bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written = 0
        // A repeating pattern rather than zeroes, so a chunk written twice or in the wrong
        // order shows up as a byte difference instead of matching by accident.
        var pattern = Data(count: min(chunk, max(bytes, 1)))
        for i in 0 ..< pattern.count { pattern[i] = UInt8((i * 31 + 7) % 251) }
        while written < bytes {
            let take = min(pattern.count, bytes - written)
            try handle.write(contentsOf: pattern.prefix(take))
            written += take
        }
        return url
    }

    // MARK: - The wire format

    /// The streamed file and the in-memory body are the same bytes, over a payload that spans
    /// several chunks and ends mid-chunk.
    func testStagedBodyMatchesTheInMemoryBodyByteForByte() throws {
        let audio = try temporaryFile(bytes: 10_000)
        defer { try? FileManager.default.removeItem(at: audio) }

        let staged = try TranscriptionService.writeMultipartBody(
            fields: fields, fileURL: audio, boundary: "BOUNDARY", chunkSize: 997, in: stagingDirectory
        )
        defer { try? FileManager.default.removeItem(at: staged) }

        let expected = TranscriptionService.multipartBody(
            fields: fields,
            fileName: audio.lastPathComponent,
            fileData: try Data(contentsOf: audio),
            boundary: "BOUNDARY"
        )
        let actual = try Data(contentsOf: staged)
        XCTAssertEqual(actual.count, expected.count, "the staged body is a different length")
        XCTAssertEqual(actual, expected, "the staged body drifted from the wire format")
    }

    /// The same, on a single-byte file and a chunk larger than the whole payload, so the loop
    /// runs exactly once and the trailer still lands.
    func testAOneByteFileStagesTheSameBytes() throws {
        let audio = try temporaryFile(bytes: 1)
        defer { try? FileManager.default.removeItem(at: audio) }

        let staged = try TranscriptionService.writeMultipartBody(
            fields: fields, fileURL: audio, boundary: "B", in: stagingDirectory
        )
        defer { try? FileManager.default.removeItem(at: staged) }

        let expected = TranscriptionService.multipartBody(
            fields: fields, fileName: audio.lastPathComponent,
            fileData: try Data(contentsOf: audio), boundary: "B"
        )
        XCTAssertEqual(try Data(contentsOf: staged), expected)
        let text = String(decoding: expected, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"), "the terminating boundary is the wire format")
    }

    /// An empty file is still refused, and nothing is staged.
    func testAnEmptyFileIsRefusedAndStagesNothing() throws {
        let audio = try temporaryFile(bytes: 0)
        XCTAssertThrowsError(
            try TranscriptionService.writeMultipartBody(
                fields: fields, fileURL: audio, boundary: "B", in: stagingDirectory
            )
        ) { error in
            let message = (error as? TranscriptionService.TranscribeError)?.message ?? ""
            XCTAssertTrue(message.contains("empty"), "unexpected message: \(message)")
        }
        XCTAssertEqual(try stagedFileCount(), 0, "a refused upload left a staged body behind")
    }

    /// A source that cannot be opened fails *after* the staging file exists, which is the path
    /// that has to clean up after itself.
    func testAnUnreadableFileLeavesNoStagedBody() throws {
        let audio = try temporaryFile(bytes: 4_096)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: audio.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audio.path) }

        XCTAssertThrowsError(
            try TranscriptionService.writeMultipartBody(
                fields: fields, fileURL: audio, boundary: "B", in: stagingDirectory
            )
        ) { error in
            let message = (error as? TranscriptionService.TranscribeError)?.message ?? ""
            XCTAssertTrue(message.contains("stage the upload"), "unexpected message: \(message)")
        }
        XCTAssertEqual(try stagedFileCount(), 0, "a failed upload left a staged body behind")
    }

    func testAMissingFileIsReportedAsUnreadable() {
        let missing = stagingDirectory
            .appendingPathComponent("baton-speech-absent-\(UUID().uuidString).bin")
        XCTAssertThrowsError(
            try TranscriptionService.writeMultipartBody(
                fields: fields, fileURL: missing, boundary: "B", in: stagingDirectory
            )
        ) { error in
            let message = (error as? TranscriptionService.TranscribeError)?.message ?? ""
            XCTAssertTrue(message.contains("Couldn't read the audio"), "unexpected message: \(message)")
        }
    }

    private func stagedFileCount() throws -> Int {
        let names = try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)
        return names.filter { $0.hasPrefix("baton-transcribe-") }.count
    }

    // MARK: - What it costs in memory

    /// A 200 MB file staged for upload must not cost 200 MB of RAM.
    ///
    /// The measurement is `resident_size_max` from `mach_task_basic_info`, a high-water mark
    /// the kernel keeps for the task, so it answers "how much did this ever hold" rather than
    /// "how much is it holding now" and cannot be flattered by a free that happens before the
    /// assertion. The old implementation read the file (mapped, but mapped pages are resident
    /// once touched) and then copied it into a heap `Data`, so this went up by roughly twice
    /// the file size.
    func testStagingA200MBFileDoesNotHoldItInMemory() throws {
        let fileSize = 200 * 1_024 * 1_024
        guard let free = try? volumeFreeBytes(), free > Int64(fileSize) * 3 else {
            throw XCTSkip("not enough free space on the temporary volume to stage a 200 MB file")
        }
        let audio = try temporaryFile(bytes: fileSize)
        defer { try? FileManager.default.removeItem(at: audio) }

        let before = try peakResidentBytes()
        let staged = try TranscriptionService.writeMultipartBody(
            fields: fields, fileURL: audio, boundary: "BOUNDARY", in: stagingDirectory
        )
        defer { try? FileManager.default.removeItem(at: staged) }
        let after = try peakResidentBytes()

        let stagedSize = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(stagedSize, fileSize, "the staged body is smaller than the audio")

        // 64 MB of headroom over the chunk buffer: enough that the test framework's own
        // allocations and a page-cache flush cannot fail it, and far under the 200 MB the
        // old implementation cost.
        let allowance = 64 * 1_024 * 1_024
        let growth = after - before
        XCTAssertLessThan(
            growth, allowance,
            "staging a \(fileSize / 1_048_576) MB upload grew peak resident memory by \(growth / 1_048_576) MB"
        )
    }

    private func peakResidentBytes() throws -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw XCTSkip("task_info is unavailable: \(result)") }
        return Int(info.resident_size_max)
    }

    private func volumeFreeBytes() throws -> Int64 {
        let values = try FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
