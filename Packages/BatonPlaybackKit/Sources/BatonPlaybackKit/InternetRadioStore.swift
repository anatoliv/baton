import AVFoundation
import Foundation
import Observation
import OSLog
import SwiftUI
import BatonSubsonicKit

private let radioStoreLog = Logger(subsystem: "io.tonebox.baton", category: "InternetRadio")

// Moved here from the Mac app so the phone runs the same radio implementation rather
// than a second one: the ICY-title cleanup, the header probing and the logo resolution
// are all fiddly, all learned from real stations, and all worth having in one place.

// MARK: - Details resolved off-server

/// Lightweight per-station details that Navidrome doesn't store (genre, bitrate) but the
/// stream's ICY response headers usually do. Resolved lazily and cached.
public struct RadioStationMeta: Equatable, Sendable {
    public var genre: String?
    public var bitrateKbps: Int?

    /// A "Trance · 256 kbps" style subtitle, or nil when nothing is known yet.
    public var subtitle: String? {
        var parts: [String] = []
        if let genre, !genre.isEmpty { parts.append(genre) }
        if let bitrateKbps, bitrateKbps > 0 { parts.append("\(bitrateKbps) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Resolution state for a station's logo. `.unresolved` means we haven't looked yet;
/// `.none` means we looked and found nothing (→ show a monogram); `.logo` carries the URL.
public enum RadioArtwork: Equatable, Sendable {
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
public final class InternetRadioStore {
    /// Stations synced from the server (`getInternetRadioStations`).
    public private(set) var stations: [NavidromeRadioStation] = []
    public private(set) var loaded = false
    public private(set) var loading = false
    public private(set) var loadError: String?

    /// The raw-stream player for the on-air station (separate from the library transport).
    public let engine = RadioPlaybackEngine()

    /// The library player to duck while a station is on the air — set by `bind(to:)`.
    @ObservationIgnored public weak var duckController: StreamingPlaybackController?

    /// The order the Radio screen is currently showing (its filter + sort). The bottom bar's
    /// prev/next walk this so they match what the user sees; falls back to `stations` until the
    /// screen sets it.
    @ObservationIgnored public var orderedStations: [NavidromeRadioStation] = []

    /// id → resolved genre/bitrate, and id → logo resolution. Both cached across visits.
    public private(set) var meta: [String: RadioStationMeta] = [:]
    public private(set) var artwork: [String: RadioArtwork] = [:]
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
    public func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        await reload()
    }

    /// Force a fresh fetch (used after add/edit/delete and by the Radio screen's retry).
    public func reload() async {
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

    public init() {
        // Surface a station whose stream fails as a toast, rather than a silent "on air".
        engine.onError = { [weak self] message in
            self?.duckController?.postToast(message, symbol: "wifi.slash")
        }
    }

    /// Connect the station engine to the library transport — the whole relationship between
    /// the two, in one call.
    ///
    /// A station and the library queue are two engines sharing one pair of speakers, so they
    /// have to agree about who has them: the library ducks while a station is on the air, a
    /// media key that arrives during a broadcast drives the station rather than resuming the
    /// library underneath it, and a library track starting takes the output back.
    ///
    /// It lives here rather than in each app's composition root because it used to live in
    /// both: the Mac wired all of it, the phone wired only the duck, and the phone would
    /// happily play a station and a track at the same time.
    public func bind(to controller: StreamingPlaybackController) {
        duckController = controller
        controller.radioIsOnAir = { [weak self] in self?.onAirStation != nil }
        controller.radioRemote = .init(
            play: { [weak self] in
                guard let self, let station = onAirStation, !isPlaying(station) else { return }
                play(station)
            },
            // A live stream has no "where we left off", so leaving the air is the honest
            // reading of pause — and it is what the library takes the output back with.
            pause: { [weak self] in self?.stop() },
            toggle: { [weak self] in
                guard let self, let station = onAirStation else { return }
                toggle(station)
            },
            next: { [weak self] in self?.playAdjacent(1) },
            previous: { [weak self] in self?.playAdjacent(-1) }
        )
    }

    public var onAirStation: NavidromeRadioStation? { engine.currentStation }
    public func isOnAir(_ station: NavidromeRadioStation) -> Bool { engine.currentStation?.id == station.id }
    public func isPlaying(_ station: NavidromeRadioStation) -> Bool { isOnAir(station) && engine.isPlaying }

    /// Play a station, or stop it if it's already the on-air one.
    public func toggle(_ station: NavidromeRadioStation) {
        if isOnAir(station) { engine.stop(); return }
        play(station)
    }

    public func play(_ station: NavidromeRadioStation) {
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

    public func stop() { engine.stop() }

    /// Switch to the station `delta` places away (wrapping) in the order the Radio screen is
    /// showing — so the bottom bar's prev (−1) / next (+1) match what the user sees regardless
    /// of the current sort. No-op if fewer than two stations.
    public func playAdjacent(_ delta: Int) {
        let order = orderedStations.isEmpty ? stations : orderedStations
        guard order.count > 1, let current = engine.currentStation,
              let idx = order.firstIndex(where: { $0.id == current.id }) else { return }
        let next = order[((idx + delta) % order.count + order.count) % order.count]
        play(next)
    }

    // MARK: Mutations

    public func add(name: String, streamURL: String, homepage: String?) async {
        await mutate {
            try await NavidromeConfig.makeClient()
                .createInternetRadioStation(name: name, streamUrl: streamURL, homepageUrl: homepage)
        }
    }

    public func update(_ station: NavidromeRadioStation, name: String, streamURL: String, homepage: String?) async {
        await mutate {
            try await NavidromeConfig.makeClient()
                .updateInternetRadioStation(id: station.id, name: name, streamUrl: streamURL, homepageUrl: homepage)
        }
    }

    public func delete(_ station: NavidromeRadioStation) async {
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
    public func resolveMeta(for station: NavidromeRadioStation) {
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
    public func resolveArtwork(for station: NavidromeRadioStation) {
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
public final class RadioPlaybackEngine {
    /// The station currently loaded (playing or buffering), if any.
    public private(set) var currentStation: NavidromeRadioStation?
    /// True while audio is actually flowing (derived from the player's timeControlStatus).
    public private(set) var isPlaying = false
    /// The live "Artist – Title" the station is broadcasting right now (ICY metadata), if any.
    public private(set) var nowPlayingTitle: String?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let transportFade = TransportFade()
    /// The user's level, kept so `applyVolume()` can recombine it with the fade envelope.
    @ObservationIgnored private var volumePercent: Int = 100
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var metadataOutput: AVPlayerItemMetadataOutput?
    @ObservationIgnored private var metadataReceiver: ICYMetadataReceiver?
    /// Called (on the main actor) when a station's stream fails to play — so the store can toast
    /// the user and the UI stops showing a dead station as "on air".
    @ObservationIgnored public var onError: (@MainActor (String) -> Void)?

    public init() {
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            // KVO can fire off-main; read the Sendable value, then hop to the main actor.
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    /// Start playing `station` from its raw stream `url`, replacing any current one.
    public func play(station: NavidromeRadioStation, url: URL) {
        // Settle any fade still running from the station we're replacing. Its completion
        // tears the item down (`replaceCurrentItem(with: nil)`), and arriving late that
        // would silence the station we're about to start — stop A, tap B inside the ramp,
        // and B dies with no error and nothing on screen to explain it.
        transportFade.cancel(apply: { [weak self] in self?.applyVolume() })
        currentStation = station
        nowPlayingTitle = nil

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        let receiver = ICYMetadataReceiver { [weak self] title in
            MainActor.assumeIsolated { self?.nowPlayingTitle = title.map(RadioPlaybackEngine.cleanStreamTitle) }
        }
        output.setDelegate(receiver, queue: .main)
        item.add(output)
        metadataOutput = output
        metadataReceiver = receiver

        // Surface a failed stream (wrong URL, 404, geo-block, TLS) instead of sitting silently
        // "on air" forever: on .failed, report it and stop.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                guard let self, status == .failed else { return }
                let msg = message ?? "The station is unavailable."
                radioStoreLog.error("radio item failed: \(msg, privacy: .public)")
                self.onError?(msg)
                self.stop()
            }
        }

        player.replaceCurrentItem(with: item)
        player.play()
        radioStoreLog.info("radio playing station \(station.id, privacy: .public)")
    }

    /// Pause the live stream (keeps the station on air so the bar's play button resumes it).
    ///
    /// Ramped like library playback. A stream cut mid-waveform clicks exactly the same way
    /// a file does, and the remote/CarPlay pause button lands here whenever radio is on air.
    public func pause() {
        transportFade.out(apply: { [weak self] in self?.applyVolume() },
                          then: { [weak self] in self?.player.pause() })
    }

    /// Resume after a pause — reconnects to the live edge.
    public func resume() {
        player.play()
        transportFade.in(apply: { [weak self] in self?.applyVolume() })
    }

    /// Set output volume (0–100) and mute — mirrored from the shared player volume so the
    /// one bottom-bar volume slider controls radio too.
    public func setVolume(percent: Int) {
        volumePercent = max(0, min(percent, 100))
        applyVolume()
    }

    /// The user's level times the transport ramp, so adjusting the volume mid-fade composes
    /// with it instead of erasing it.
    private func applyVolume() {
        player.volume = Float(volumePercent) / 100 * transportFade.multiplier
    }

    public func setMuted(_ muted: Bool) { player.isMuted = muted }

    /// Stop playback and clear the on-air station.
    ///
    /// The station clears from the UI immediately; only the audio is ramped, so the button
    /// still feels instant. Tearing the item down inside the fade's completion matters —
    /// `replaceCurrentItem(with: nil)` on an audible player is its own hard cut.
    public func stop() {
        transportFade.out(apply: { [weak self] in self?.applyVolume() }) { [weak self] in
            guard let self else { return }
            self.player.pause()
            self.player.replaceCurrentItem(with: nil)
        }
        statusObservation = nil
        currentStation = nil
        isPlaying = false
        nowPlayingTitle = nil
        metadataOutput = nil
        metadataReceiver = nil
    }

    /// Tidy an ICY `StreamTitle` for display. Standard streams send "Artist - Title" (used
    /// as-is); some (e.g. Radio 105) broadcast a "~"-delimited metadata blob — keep the first
    /// couple of text fields (song/artist) and drop timestamps, bare numbers, and ids.
    public static func cleanStreamTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("~") else { return trimmed }
        func isNoise(_ field: String) -> Bool {
            if field.isEmpty { return true }
            if field.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil { return true }
            if field.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil { return true }
            if field.range(of: #"^[0-9a-fA-F-]{16,}$"#, options: .regularExpression) != nil { return true }
            return false
        }
        let fields = trimmed
            .split(separator: "~", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isNoise($0) }
        var picked = Array(fields.prefix(2))
        // Some stations repeat the same value (e.g. the station name) across fields.
        if picked.count == 2, picked[0].caseInsensitiveCompare(picked[1]) == .orderedSame {
            picked = [picked[0]]
        }
        return picked.isEmpty ? trimmed : picked.joined(separator: " — ")
    }
}

/// Bridges AVFoundation's timed-metadata callback (delivered on the main queue) to a closure
/// that updates the engine's `nowPlayingTitle`. Reads the ICY `StreamTitle` string.
private final class ICYMetadataReceiver: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let onTitle: @Sendable (String?) -> Void
    init(onTitle: @escaping @Sendable (String?) -> Void) { self.onTitle = onTitle }

    public func metadataOutput(
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
