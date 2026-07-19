import AVFoundation
import Foundation
import Observation
import OSLog
import SwiftUI

private let radioStoreLog = Logger(subsystem: "io.tonebox.macos", category: "InternetRadio")

// MARK: - Details resolved off-server

/// Lightweight per-station details that Navidrome doesn't store (genre, bitrate) but the
/// stream's ICY response headers usually do. Resolved lazily and cached.
struct RadioStationMeta: Equatable, Sendable {
    var genre: String?
    var bitrateKbps: Int?

    /// A "Trance · 256 kbps" style subtitle, or nil when nothing is known yet.
    var subtitle: String? {
        var parts: [String] = []
        if let genre, !genre.isEmpty { parts.append(genre) }
        if let bitrateKbps, bitrateKbps > 0 { parts.append("\(bitrateKbps) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Resolution state for a station's logo. `.unresolved` means we haven't looked yet;
/// `.none` means we looked and found nothing (→ show a monogram); `.logo` carries the URL.
enum RadioArtwork: Equatable, Sendable {
    case unresolved
    case none
    case logo(URL)
}

// MARK: - Store

/// Owns the internet-radio station list, the raw-stream player, and the lazily-resolved
/// extras (now-playing track, genre/bitrate, station logos). Lives on `MusicModel` so the
/// sidebar badge, the Radio screen, and the global player bar all read one source of truth.
@MainActor
@Observable
final class InternetRadioStore {
    /// Stations synced from the server (`getInternetRadioStations`).
    private(set) var stations: [NavidromeRadioStation] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var loadError: String?

    /// The raw-stream player for the on-air station (separate from the library transport).
    let engine = RadioPlaybackEngine()

    /// The library player to duck while a station is on the air — set by `MusicModel`.
    @ObservationIgnored weak var duckController: StreamingPlaybackController?

    /// id → resolved genre/bitrate, and id → logo resolution. Both cached across visits.
    private(set) var meta: [String: RadioStationMeta] = [:]
    private(set) var artwork: [String: RadioArtwork] = [:]
    @ObservationIgnored private var metaInFlight: Set<String> = []
    @ObservationIgnored private var artworkInFlight: Set<String> = []

    @ObservationIgnored private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    // MARK: List

    /// Fetch the station list once. Safe to call from several places (sidebar prefetch,
    /// Radio screen) — guarded so it only fetches the first time.
    func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        await reload()
    }

    /// Force a fresh fetch (used after add/edit/delete and by the Radio screen's retry).
    func reload() async {
        guard NavidromeConfig.isConfigured else {
            loadError = "No music server is configured."
            loaded = true
            return
        }
        loading = true
        loadError = nil
        defer { loading = false; loaded = true }
        do {
            let client = try NavidromeConfig.makeClient()
            stations = try await client.getInternetRadioStations()
        } catch {
            loadError = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
            radioStoreLog.error("load stations failed: \(self.loadError ?? "", privacy: .public)")
        }
    }

    // MARK: Playback

    var onAirStation: NavidromeRadioStation? { engine.currentStation }
    func isOnAir(_ station: NavidromeRadioStation) -> Bool { engine.currentStation?.id == station.id }
    func isPlaying(_ station: NavidromeRadioStation) -> Bool { isOnAir(station) && engine.isPlaying }

    /// Play a station, or stop it if it's already the on-air one.
    func toggle(_ station: NavidromeRadioStation) {
        if isOnAir(station) { engine.stop(); return }
        play(station)
    }

    func play(_ station: NavidromeRadioStation) {
        guard let url = station.streamURL else {
            duckController?.postToast("Station has no valid stream URL", symbol: "exclamationmark.triangle")
            return
        }
        // Duck the library player so the two transports never overlap.
        duckController?.acquireAudioFocusSuspend(owner: "radio")
        engine.play(station: station, url: url)
        // Start at the shared bottom-bar volume so the one slider governs radio too.
        if let ctrl = duckController {
            engine.setVolume(percent: ctrl.volumePercent)
            engine.setMuted(ctrl.isMuted)
        }
    }

    func stop() { engine.stop() }

    /// Switch to the station `delta` places away in the list (wrapping) — drives the
    /// bottom bar's prev/next in radio mode. No-op if fewer than two stations.
    func playAdjacent(_ delta: Int) {
        guard stations.count > 1, let current = engine.currentStation,
              let idx = stations.firstIndex(where: { $0.id == current.id }) else { return }
        let next = stations[((idx + delta) % stations.count + stations.count) % stations.count]
        play(next)
    }

    // MARK: Mutations

    func add(name: String, streamURL: String, homepage: String?) async {
        await mutate {
            try await NavidromeConfig.makeClient()
                .createInternetRadioStation(name: name, streamUrl: streamURL, homepageUrl: homepage)
        }
    }

    func update(_ station: NavidromeRadioStation, name: String, streamURL: String, homepage: String?) async {
        await mutate {
            try await NavidromeConfig.makeClient()
                .updateInternetRadioStation(id: station.id, name: name, streamUrl: streamURL, homepageUrl: homepage)
        }
    }

    func delete(_ station: NavidromeRadioStation) async {
        if isOnAir(station) { engine.stop() }
        await mutate {
            try await NavidromeConfig.makeClient().deleteInternetRadioStation(id: station.id)
        }
    }

    private func mutate(_ op: @Sendable () async throws -> Void) async {
        do {
            try await op()
            await reload()
        } catch {
            let message = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
            duckController?.postToast(message, symbol: "exclamationmark.triangle")
            radioStoreLog.error("station mutation failed: \(message, privacy: .public)")
        }
    }

    // MARK: Lazy details — genre/bitrate from ICY headers

    /// Probe a station's stream for `icy-genre` / `icy-br` headers (best-effort, cached).
    func resolveMeta(for station: NavidromeRadioStation) {
        guard meta[station.id] == nil, !metaInFlight.contains(station.id),
              let url = station.streamURL else { return }
        metaInFlight.insert(station.id)
        Task { [weak self] in
            guard let self else { return }
            let result = await Self.probeICYHeaders(url: url, session: self.session)
            self.metaInFlight.remove(station.id)
            if let result { self.meta[station.id] = result }
        }
    }

    private nonisolated static func probeICYHeaders(url: URL, session: URLSession) async -> RadioStationMeta? {
        var req = URLRequest(url: url)
        req.setValue("0", forHTTPHeaderField: "Icy-MetaData")
        req.setValue("Baton (macOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: req)
            defer { bytes.task.cancel() } // read headers only, don't drain the stream
            guard let http = response as? HTTPURLResponse else { return nil }
            let genre = http.value(forHTTPHeaderField: "icy-genre")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let br = http.value(forHTTPHeaderField: "icy-br").flatMap { Int($0.split(separator: ",").first.map(String.init) ?? $0) }
            let cleanedGenre = (genre?.isEmpty ?? true) ? nil : genre?.capitalized
            if cleanedGenre == nil, br == nil { return nil }
            return RadioStationMeta(genre: cleanedGenre, bitrateKbps: br)
        } catch {
            return nil
        }
    }

    // MARK: Lazy details — station logo from its homepage

    /// Resolve a station's logo URL from its homepage (apple-touch-icon / og:image / favicon).
    /// Best-effort and cached; a `.none` result tells the UI to draw a monogram instead.
    func resolveArtwork(for station: NavidromeRadioStation) {
        guard artwork[station.id] == nil, !artworkInFlight.contains(station.id) else { return }
        guard let home = station.homepageUrl, let homeURL = URL(string: home) else {
            artwork[station.id] = .none
            return
        }
        artworkInFlight.insert(station.id)
        Task { [weak self] in
            guard let self else { return }
            let found = await Self.findLogo(homepage: homeURL, session: self.session)
            self.artworkInFlight.remove(station.id)
            self.artwork[station.id] = found.map { RadioArtwork.logo($0) } ?? .none
        }
    }

    private nonisolated static func findLogo(homepage: URL, session: URLSession) async -> URL? {
        var req = URLRequest(url: homepage)
        req.setValue("Mozilla/5.0 (Macintosh) Baton", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            return fallbackIcon(homepage)
        }
        let base = http.url ?? homepage
        let html = String(decoding: data.prefix(200_000), as: UTF8.self)
        // Priority: apple-touch-icon (usually 180px, crisp) → og:image → rel="icon".
        let patterns = [
            #"<link[^>]+rel=["'][^"']*apple-touch-icon[^"']*["'][^>]+href=["']([^"']+)["']"#,
            #"<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*apple-touch-icon[^"']*["']"#,
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<link[^>]+rel=["'](?:shortcut )?icon["'][^>]+href=["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            if let href = firstCapture(pattern, in: html), let resolved = URL(string: href, relativeTo: base)?.absoluteURL {
                return resolved
            }
        }
        return fallbackIcon(base)
    }

    /// A last-resort guess when the homepage doesn't advertise an icon — many sites still
    /// serve `/apple-touch-icon.png`. `AsyncImage` falls back to the monogram if it 404s.
    private nonisolated static func fallbackIcon(_ url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return URL(string: "\(scheme)://\(host)/apple-touch-icon.png")
    }

    private nonisolated static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Raw-stream playback engine

/// A minimal `AVPlayer` wrapper that plays one raw internet-radio stream at a time and
/// surfaces the live ICY `StreamTitle` (the currently-playing track most Shoutcast/Icecast
/// stations broadcast). Deliberately separate from `StreamingPlaybackController`: a station
/// is an endless stream with no song id, duration, or queue.
@MainActor
@Observable
final class RadioPlaybackEngine {
    /// The station currently loaded (playing or buffering), if any.
    private(set) var currentStation: NavidromeRadioStation?
    /// True while audio is actually flowing (derived from the player's timeControlStatus).
    private(set) var isPlaying = false
    /// The live "Artist – Title" the station is broadcasting right now (ICY metadata), if any.
    private(set) var nowPlayingTitle: String?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var metadataOutput: AVPlayerItemMetadataOutput?
    @ObservationIgnored private var metadataReceiver: ICYMetadataReceiver?

    init() {
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            MainActor.assumeIsolated { self?.isPlaying = player.timeControlStatus == .playing }
        }
    }

    /// Start playing `station` from its raw stream `url`, replacing any current one.
    func play(station: NavidromeRadioStation, url: URL) {
        currentStation = station
        nowPlayingTitle = nil

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        let receiver = ICYMetadataReceiver { [weak self] title in
            MainActor.assumeIsolated { self?.nowPlayingTitle = title }
        }
        output.setDelegate(receiver, queue: .main)
        item.add(output)
        metadataOutput = output
        metadataReceiver = receiver

        player.replaceCurrentItem(with: item)
        player.play()
        radioStoreLog.info("radio playing station \(station.id, privacy: .public)")
    }

    /// Pause the live stream (keeps the station on air so the bar's play button resumes it).
    func pause() { player.pause() }

    /// Resume after a pause — reconnects to the live edge.
    func resume() { player.play() }

    /// Set output volume (0–100) and mute — mirrored from the shared player volume so the
    /// one bottom-bar volume slider controls radio too.
    func setVolume(percent: Int) { player.volume = Float(max(0, min(percent, 100))) / 100 }
    func setMuted(_ muted: Bool) { player.isMuted = muted }

    /// Stop playback and clear the on-air station.
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStation = nil
        isPlaying = false
        nowPlayingTitle = nil
        metadataOutput = nil
        metadataReceiver = nil
    }
}

/// Bridges AVFoundation's timed-metadata callback (delivered on the main queue) to a closure
/// that updates the engine's `nowPlayingTitle`. Reads the ICY `StreamTitle` string.
private final class ICYMetadataReceiver: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let onTitle: @Sendable (String?) -> Void
    init(onTitle: @escaping @Sendable (String?) -> Void) { self.onTitle = onTitle }

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        var title: String?
        for group in groups {
            for item in group.items where item.identifier == .icyMetadataStreamTitle || item.commonKey == .commonKeyTitle {
                if let value = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    title = value
                }
            }
        }
        onTitle(title)
    }
}
