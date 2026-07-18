import AVFoundation
import Observation
import OSLog
import SwiftUI

private let radioLog = Logger(subsystem: "io.tonebox.macos", category: "Radio")

/// The **Radio** screen — internet-radio stations kept on the Navidrome server.
///
/// A station is a raw stream URL (ICY/MP3/AAC shoutcast-style), NOT a Subsonic
/// song, so it can't go through `StreamingPlaybackController` (which only resolves
/// and plays library `stream.view` URLs by song id). This view therefore owns a
/// tiny `AVPlayer`-based `RadioPlaybackEngine` for the raw stream, and — so the two
/// transports never play over each other — suspends the main music player via its
/// existing audio-focus API while a station is on the air. Unifying the two players
/// behind one transport is a sensible follow-up.
struct MusicRadioView: View {
    @Environment(MusicModel.self) private var model

    /// Loaded station list + fetch/mutation state.
    @State private var stations: [NavidromeRadioStation] = []
    @State private var isLoading = false
    @State private var loadError: String?

    /// Local raw-stream player for the on-air station.
    @State private var engine = RadioPlaybackEngine()

    /// Add/edit sheet state. `editing == nil` means "add a new station".
    @State private var showEditor = false
    @State private var editing: NavidromeRadioStation?

    /// Delete confirmation target.
    @State private var pendingDelete: NavidromeRadioStation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            content
        }
        .task { await load() }
        .sheet(isPresented: $showEditor) {
            RadioStationEditor(station: editing) { name, streamURL, homepage in
                await save(name: name, streamURL: streamURL, homepage: homepage)
            }
        }
        .confirmationDialog(
            "Delete this station?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let station = pendingDelete { Task { await delete(station) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "“\($0.name)” will be removed from the server." } ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Radio")
                .font(.title2.weight(.bold))
            Spacer()
            Button {
                editing = nil
                showEditor = true
            } label: {
                Label("Add Station", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading, stations.isEmpty {
            centered { ProgressView() }
        } else if let loadError, stations.isEmpty {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(loadError).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
            }
        } else if stations.isEmpty {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No radio stations").font(.headline)
                    Text("Add an internet-radio stream URL to listen here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            List {
                ForEach(stations) { station in
                    RadioStationRow(
                        station: station,
                        isOnAir: engine.currentStation?.id == station.id,
                        isPlaying: engine.currentStation?.id == station.id && engine.isPlaying,
                        onPlay: { toggle(station) },
                        onEdit: { editing = station; showEditor = true },
                        onDelete: { pendingDelete = station }
                    )
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func centered(@ViewBuilder _ body: () -> some View) -> some View {
        VStack { Spacer(); body(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Fetches the station list from the server.
    private func load() async {
        guard model.musicLibrary.isConfigured else {
            loadError = "No music server is configured."
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let client = try NavidromeConfig.makeClient()
            stations = try await client.getInternetRadioStations()
        } catch {
            let message = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
            loadError = message
            radioLog.error("load stations failed: \(message, privacy: .public)")
        }
    }

    /// Play the station, or stop it if it's already on the air.
    private func toggle(_ station: NavidromeRadioStation) {
        if engine.currentStation?.id == station.id {
            engine.stop()
            return
        }
        guard let url = station.streamURL else {
            model.music.postToast("Station has no valid stream URL", symbol: "exclamationmark.triangle")
            return
        }
        // Duck the main library player so the two transports don't overlap.
        model.music.acquireAudioFocusSuspend(owner: Self.radioFocusOwner)
        engine.play(station: station, url: url)
    }

    /// Creates or updates a station, then refreshes the list.
    private func save(name: String, streamURL: String, homepage: String?) async {
        do {
            let client = try NavidromeConfig.makeClient()
            if let editing {
                try await client.updateInternetRadioStation(
                    id: editing.id, name: name, streamUrl: streamURL, homepageUrl: homepage
                )
            } else {
                try await client.createInternetRadioStation(
                    name: name, streamUrl: streamURL, homepageUrl: homepage
                )
            }
            await load()
        } catch {
            let message = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
            model.music.postToast(message, symbol: "exclamationmark.triangle")
            radioLog.error("save station failed: \(message, privacy: .public)")
        }
    }

    /// Deletes a station; stops it first if it's on the air.
    private func delete(_ station: NavidromeRadioStation) async {
        if engine.currentStation?.id == station.id { engine.stop() }
        do {
            let client = try NavidromeConfig.makeClient()
            try await client.deleteInternetRadioStation(id: station.id)
            await load()
        } catch {
            let message = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
            model.music.postToast(message, symbol: "exclamationmark.triangle")
            radioLog.error("delete station failed: \(message, privacy: .public)")
        }
        pendingDelete = nil
    }

    /// Audio-focus owner tag used when radio ducks the library player.
    private static let radioFocusOwner = "radio"
}

// MARK: - Row

private struct RadioStationRow: View {
    let station: NavidromeRadioStation
    let isOnAir: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(isOnAir ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop" : "Play")

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if isOnAir {
                        Label("On air", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(station.streamUrl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)

            Menu {
                Button("Edit…", action: onEdit)
                if let home = station.homepageUrl, let url = URL(string: home) {
                    Link("Open Homepage", destination: url)
                }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Add / edit sheet

struct RadioStationEditor: View {
    /// The station being edited, or nil to add a new one.
    let station: NavidromeRadioStation?
    /// Called with validated fields on Save. Runs the create/update.
    let onSave: (_ name: String, _ streamURL: String, _ homepage: String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var streamURL = ""
    @State private var homepage = ""
    @State private var saving = false

    /// Save is allowed only with a non-empty name and a syntactically valid http(s)
    /// stream URL — the same rule the row uses to decide a station is playable.
    private var canSave: Bool {
        RadioStationEditor.isValid(name: name, streamURL: streamURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(station == nil ? "Add Station" : "Edit Station")
                .font(.headline)

            Form {
                TextField("Name", text: $name, prompt: Text("Jazz FM"))
                TextField("Stream URL", text: $streamURL, prompt: Text("https://stream.example.com/live.mp3"))
                    .textContentType(.URL)
                TextField("Homepage (optional)", text: $homepage, prompt: Text("https://example.com"))
                    .textContentType(.URL)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        let home = homepage.trimmingCharacters(in: .whitespaces)
                        await onSave(
                            name.trimmingCharacters(in: .whitespaces),
                            streamURL.trimmingCharacters(in: .whitespaces),
                            home.isEmpty ? nil : home
                        )
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || saving)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let station {
                name = station.name
                streamURL = station.streamUrl
                homepage = station.homepageUrl ?? ""
            }
        }
    }

    /// Pure validation seam (unit-tested): a station needs a non-empty name and an
    /// absolute http(s) stream URL.
    static func isValid(name: String, streamURL: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return false }
        guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}

// MARK: - Raw-stream playback engine

/// A minimal `AVPlayer` wrapper that plays one raw internet-radio stream at a time.
///
/// Deliberately separate from `StreamingPlaybackController`: a station is a live
/// stream URL with no song id, duration, or queue, so none of that controller's
/// queue/seek/gapless machinery applies. It owns its own `AVPlayer` and never
/// shares transport state — the only cross-talk is the caller ducking the library
/// player via audio focus before it starts a station. A follow-up could fold raw
/// streams into the main controller behind a single transport.
@MainActor
@Observable
final class RadioPlaybackEngine {
    /// The station currently loaded (playing or buffering), if any.
    private(set) var currentStation: NavidromeRadioStation?
    /// True while audio is actually flowing (derived from the player's rate/status).
    private(set) var isPlaying = false

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?

    init() {
        // Track whether audio is flowing so the UI can show a stop (vs. play) glyph.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            MainActor.assumeIsolated {
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    /// Starts playing `station` from its raw stream `url`, replacing any current one.
    func play(station: NavidromeRadioStation, url: URL) {
        currentStation = station
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        player.replaceCurrentItem(with: item)
        player.play()
        radioLog.info("radio playing station \(station.id, privacy: .public)")
    }

    /// Stops playback and clears the on-air station.
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStation = nil
        isPlaying = false
    }
}
