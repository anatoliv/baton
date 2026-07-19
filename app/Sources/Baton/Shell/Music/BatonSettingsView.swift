import AppKit
import SwiftUI

/// Baton's unified Settings window. A chromeless sidebar + detail layout matching
/// Tonebox's Settings design: a top spacer row reserves space for the traffic
/// lights, a `List(selection:)` sidebar of categories, and a `Form`-based detail
/// pane per category. Consolidates the previously-scattered Servers, Equalizer,
/// and playback preferences (which had no home before) into one place.
///
/// Opened via `openWindow(id:)` on ⌘,; ⌥⌘E deep-links to the Equalizer pane by
/// writing `selectionKey` before opening (see `BatonAppCommands`).
struct BatonSettingsView: View {
    /// Scene identifier used by `BatonApp`'s `Window(...)` scene and by
    /// `openWindow(id:)` callsites. Single source of truth.
    static let windowID = "baton-settings-main"

    /// The `@AppStorage` key the selected pane persists to. Exposed so deep-link
    /// callsites (⌥⌘E → Equalizer) can pre-select a pane before opening.
    static let selectionKey = "baton.settings.selectedCategory"

    @AppStorage(Self.selectionKey) private var selection: BatonSettingsCategory = .servers

    private let sidebarWidth: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            // Spacer row reserves 44pt for the AppKit traffic lights to render
            // into (the window accessor nudges them here for the hidden-title look).
            Color.clear.frame(height: 44)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarWidth)
                Divider()
                detailPane
            }
        }
        // maxWidth/maxHeight .infinity so the content grows when the user drags a
        // window edge — without these the frame collapses to intrinsic size and
        // resizes are silently rejected.
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .background(BatonSettingsWindowAccessor())
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(BatonSettingsCategory.allCases) { category in
                Label(category.label, systemImage: category.symbol)
                    .tag(category)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var detailPane: some View {
        content
            .frame(minWidth: 400, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .servers:
            BatonServersPane()
        case .playback:
            BatonPlaybackPane()
        case .equalizer:
            BatonEqualizerPane()
        case .actions:
            BatonActionsPane()
        case .speech:
            BatonSpeechPane()
        case .about:
            BatonAboutPane()
        }
    }
}

/// The Settings categories, in sidebar order.
enum BatonSettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case servers
    case playback
    case equalizer
    case actions
    case speech
    case about

    var id: Self { self }

    var label: String {
        switch self {
        case .servers: "Servers"
        case .playback: "Playback"
        case .equalizer: "Equalizer"
        case .actions: "Actions"
        case .speech: "Speech"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .servers: "server.rack"
        case .playback: "play.circle"
        case .equalizer: "slider.horizontal.3"
        case .actions: "bolt.horizontal.circle"
        case .speech: "waveform"
        case .about: "info.circle"
        }
    }
}

// MARK: - Servers pane

/// The multi-server manager, rebuilt as a grouped `Form` so it matches the rest of
/// Settings (the old `BatonServerListView` was a self-framed sheet with its own
/// padding and a "Done" button — out of place here). Drives the same
/// `NavidromeConfig` multi-server API and reuses `BatonServerEditSheet` for the
/// add/edit + verify + refresh flow.
private struct BatonServersPane: View {
    @Environment(MusicModel.self) private var model

    @State private var servers: [NavidromeServerEntry] = NavidromeConfig.servers()
    @State private var activeID: UUID? = NavidromeConfig.activeServerID()
    @State private var editing: EditTarget?
    @State private var pendingDelete: NavidromeServerEntry?

    /// Which server the edit sheet is editing — `.new` to add, `.existing` to edit.
    private enum EditTarget: Identifiable {
        case new
        case existing(NavidromeServerEntry)
        var id: String {
            switch self {
            case .new: return "new"
            case let .existing(entry): return entry.id.uuidString
            }
        }
    }

    var body: some View {
        Form {
            Section("Servers") {
                if servers.isEmpty {
                    Text("No servers yet. Add one to start listening.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(servers) { server in
                        row(for: server)
                    }
                }
                Text("Baton streams from Navidrome or any Subsonic-compatible server. The active server (checkmark) is the one you're browsing and playing.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    editing = .new
                } label: {
                    Label("Add Server…", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                BatonServerEditSheet(existing: nil) { reload() }
            case let .existing(entry):
                BatonServerEditSheet(existing: entry) { reload() }
            }
        }
        .confirmationDialog(
            "Remove this server?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { server in
            Button("Remove \(server.displayName)", role: .destructive) {
                remove(server)
            }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Baton will forget \(server.displayName) and its saved password.")
        }
    }

    @ViewBuilder
    private func row(for server: NavidromeServerEntry) -> some View {
        let isActive = server.id == activeID
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .accessibilityLabel(isActive ? "Active" : "Inactive")
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName).font(.body.weight(isActive ? .semibold : .regular))
                Text(subtitle(for: server)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if !isActive {
                    Button("Make Active") { switchTo(server) }
                }
                Button("Edit…") { editing = .existing(server) }
                Divider()
                Button("Remove…", role: .destructive) { pendingDelete = server }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden) // show just the ⋯ — the borderless style adds a redundant chevron otherwise
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive { switchTo(server) }
        }
    }

    private func subtitle(for server: NavidromeServerEntry) -> String {
        let host = URL(string: server.urlString)?.host ?? server.urlString
        if server.authMode == .apiKey { return host }
        return server.username.isEmpty ? host : "\(server.username) · \(host)"
    }

    // MARK: Actions

    private func reload() {
        servers = NavidromeConfig.servers()
        activeID = NavidromeConfig.activeServerID()
    }

    private func switchTo(_ server: NavidromeServerEntry) {
        NavidromeConfig.setActiveServer(id: server.id)
        activeID = NavidromeConfig.activeServerID()
        model.musicLibrary.refreshConnection()
        Task { await model.musicLibrary.loadAlbums() }
    }

    private func remove(_ server: NavidromeServerEntry) {
        let wasActive = server.id == activeID
        NavidromeConfig.removeServer(id: server.id)
        reload()
        pendingDelete = nil
        // If the active server changed (or is now gone), re-point the library.
        if wasActive {
            model.musicLibrary.refreshConnection()
            Task { await model.musicLibrary.loadAlbums() }
        }
    }
}

// MARK: - About pane

/// A grouped-`Form` About pane matching the rest of Settings. The standalone About
/// *window* (⌘-menu → About Baton) still uses `BatonAboutView`; this is the
/// consistent in-Settings presentation of the same facts.
private struct BatonAboutPane: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "music.note")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.tint)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Baton").font(.title3.bold())
                        Text("by Tonebox").font(.callout).foregroundStyle(.secondary)
                        Text("Conduct your music.").font(.callout).italic().foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Version") {
                    Text(version).textSelection(.enabled).foregroundStyle(.secondary)
                }
                LabeledContent("License") {
                    Text("MIT").textSelection(.enabled).foregroundStyle(.secondary)
                }
                Text("Baton is a native macOS player for your self-hosted Navidrome / Subsonic library — gapless playback, a parametric equalizer, and scrobbling, controllable by voice.")
                    .font(.callout).foregroundStyle(.secondary)
                Link("baton.tonebox.io", destination: URL(string: "https://baton.tonebox.io")!)
                    .font(.callout)
                Text("© 2026 Anatoli Vishnyakov · free to use, modify, and share, under the MIT License.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Playback pane

/// Consolidates Baton's playback preferences — which previously had no settings home
/// at all (only `autoplayEnabled` had a toggle, buried in the now-playing bar). Every
/// control here drives an existing, persisted `@Observable` property on
/// `StreamingPlaybackController` (`model.music`) or a real store; nothing is invented.
///
/// Mirrors Tonebox's `MusicSettingsView` "Sound" / "Browse" / "Scrobbling" sections,
/// minus Tonebox-only surfaces (voice/dictation control, which Baton has no dictation
/// for).
private struct BatonPlaybackPane: View {
    @Environment(MusicModel.self) private var model

    /// Filter-history size is UserDefaults-backed via `FilterHistory.sizeKey`.
    @AppStorage(FilterHistory.sizeKey) private var filterHistorySize = FilterHistory.defaultSize
    /// Offline mode toggle — same key `MusicDownloadsView` reads.
    @AppStorage("baton.music.offlineMode") private var offlineMode = false
    @AppStorage(MusicModel.autoRemoveFinishedKey) private var autoRemoveFinishedPodcasts = true
    /// Whether the niche "Advanced" area (filter history) is expanded. Persisted so
    /// power users who open it keep it open; collapsed by default for everyone else.
    @AppStorage("baton.settings.playbackAdvancedExpanded") private var advancedExpanded = false

    /// Fixed width for the trailing value labels on the Sound sliders, so Pre-amp and
    /// Crossfade line up identically down the right edge.
    private let sliderValueWidth: CGFloat = 52

    @State private var filenameTemplate = MusicDownloadStore.shared.filenameTemplate
    /// Gapless prefetch cache size on disk, refreshed when the pane appears.
    @State private var gaplessCacheBytes: Int64 = 0
    @State private var showResetConfirm = false

    private var player: StreamingPlaybackController { model.music }

    var body: some View {
        Form {
            soundSection
            downloadsSection
            scrobblingSection
            advancedSection
            resetSection
        }
        .formStyle(.grouped)
        .onAppear { gaplessCacheBytes = player.gaplessCacheSizeBytes }
        .confirmationDialog("Reset Playback settings to defaults?", isPresented: $showResetConfirm) {
            Button("Reset to Defaults", role: .destructive) { resetPlayback() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores Sound and Browse preferences to their defaults. Your scrobbling accounts and download folder are kept.")
        }
    }

    /// Resets only genuine preferences to their defaults — NOT credentials (scrobbler /
    /// Last.fm), the download folder, or the filename template.
    private var resetSection: some View {
        Section {
            Button(role: .destructive) { showResetConfirm = true } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func resetPlayback() {
        player.loudnessMode = .off
        player.loudnessPreampDB = 0
        player.crossfadeSeconds = 0
        player.gaplessEnabled = false
        player.gaplessPrefetchWifiOnly = false
        player.autoplayEnabled = false
        offlineMode = false
        filterHistorySize = FilterHistory.defaultSize
        advancedExpanded = false
    }

    // MARK: Sound

    private var soundSection: some View {
        Section("Sound") {
            Picker("Loudness normalization", selection: Binding(
                get: { player.loudnessMode },
                set: { player.loudnessMode = $0 }
            )) {
                ForEach(StreamingPlaybackController.LoudnessMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Text("Evens out track-to-track volume using your server's ReplayGain / R128 data — no re-encoding, no lag. **Track** levels every song the same; **Album** keeps an album's own quiet-to-loud dynamics. Needs ReplayGain tags in your library; tracks without data play at normal volume.")
                .font(.callout).foregroundStyle(.secondary)
            if player.loudnessMode != .off {
                LabeledContent("Pre-amp") {
                    HStack {
                        Slider(value: Binding(
                            get: { player.loudnessPreampDB },
                            set: { player.loudnessPreampDB = $0 }
                        ), in: -12 ... 12, step: 1)
                        Text("\(player.loudnessPreampDB >= 0 ? "+" : "")\(Int(player.loudnessPreampDB)) dB")
                            .foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: sliderValueWidth, alignment: .trailing)
                    }
                }
            }

            LabeledContent("Crossfade") {
                HStack {
                    Slider(value: Binding(
                        get: { player.crossfadeSeconds },
                        set: { player.crossfadeSeconds = ($0 < 0.5 ? 0 : $0) }
                    ), in: 0 ... 12, step: 1)
                    Text(player.crossfadeSeconds < 0.5 ? "Off" : "\(Int(player.crossfadeSeconds))s")
                        .foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: sliderValueWidth, alignment: .trailing)
                }
            }
            Text("Overlaps the end of one track with the start of the next for a smooth transition. Off is a clean cut.")
                .font(.callout).foregroundStyle(.secondary)

            // Gapless and crossfade are mutually exclusive — only offer gapless
            // when crossfade is off (matches the controller's own guard).
            if player.crossfadeSeconds < 0.5 {
                Toggle("Gapless playback", isOn: Binding(
                    get: { player.gaplessEnabled },
                    set: { player.gaplessEnabled = $0 }
                ))
                Text("For albums recorded without gaps (live, DJ sets, classical) — preloads the next track so it starts with no gap. Downloaded tracks are seamless; streamed tracks are prefetched to a small cache so their handoff is gap-free too.")
                    .font(.callout).foregroundStyle(.secondary)
                if player.gaplessEnabled {
                    Toggle("Prefetch streamed tracks on Wi-Fi only", isOn: Binding(
                        get: { player.gaplessPrefetchWifiOnly },
                        set: { player.gaplessPrefetchWifiOnly = $0 }
                    ))
                    Text("Skip the next-track prefetch on metered connections (personal hotspot, Low Data Mode). Playback still works — the streamed handoff just isn't pre-cached.")
                        .font(.callout).foregroundStyle(.secondary)
                    if gaplessCacheBytes > 0 {
                        Button("Clear prefetch cache (\(ByteCountFormatter.string(fromByteCount: gaplessCacheBytes, countStyle: .file)))", role: .destructive) {
                            player.clearGaplessCache()
                            gaplessCacheBytes = player.gaplessCacheSizeBytes
                        }
                    }
                }
            }

            Toggle("Autoplay similar tracks when the queue ends", isOn: Binding(
                get: { player.autoplayEnabled },
                set: { player.autoplayEnabled = $0 }
            ))
            Text("When the queue is about to run dry, keep going by appending tracks similar to what's playing (continuous radio).")
                .font(.callout).foregroundStyle(.secondary)
            if !model.musicRadioBans.ids.isEmpty {
                Button("Clear radio bans (\(model.musicRadioBans.ids.count))", role: .destructive) {
                    model.musicRadioBans.clear()
                }
            }
        }
    }

    // MARK: Downloads

    private var downloadsSection: some View {
        let store = MusicDownloadStore.shared
        return Section("Downloads") {
            Toggle("Offline mode", isOn: $offlineMode)
            Text("Play only tracks already downloaded to this Mac; never stream. Useful on the go or a metered connection.")
                .font(.callout).foregroundStyle(.secondary)

            Toggle("Remove finished podcast episodes", isOn: $autoRemoveFinishedPodcasts)
            Text("When you finish listening to a downloaded episode, delete its file automatically to save space.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Downloaded music folder").fontWeight(.medium)
                Text(store.directory.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Choose Folder…") { chooseDownloadFolder() }
                Button("Show in Finder") { NSWorkspace.shared.open(store.directory) }
                if store.isUsingCustomFolder {
                    Button("Use Default") { store.resetDownloadFolder() }
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Filename format").fontWeight(.medium)
                TextField("Filename format", text: $filenameTemplate, prompt: Text(MusicDownloadStore.defaultTemplate))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: filenameTemplate) { MusicDownloadStore.shared.filenameTemplate = filenameTemplate }
                HStack(spacing: 6) {
                    Text("Tokens:").foregroundStyle(.secondary)
                    ForEach(["{artist}", "{album}", "{title}", "{id}"], id: \.self) { token in
                        Button(token) { insertToken(token) }
                            .buttonStyle(.plain)
                            .font(.callout.monospaced())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Button {
                        filenameTemplate = MusicDownloadStore.defaultTemplate
                        MusicDownloadStore.shared.filenameTemplate = filenameTemplate
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }
                .font(.callout)
                Text("Example: “\(previewFilename)”")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Text("Downloads save here for offline playback. The player finds them by track ID regardless of name; changing the folder or format doesn't move or rename existing files.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Advanced

    /// Niche, power-user controls (browse filter history) folded away at the bottom
    /// of the pane. Collapsed by default; expansion is persisted so anyone who opens
    /// it keeps it open. Uses a `DisclosureGroup` inside its own `Section` so it reads
    /// as a distinct, subordinate area rather than a peer of Sound/Downloads/Scrobbling.
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                Picker("Filter history size", selection: $filterHistorySize) {
                    // Preset sizes (plus the current value, so a legacy value never shows blank).
                    ForEach(Array(Set([5, 10, 15, 20, 30, 50, filterHistorySize])).sorted(), id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
                .pickerStyle(.menu)
                Text("How many recent filter terms each browse screen's search box remembers. Each screen keeps its own history.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Clear filter history", role: .destructive) { FilterHistory.clearAll() }
            } label: {
                Text("Advanced")
            }
        }
    }

    // MARK: Scrobbling

    private var scrobblingSection: some View {
        Section("Scrobbling") {
            TextField("ListenBrainz user token", text: Binding(
                get: { model.musicScrobbler.token },
                set: { model.musicScrobbler.token = $0 }
            ), prompt: Text("Paste your token to enable"))
                .textFieldStyle(.roundedBorder)
            Text("Submits your listens to **ListenBrainz** (open, MusicBrainz-backed) once a track plays past halfway. Get a token from your [ListenBrainz profile](https://listenbrainz.org/profile/). This is on top of the play counts Baton already sends your Navidrome server. Leave blank to keep scrobbling local-only.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()
            lastfmControls

            Divider()
            scrobbleSourceControls
        }
    }

    /// Chooses who delivers Last.fm / ListenBrainz scrobbles, so plays aren't counted twice when
    /// the server already scrobbles them.
    @ViewBuilder private var scrobbleSourceControls: some View {
        Picker("Last.fm & ListenBrainz scrobbles", selection: Binding(
            get: { model.scrobbler.externalSource },
            set: { model.scrobbler.externalSource = $0 }
        )) {
            Text("Sent by Baton").tag(ScrobbleService.ExternalSource.baton)
            Text("Handled by my server").tag(ScrobbleService.ExternalSource.server)
        }
        .pickerStyle(.radioGroup)
        Text("If your Navidrome/Subsonic server is **already** linked to Last.fm/ListenBrainz, choose **Handled by my server** so the same play isn't scrobbled twice — Baton still tracks play counts and \"now playing\". Otherwise leave it on **Sent by Baton**. Server play counts are always tracked regardless.")
            .font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var lastfmControls: some View {
        let lastfm = model.musicLastFM
        if lastfm.isConnected {
            HStack {
                Label("Last.fm connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Disconnect", role: .destructive) { lastfm.disconnect() }
            }
        } else {
            TextField("Last.fm API key", text: Binding(get: { lastfm.apiKey }, set: { lastfm.apiKey = $0 }))
                .textFieldStyle(.roundedBorder)
            TextField("Last.fm shared secret", text: Binding(get: { lastfm.apiSecret }, set: { lastfm.apiSecret = $0 }))
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Authorize in browser…") { Task { await lastfm.beginAuth() } }
                    .disabled(!lastfm.hasCredentials)
                if lastfm.pendingToken != nil {
                    Button("I've authorized — finish") { Task { await lastfm.completeAuth() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text("Last.fm needs your own free API account ([create one](https://www.last.fm/api/account/create)) — paste the key + secret, click Authorize (a browser tab opens), approve it, then click Finish.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    /// A sample of what the current template produces, so the format is easy to read.
    private var previewFilename: String {
        MusicDownloadStore.renderFilename(
            template: filenameTemplate,
            artist: "Daft Punk", album: "Discovery", title: "One More Time",
            id: "3xY7Qk2a", taken: [:]
        )
    }

    private func insertToken(_ token: String) {
        filenameTemplate += token
        MusicDownloadStore.shared.filenameTemplate = filenameTemplate
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for downloaded music"
        panel.directoryURL = MusicDownloadStore.shared.directory
        if panel.runModal() == .OK, let url = panel.url {
            MusicDownloadStore.shared.setDownloadFolder(url)
        }
    }
}

// MARK: - Equalizer pane

/// The parametric-EQ controls, rebuilt as a grouped `Form` so they match the rest
/// of Settings (the old `MusicEqualizerView` carried a dark, glassy chrome meant
/// for the now-playing surface). Same functionality — enable, presets, a live
/// response curve, and per-band frequency / Q / gain — driven through
/// `model.musicEqualizer`. ⌥⌘E deep-links here.
private struct BatonEqualizerPane: View {
    @Environment(MusicModel.self) private var model

    /// The band currently expanded for editing (nil = none).
    @State private var selectedBand: Int?
    @State private var showResetConfirm = false

    private var eq: MusicEqualizer { model.musicEqualizer }

    var body: some View {
        Form {
            Section("Equalizer") {
                Toggle("Enable equalizer", isOn: Binding(
                    get: { eq.isEnabled }, set: { eq.isEnabled = $0 }
                ))
                Text("A parametric equalizer applied to everything Baton plays. Shape the sound per band, or start from a preset.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Preset") {
                Picker("Preset", selection: Binding(
                    get: { eq.preset },
                    set: { name in
                        // "Custom" isn't an applyable preset — it's the label shown
                        // once you hand-tune a band. Only apply real presets.
                        if name != "Custom" { eq.apply(preset: name); selectedBand = nil }
                    }
                )) {
                    if eq.preset == "Custom" {
                        Text("Custom").tag("Custom")
                    }
                    ForEach(MusicEqualizer.presets, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!eq.isEnabled)
                Button("Flat / Reset", role: .destructive) {
                    eq.reset()
                    selectedBand = nil
                }
                .disabled(!eq.isEnabled)
                Text("Presets set every band at once. **Flat / Reset** zeroes all gains back to a neutral response.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Response") {
                EQResponseCurve(bands: eq.bands, selected: selectedBand)
                    .frame(height: 120)
                    .padding(.vertical, 6)
                    .opacity(eq.isEnabled ? 1 : 0.4)
            }

            Section("Bands") {
                ForEach(Array(eq.bands.enumerated()), id: \.element.id) { index, band in
                    EQBandRow(
                        band: band,
                        expanded: selectedBand == index,
                        onTap: { withAnimation(.easeInOut(duration: 0.18)) { selectedBand = selectedBand == index ? nil : index } },
                        onFrequency: { eq.setFrequency($0, band: index) },
                        onQ: { eq.setQ($0, band: index) },
                        onGain: { eq.setGain($0, band: index) }
                    )
                }
                .disabled(!eq.isEnabled)
                Text("Tap a band to edit its centre frequency, Q (width), and gain. Adjusting a band switches the preset to **Custom**.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) { showResetConfirm = true } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the equalizer to defaults?", isPresented: $showResetConfirm) {
            Button("Reset to Defaults", role: .destructive) {
                eq.isEnabled = false
                eq.reset()
                selectedBand = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turns the equalizer off and flattens every band.")
        }
    }
}

// MARK: - Equalizer subviews

/// A single band's row: a compact summary line, expanding to frequency / Q / gain
/// sliders. Styled for the light grouped Form (no dark chrome).
private struct EQBandRow: View {
    let band: EQBand
    let expanded: Bool
    let onTap: () -> Void
    let onFrequency: (Double) -> Void
    let onQ: (Double) -> Void
    let onGain: (Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack {
                    Text(frequencyLabel(band.frequency))
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .frame(width: 62, alignment: .leading)
                    gainBar
                    Text(gainLabel(band.gainDB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 10) {
                    EQParameterSlider(label: "Freq", value: band.frequency, range: log10(MusicEqualizer.minFrequency) ... log10(MusicEqualizer.maxFrequency), display: frequencyLabel(band.frequency), transform: { pow(10, $0) }, inverse: { log10($0) }, onChange: onFrequency)
                    EQParameterSlider(label: "Q", value: band.q, range: MusicEqualizer.minQ ... MusicEqualizer.maxQ, display: String(format: "%.2f", band.q), onChange: onQ)
                    EQParameterSlider(label: "Gain", value: band.gainDB, range: MusicEqualizer.minGain ... MusicEqualizer.maxGain, display: gainLabel(band.gainDB), onChange: onGain)
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
        }
    }

    private var gainBar: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            let frac = band.gainDB / MusicEqualizer.maxGain // −1…1
            let w = abs(frac) * mid
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3)
                // Single brand accent — the bar's direction from the midpoint (left = cut,
                // right = boost) encodes the sign, so no second literal color is needed.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, w), height: 3)
                    .offset(x: frac >= 0 ? mid : mid - w)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
    }

    private func frequencyLabel(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1fk", hz / 1000).replacingOccurrences(of: ".0k", with: "k") : "\(Int(hz.rounded()))Hz"
    }

    private func gainLabel(_ dB: Double) -> String {
        String(format: "%+.1f dB", dB)
    }
}

/// A labelled slider for one band parameter. Supports an optional log transform
/// (used for frequency) so the knob position maps evenly across decades.
private struct EQParameterSlider: View {
    let label: String
    let value: Double
    /// The slider's operating range (in transformed space when a transform is supplied).
    let range: ClosedRange<Double>
    let display: String
    /// Maps slider position → real value (identity by default).
    var transform: (Double) -> Double = { $0 }
    /// Maps real value → slider position (identity by default).
    var inverse: (Double) -> Double = { $0 }
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Slider(
                value: Binding(
                    get: { min(max(inverse(value), range.lowerBound), range.upperBound) },
                    set: { onChange(transform($0)) }
                ),
                in: range
            )
            .controlSize(.small)
            Text(display)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }
}

/// Draws the combined magnitude response of all bands as a smooth curve over a
/// log-frequency axis, plus a handle dot per band centre (highlighted when its row
/// is selected). Tuned for the light grouped background.
private struct EQResponseCurve: View {
    let bands: [EQBand]
    let selected: Int?

    private let sampleRate = 44_100.0
    private let minF = 20.0
    private let maxF = 20_000.0
    private let maxDB = 12.0

    var body: some View {
        Canvas { ctx, size in
            drawGrid(&ctx, size: size)
            drawCurve(&ctx, size: size)
            drawHandles(&ctx, size: size)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// Combined response in dB at a given frequency (sum of per-band peaking magnitudes).
    private func responseDB(at f: Double) -> Double {
        var linear = 1.0
        for band in bands {
            let biquad = Biquad.peaking(frequency: band.frequency, sampleRate: sampleRate, q: band.q, gainDB: band.gainDB)
            linear *= biquad.magnitude(atFrequency: f, sampleRate: sampleRate)
        }
        return 20 * log10(max(linear, 1e-6))
    }

    private func x(for f: Double, width: CGFloat) -> CGFloat {
        let t = (log10(f) - log10(minF)) / (log10(maxF) - log10(minF))
        return CGFloat(t) * width
    }

    private func y(forDB db: Double, height: CGFloat) -> CGFloat {
        let t = (db + maxDB) / (2 * maxDB) // 0 (top, +12) … 1 (bottom, −12)
        return height * (1 - CGFloat(min(max(t, 0), 1)))
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        var mid = Path()
        mid.move(to: CGPoint(x: 0, y: y(forDB: 0, height: size.height)))
        mid.addLine(to: CGPoint(x: size.width, y: y(forDB: 0, height: size.height)))
        ctx.stroke(mid, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
    }

    private func drawCurve(_ ctx: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let steps = 160
        for i in 0 ... steps {
            let t = Double(i) / Double(steps)
            let f = pow(10, log10(minF) + t * (log10(maxF) - log10(minF)))
            let px = CGFloat(t) * size.width
            let py = y(forDB: responseDB(at: f), height: size.height)
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) } else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)

        // Soft fill under the curve toward the 0 dB line.
        var fill = path
        fill.addLine(to: CGPoint(x: size.width, y: y(forDB: 0, height: size.height)))
        fill.addLine(to: CGPoint(x: 0, y: y(forDB: 0, height: size.height)))
        fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [.accentColor.opacity(0.28), .accentColor.opacity(0.02)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
        ))
    }

    private func drawHandles(_ ctx: inout GraphicsContext, size: CGSize) {
        for (i, band) in bands.enumerated() {
            let px = x(for: band.frequency, width: size.width)
            let py = y(forDB: band.gainDB, height: size.height)
            let isSel = selected == i
            let r: CGFloat = isSel ? 6 : 4
            let rect = CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(.accentColor))
            if isSel {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(.accentColor.opacity(0.5)), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Window accessor

/// Slimmed port of Tonebox's `SettingsWindowAccessor`: merges the Settings
/// window's title bar into the content area so the sidebar's spacer row can host
/// the traffic lights inline, and makes the window resizable with a sensible min
/// size. No Sparkle/floating-level or Guide-overlay specifics — Baton doesn't
/// need them.
private struct BatonSettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { configure(window) }
        }
    }

    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 640, height: 500)
    }
}
