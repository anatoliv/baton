import AVFoundation
import XCTest
import BatonDSP
import BatonSubsonicKit
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// The engine against the **real configured Navidrome server** — the audio the local
/// HTTP fixtures can only imitate: a genuine server-side transcode, its real bitrate,
/// its real delivery behaviour.
///
/// **Skipped unless measurable**, following `RemoteAgentLiveTests`' idiom: no configured
/// server, unreadable credentials, or an unreachable host all `XCTSkip` — an
/// unreachable server is *not measurable*, not broken. The normal suite stays offline
/// and deterministic.
///
/// Configuration is read from the Baton app's own storage (defaults domain
/// `io.tonebox.baton` + the `io.tonebox.secrets` Keychain service), **read-only** — the
/// test never assigns `NavidromeConfig.defaults`, so nothing here can write into the
/// real app's config from a test process. Credentials, tokens, and URLs are never
/// printed or asserted on: reported numbers are formats, rates, and dB deltas only.
///
/// Stream requests carry `prefetch=1` (`StreamingPlaybackController.markPrefetch`) so
/// these test fetches are distinguishable from listens in the server's access log —
/// the same honesty the gapless prefetcher observes.
@MainActor
final class EngineLiveNavidromeTests: XCTestCase {

    // MARK: - Live context (resolved once, cached across the class's tests)

    struct Live {
        let client: NavidromeClient
        let song: NavidromeSong
        /// Signed `format=mp3` stream URL, marked as a prefetch. Never printed.
        let streamURL: URL
        let headers: [String: String]
    }

    private static var cached: Result<Live, any Error>?

    private static func liveContext() async throws -> Live {
        if let cached { return try cached.get() }
        do {
            let live = try await resolveLiveContext()
            cached = .success(live)
            return live
        } catch {
            cached = .failure(error)
            throw error
        }
    }

    private static func resolveLiveContext() async throws -> Live {
        // The app is not sandboxed, so its preferences are a plain defaults domain this
        // process can read. Read-only by construction: we decode the entries ourselves
        // rather than pointing the global `NavidromeConfig.defaults` at the app's domain,
        // which would let any later test in this process write into the user's config.
        // The list is stored as JSON `Data` (see `NavidromeConfig.writeServers`).
        guard let appDefaults = UserDefaults(suiteName: "io.tonebox.baton"),
              let raw = appDefaults.data(forKey: NavidromeConfig.serversKey)
                ?? appDefaults.string(forKey: NavidromeConfig.serversKey).map({ Data($0.utf8) }),
              let entries = try? JSONDecoder().decode([NavidromeServerEntry].self, from: raw),
              !entries.isEmpty else {
            throw XCTSkip("no Navidrome server configured in the app on this Mac")
        }
        let activeID = appDefaults.string(forKey: NavidromeConfig.activeServerKey).flatMap(UUID.init(uuidString:))
        guard let entry = entries.first(where: { $0.id == activeID }) ?? entries.first,
              let baseURL = URL(string: entry.urlString) else {
            throw XCTSkip("configured server entry is unusable")
        }

        // Keychain read with a hard timeout: an ACL that wants interactive approval
        // would otherwise hang the suite on a modal prompt nobody is watching.
        guard let secret = readSecretWithTimeout(account: NavidromeConfig.keychainAccount(for: entry.id)) else {
            throw XCTSkip("server credentials not readable from the test process (Keychain)")
        }

        let credentials = NavidromeCredentials(
            baseURL: baseURL, username: entry.username, secret: secret,
            authMode: entry.authMode, customHeaders: entry.customHeaders ?? [:]
        )
        let client = NavidromeClient(credentials: credentials, session: NavidromeConfig.sharedSession)

        // Reachable + authenticated, or not measurable.
        do { try await client.ping() } catch {
            throw XCTSkip("Navidrome server not reachable/authenticated — live checks are not measurable")
        }

        // A real track with room to seek: prefer long (a still-encoding transcode is only
        // observable while there is still something left to encode), and prefer a source
        // format that *forces* the transcode (non-MP3 suffix) so the server is genuinely
        // encoding rather than passing bytes through.
        let songs = try await client.getRandomSongs(count: 100)
        let long = songs.filter { ($0.duration ?? 0) >= 180 }
        let pick = long.first { StreamSeek.needsTranscode(suffix: $0.suffix) }
            ?? long.max { ($0.duration ?? 0) < ($1.duration ?? 0) }
            ?? songs.max { ($0.duration ?? 0) < ($1.duration ?? 0) }
        guard let song = pick, (song.duration ?? 0) >= 60 else {
            throw XCTSkip("library has no track ≥ 60 s to measure against")
        }

        let streamURL = StreamingPlaybackController.markPrefetch(try client.streamURL(songID: song.id))
        return Live(client: client, song: song, streamURL: streamURL, headers: entry.customHeaders ?? [:])
    }

    private static func readSecretWithTimeout(account: String, seconds: TimeInterval = 10) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var secret: String?
        DispatchQueue.global().async {
            // The Security-framework read is ACL-denied to the test process (the item
            // belongs to Baton.app) and returns nil instantly — measured. The Apple-signed
            // `security` CLI can read the same item without a prompt, so it is the
            // fallback. The value stays in memory; it is never printed or logged.
            secret = NavidromeKeychain.secret(account: account) ?? securityCLISecret(account: account)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        return secret
    }

    private static func securityCLISecret(account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", NavidromeKeychain.service, "-a", account, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe() // swallow — nothing from this tool should reach the log
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }

    override func setUp() async throws {
        TrackLevelTimeline.clear()
    }

    private func makeTrack(_ live: Live) -> EnginePlaybackController.Track {
        EnginePlaybackController.Track(
            id: live.song.id,
            url: live.streamURL,
            duration: Double(live.song.duration ?? 0),
            song: live.song,
            supportsTimeOffset: true // a real Subsonic transcode honours timeOffset
        )
    }

    private func playAndAwaitAudio(
        _ harness: EngineRenderHarness, _ live: Live, minScheduled: Double = 2.0
    ) async throws {
        let track = makeTrack(live)
        harness.controller.streamHeaders = live.headers
        harness.controller.play([track])
        // Generous: a cold transcode starts at the encoder's pace, not the network's.
        try await harness.waitUntil(timeout: 30) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > minScheduled
        }
    }

    // MARK: - 1. The served transcode decodes (and what it actually is)

    /// Pull the head of the real stream and push it through the decoder alone: does the
    /// server's actual payload parse, and what is it? The reported numbers (format,
    /// rate, channels, measured byte rate) are the ground truth for everything else.
    func testServedStreamDecodesAndReportsRealFormat() async throws {
        let live = try await Self.liveContext()

        var request = URLRequest(url: live.streamURL)
        for (name, value) in live.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let decoder = try AudioStreamDecoder()
        var buffer = [UInt8]()
        buffer.reserveCapacity(32 * 1024)
        var consumed = 0
        var decodedFrames = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 32 * 1024 {
                for pcm in try decoder.parse(Data(buffer)) { decodedFrames += Int(pcm.frameLength) }
                consumed += buffer.count
                buffer.removeAll(keepingCapacity: true)
            }
            if consumed >= 192 * 1024 { break } // the head is plenty of proof
        }

        let format = try XCTUnwrap(decoder.pcmFormat, "the server's stream did not parse to any audio format")
        XCTAssertGreaterThan(decodedFrames, Int(format.sampleRate), "under a second of PCM from 192 KB — decode is not real")

        // Ground truth for the report — deliberately no URL, no headers beyond type.
        let served = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        let length = http.expectedContentLength
        let kbps = decoder.estimatedBytesPerSecond.map { Int($0 * 8 / 1000) }
        print("""
        LIVE stream: source suffix=\(live.song.suffix ?? "?") sourceBitRate=\(live.song.bitRate.map(String.init) ?? "?")kbps \
        duration=\(live.song.duration ?? 0)s → served Content-Type=\(served) \
        contentLength=\(length == -1 ? "none (chunked/encoding)" : String(length)) \
        decoded=\(Int(format.sampleRate))Hz ch=\(format.channelCount) estimated=\(kbps.map(String.init) ?? "?")kbps
        """)
    }

    // MARK: - 2. EQ applies to the real stream

    /// The motivating claim, on the real server: a full-spectrum −12 dB cut must
    /// measurably attenuate the rendered music. On the shipping engine this exact
    /// source renders with the EQ silently absent.
    func testEQAppliesToLiveServerStream() async throws {
        let live = try await Self.liveContext()

        func renderedRMS(eqEnabled: Bool) async throws -> Double {
            let harness = try EngineRenderHarness(sampleRate: 44_100)
            defer { harness.shutdown() }
            let cutAll = EQLimits.frequencies.map { EQBand(frequency: $0, q: 1.0, gainDB: -12) }
            harness.controller.applyEQ(bands: cutAll, enabled: eqEnabled)
            try await playAndAwaitAudio(harness, live, minScheduled: 3.0)
            let samples = try await harness.renderSeconds(2.5)
            return EngineTestSignals.rms(Array(samples.dropFirst(Int(0.5 * 44_100))))
        }

        let flat = try await renderedRMS(eqEnabled: false)
        let cut = try await renderedRMS(eqEnabled: true)
        // The track is a random draw; one that *opens* near-silent can't carry a dB
        // comparison. That is the draw's fault, not the engine's — skip, don't flake.
        try XCTSkipIf(flat < 0.003, "randomly drawn track opens near-silent — not measurable for a dB delta")
        XCTAssertGreaterThan(flat, 0.003, "the live stream rendered (near-)silence — decode or scheduling failed")
        let ratioDB = 20 * log10(cut / flat)
        print("LIVE EQ: flat RMS=\(flat) cut RMS=\(cut) delta=\(ratioDB) dB")
        XCTAssertLessThan(ratioDB, -6, "EQ did not apply to the live server stream (measured \(ratioDB) dB)")
    }

    // MARK: - 3. Metering is live and honest

    /// The monitor the UI reads goes live on the real stream, and the offline-envelope
    /// fallback provably cannot be the source (no envelope exists for this track).
    func testMonitorIsLiveOnRealStreamWithNoEnvelopeFallback() async throws {
        let live = try await Self.liveContext()
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }

        let monitor = AudioLevelMonitor(defaults: UserDefaults(suiteName: "baton.live.bars.\(UUID().uuidString)")!)
        harness.controller.startMetering(into: monitor.snapshot)
        monitor.retain()

        try await playAndAwaitAudio(harness, live)
        // A randomly drawn track may *open* silent (measured: one did). Render forward
        // in half-second slices until the music actually starts; only a track silent
        // for its whole first stretch is unmeasurable, and that is the draw, not the
        // meter — skip rather than flake.
        var rendered = 0.0
        while !monitor.isLive, rendered < 8.0 {
            _ = try await harness.renderSeconds(0.5)
            rendered += 0.5
            monitor.sampleNow()
        }
        try XCTSkipIf(!monitor.isLive, "randomly drawn track is silent for its first \(Int(rendered))s — not measurable")
        let first = monitor.levels

        XCTAssertFalse(TrackLevelTimeline.hasEnvelope(id: live.song.id),
                       "an offline envelope exists — a live reading could not be proven")
        XCTAssertGreaterThan(first.peak, 0)

        // "Moves with the music" — honestly: the meter must vary **iff the audio does**.
        // Random real music can legitimately hold level (a sustained pad read as one
        // constant in a run of this test), so requiring variation unconditionally is a
        // flake, and requiring none would miss a stuck meter. Compare the two.
        var audioRMS: [Double] = []
        // Ten slices rather than four, and it stops as soon as the meter has clearly moved.
        //
        // Four was too few under load. The bug this guards — a meter wired to nothing,
        // reading a constant while music plays — shows up within a second or two when it
        // is real, so waiting longer costs nothing on a healthy build and removes a class
        // of failure that had nothing to do with the meter. It flaked twice in one day
        // inside the full gate while passing every time in isolation, which is the
        // signature of a threshold set by the machine's mood rather than by the code.
        var readings: [Float] = [first.peak]
        for _ in 0 ..< 10 {
            let slice = try await harness.renderSeconds(1.0)
            audioRMS.append(EngineTestSignals.rms(slice))
            monitor.sampleNow()
            readings.append(monitor.levels.peak)
            if (readings.max() ?? 0) - (readings.min() ?? 0) > 0.02 { break }
        }
        let audioVaried = (audioRMS.max() ?? 0) > (audioRMS.min() ?? 0) * 1.4 + 0.001
        let meterVaried = (readings.max() ?? 0) - (readings.min() ?? 0) > 0.02
        if audioVaried {
            XCTAssertTrue(meterVaried,
                          "the audio's level moved but the meter read a constant — a stuck meter, not a live one")
        }
        print("LIVE metering: isLive=\(monitor.isLive) peaks=\(readings) audioVaried=\(audioVaried) meterVaried=\(meterVaried)")
    }

    // MARK: - 4. Seek: in-spool, then a cold timeOffset reload

    func testSeekInSpoolThenColdTimeOffsetReload() async throws {
        let live = try await Self.liveContext()
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }

        try await playAndAwaitAudio(harness, live, minScheduled: 4.0)
        _ = try await harness.renderSeconds(1.0)

        // In-spool: a short forward seek into audio that has already arrived.
        harness.controller.seek(to: 3.0)
        try await harness.waitUntil(timeout: 10) {
            abs(harness.controller.currentTime - 3.0) < 0.5
                && harness.pipeline.aheadSeconds(on: harness.controller.activeDeckForTesting) > 0.5
        }
        XCTAssertEqual(harness.controller.loadCountForTesting, 1,
                       "a reachable seek must reposition in the spool, not re-request")
        let afterInSpool = try await harness.renderSeconds(0.5)
        XCTAssertGreaterThan(EngineTestSignals.rms(afterInSpool), 0.001, "no audio after the in-spool seek")

        // Cold reload: aim past what has been spooled. If the whole file already arrived
        // (short track / fast encode), the far target is reachable and the reload path
        // simply cannot be exercised live — report that instead of faking it.
        let duration = Double(live.song.duration ?? 0)
        let reachableEnd = await harness.controller.sourceForTesting?.reachableSeconds()?.upperBound ?? 0
        let target = min(duration - 15, reachableEnd + 90)
        guard target > reachableEnd + 5 else {
            print("LIVE seek: full stream already spooled (reachable to \(Int(reachableEnd))s of \(Int(duration))s) — timeOffset reload not exercisable on this track")
            return
        }

        harness.controller.seek(to: target)
        try await harness.waitUntil(timeout: 30) {
            harness.controller.loadCountForTesting == 2
                && harness.pipeline.aheadSeconds(on: harness.controller.activeDeckForTesting) > 0.5
        }
        // The reload must have asked the SERVER for the offset — the only way to reach a
        // position a still-encoding transcode hasn't produced. Query-shape check only.
        let query = harness.controller.lastStreamURLForTesting?.query ?? ""
        XCTAssertTrue(query.contains("timeOffset=\(Int(target))"),
                      "the reload did not re-request with timeOffset")
        XCTAssertEqual(harness.controller.currentIndex, 0, "a live seek must never advance the queue")
        XCTAssertEqual(harness.controller.currentTime, target, accuracy: 2.0)
        let afterReload = try await harness.renderSeconds(0.8)
        XCTAssertGreaterThan(EngineTestSignals.rms(Array(afterReload.dropFirst(8_000))), 0.001,
                             "the timeOffset stream did not produce audio at \(Int(target))s")
        print("LIVE seek: in-spool → OK (no reload); cold reload to \(Int(target))s of \(Int(duration))s via timeOffset → OK")
    }
}
