@testable import BatonShareKit
import Foundation
import XCTest
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(AVFoundation) && !os(watchOS)
import AVFoundation
#endif

/// The collection cover (a JPEG within the manifest's cap) and the track audio (AAC in M4A).
final class ShareCollectionMediaTests: XCTestCase {
    func testTheContainerIsReadFromTheBytes() {
        XCTAssertEqual(ShareCollectionAudio.container(of: Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])), .mp4)
        XCTAssertEqual(ShareCollectionAudio.container(of: Data([0xFF, 0xF1, 0x50, 0x80])), .adts)
        XCTAssertEqual(ShareCollectionAudio.container(of: Data([0xFF, 0xF9, 0x50, 0x80])), .adts)
        XCTAssertEqual(ShareCollectionAudio.container(of: Data([0xFF, 0xFB, 0x90, 0x64])), .other, "an MP3 frame is not ADTS")
        XCTAssertEqual(ShareCollectionAudio.container(of: Data("ID3".utf8)), .other)
        XCTAssertEqual(ShareCollectionAudio.container(of: Data("fLaC".utf8)), .other)
        XCTAssertEqual(ShareCollectionAudio.fileExtension(contentType: "audio/flac", head: Data()), "flac")
        XCTAssertEqual(ShareCollectionAudio.fileExtension(contentType: nil, head: Data("fLaC....".utf8)), "flac")
        XCTAssertEqual(ShareCollectionAudio.fileExtension(contentType: "audio/mpeg", head: Data([0xFF, 0xF1])), "aac", "bytes win")
        XCTAssertEqual(ShareCollectionAudio.fileExtension(contentType: "application/octet-stream", head: Data("OggS".utf8)), "ogg")
        XCTAssertEqual(ShareCollectionAudio.wireSeconds(240.2), 241)
        XCTAssertEqual(ShareCollectionAudio.wireSeconds(0), 1)
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    /// A noisy image, which JPEG compresses badly, so the size steps are exercised.
    private func image(side: Int, seed: UInt32, type: UTType = .png) -> Data {
        var state = seed
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: side * side * 4)
        for index in 0 ..< side * side * 4 {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func size(_ jpeg: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    func testAnAlbumCoverIsAJPEGWithinTheCapAtMostSixHundredPixels() throws {
        let big = image(side: 1400, seed: 1)
        XCTAssertGreaterThan(big.count, ShareBookManifest.maxCoverBytes)
        let cover = try XCTUnwrap(ShareCollectionCover.jpeg(big))
        XCTAssertLessThanOrEqual(cover.count, ShareBookManifest.maxCoverBytes)
        XCTAssertEqual(ShareCollectionCover.type(of: cover), "image/jpeg")
        let (width, height) = try XCTUnwrap(size(cover))
        XCTAssertLessThanOrEqual(max(width, height), 600)
        XCTAssertNoThrow(try ShareBookManifest.Cover(type: "image/jpeg", bytes: cover).validated())
        // A tighter budget steps down in size or quality rather than failing.
        let small = try XCTUnwrap(ShareCollectionCover.jpeg(big, maxBytes: 20_000))
        XCTAssertLessThanOrEqual(small.count, 20_000)
        XCTAssertNil(ShareCollectionCover.jpeg(Data("not an image".utf8)))
    }

    func testAMosaicIsTwoByTwoFromWhatThereIs() throws {
        let covers = (1 ... 5).map { image(side: 500, seed: UInt32($0)) }
        for count in 1 ... 5 {
            let mosaic = try XCTUnwrap(ShareCollectionCover.mosaic(Array(covers.prefix(count))), "\(count) covers")
            XCTAssertLessThanOrEqual(mosaic.count, ShareBookManifest.maxCoverBytes)
            XCTAssertEqual(ShareCollectionCover.type(of: mosaic), "image/jpeg")
            let (width, height) = try XCTUnwrap(size(mosaic))
            XCTAssertEqual(width, height, "square")
            XCTAssertLessThanOrEqual(width, 600)
        }
        XCTAssertNil(ShareCollectionCover.mosaic([]))
        XCTAssertNil(ShareCollectionCover.mosaic([Data("x".utf8)]))
    }
    #endif

    #if canImport(AVFoundation) && !os(watchOS) && os(macOS)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    /// A 16-bit stereo WAV of a tone, `seconds` long at `rate` Hz.
    private func wav(seconds: Double, rate: Int = 48_000, channels: Int = 2) throws -> URL {
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0 ..< frames {
            let sample = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(rate)) * 12_000)
            for _ in 0 ..< channels { withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var file = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        file += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(channels)) + le(UInt32(rate))
        file += le(UInt32(rate * channels * 2)) + le(UInt16(channels * 2)) + le(UInt16(16))
        file += Data("data".utf8) + le(UInt32(pcm.count)) + pcm
        let url = root.appendingPathComponent("tone-\(UUID().uuidString).wav")
        try file.write(to: url)
        return url
    }

    private func codec(_ url: URL) async throws -> FourCharCode? {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first
        let format = try await track?.load(.formatDescriptions).first
        return format.map(CMFormatDescriptionGetMediaSubType)
    }

    func testAnythingButAACIsConvertedOnTheDeviceToAACInM4A() async throws {
        let input = try wav(seconds: 4.2, rate: 48_000)
        let output = root.appendingPathComponent("out.m4a")
        let made = try await ShareCollectionAudio.makeM4A(from: input, to: output, bitRate: 128_000)
        XCTAssertEqual(made.seconds, 5, "4.2 s measured from the file, rounded up")
        XCTAssertFalse(made.remuxed)
        let data = try Data(contentsOf: output)
        XCTAssertEqual(ShareCollectionAudio.container(of: data), .mp4)
        let written = try await codec(output)
        XCTAssertEqual(written, kAudioFormatMPEG4AAC)
        // 128 kbps for 4.2 s is about 67 KB; a WAV would be 800 KB.
        XCTAssertLessThan(data.count, 120_000)
        XCTAssertGreaterThan(data.count, 30_000)
        // A mono source stays mono, at a lower rate.
        let mono = root.appendingPathComponent("mono.m4a")
        _ = try await ShareCollectionAudio.makeM4A(from: try wav(seconds: 2, rate: 44_100, channels: 1), to: mono, bitRate: 64_000)
        let monoCodec = try await codec(mono)
        XCTAssertEqual(monoCodec, kAudioFormatMPEG4AAC)
    }

    func testEveryRateTheCapsCanChooseEncodesInStereo() async throws {
        // 48 kbps stereo cannot be encoded at 44.1 kHz; the fallback rates must all work, or a
        // long track the planner accepted fails halfway through sealing.
        let input = try wav(seconds: 2, rate: 44_100)
        for rate in [ShareCollectionLimits.musicBitRate] + ShareCollectionLimits.fallbackBitRates {
            let output = root.appendingPathComponent("stereo-\(rate).m4a")
            let made = try await ShareCollectionAudio.makeM4A(from: input, to: output, bitRate: rate)
            XCTAssertFalse(made.remuxed, "\(rate)")
            let written = try await codec(output)
            XCTAssertEqual(written, kAudioFormatMPEG4AAC, "\(rate)")
        }
    }

    func testAnADTSAnswerIsRemuxedIntoM4AUntouched() async throws {
        // What Navidrome's aac transcoding answers: raw ADTS frames, made here with afconvert.
        let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")
        guard FileManager.default.isExecutableFile(atPath: afconvert.path) else { throw XCTSkip("afconvert is not on this Mac") }
        let adts = root.appendingPathComponent("answer.aac")
        let process = Process()
        process.executableURL = afconvert
        process.arguments = ["-f", "adts", "-d", "aac", "-b", "128000", try wav(seconds: 3).path, adts.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let answer = try Data(contentsOf: adts)
        XCTAssertEqual(ShareCollectionAudio.container(of: answer), .adts)
        let output = root.appendingPathComponent("remuxed.m4a")
        let made = try await ShareCollectionAudio.makeM4A(from: adts, to: output, bitRate: 128_000)
        // The AAC priming and the last frame's padding make the copy a little over 3 s.
        XCTAssertTrue((3 ... 4).contains(made.seconds), "\(made.seconds)")
        XCTAssertTrue(made.remuxed, "AAC at the asked rate is copied, not encoded twice")
        let data = try Data(contentsOf: output)
        XCTAssertEqual(ShareCollectionAudio.container(of: data), .mp4)
        let written = try await codec(output)
        XCTAssertEqual(written, kAudioFormatMPEG4AAC)
        // A passthrough keeps the AAC frames: the M4A is the ADTS stream less its 7-byte headers, plus boxes.
        XCTAssertLessThan(abs(data.count - answer.count), answer.count / 5)
    }

    func testUnreadableInputIsRefused() async throws {
        let junk = root.appendingPathComponent("junk.mp3")
        try Data("not audio at all".utf8).write(to: junk)
        do {
            _ = try await ShareCollectionAudio.makeM4A(from: junk, to: root.appendingPathComponent("x.m4a"), bitRate: 128_000)
            XCTFail("junk must not convert")
        } catch {}
    }
    #endif
}
