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
            // The EQ view brings its own dark, glassy chrome — host it directly.
            MusicEqualizerView()
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
    case about

    var id: Self { self }

    var label: String {
        switch self {
        case .servers: "Servers"
        case .playback: "Playback"
        case .equalizer: "Equalizer"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .servers: "server.rack"
        case .playback: "play.circle"
        case .equalizer: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

// MARK: - Servers pane

/// Wraps the existing multi-server manager as a Settings pane. `BatonServerListView`
/// carries its own padding + framing, so it drops in directly. (Its "Done" button
/// still calls `dismiss()`, which is harmless inside the Settings window — closing
/// it just closes Settings.)
private struct BatonServersPane: View {
    var body: some View {
        BatonServerListView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - About pane

/// Reuses the custom About panel content as a Settings pane.
private struct BatonAboutPane: View {
    var body: some View {
        BatonAboutView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    @State private var filenameTemplate = MusicDownloadStore.shared.filenameTemplate
    /// Gapless prefetch cache size on disk, refreshed when the pane appears.
    @State private var gaplessCacheBytes: Int64 = 0

    private var player: StreamingPlaybackController { model.music }

    var body: some View {
        Form {
            soundSection
            downloadsSection
            browseSection
            scrobblingSection
        }
        .formStyle(.grouped)
        .onAppear { gaplessCacheBytes = player.gaplessCacheSizeBytes }
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
            Text("Evens out track-to-track volume using your server's ReplayGain / R128 data — no re-encoding, no lag. **Track** levels every song the same; **Album** keeps an album's own quiet-to-loud dynamics. Needs ReplayGain tags in your library; tracks without data play at normal volume.")
                .font(.callout).foregroundStyle(.secondary)
            if player.loudnessMode != .off {
                HStack {
                    Text("Pre-amp")
                    Slider(value: Binding(
                        get: { player.loudnessPreampDB },
                        set: { player.loudnessPreampDB = $0 }
                    ), in: -12 ... 12, step: 1)
                    Text("\(player.loudnessPreampDB >= 0 ? "+" : "")\(Int(player.loudnessPreampDB)) dB")
                        .foregroundStyle(.secondary).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }

            HStack {
                Text("Crossfade")
                Slider(value: Binding(
                    get: { player.crossfadeSeconds },
                    set: { player.crossfadeSeconds = ($0 < 0.5 ? 0 : $0) }
                ), in: 0 ... 12, step: 1)
                Text(player.crossfadeSeconds < 0.5 ? "Off" : "\(Int(player.crossfadeSeconds))s")
                    .foregroundStyle(.secondary).monospacedDigit().frame(width: 52, alignment: .trailing)
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Downloaded music folder").fontWeight(.medium)
                Text(store.directory.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

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
                    Button("Reset") {
                        filenameTemplate = MusicDownloadStore.defaultTemplate
                        MusicDownloadStore.shared.filenameTemplate = filenameTemplate
                    }
                    .controlSize(.small)
                }
                .font(.callout)
                Text("Example: “\(previewFilename)”")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.top, 2)

            Text("Downloads save here for offline playback. The player finds them by track ID regardless of name; changing the folder or format doesn't move or rename existing files.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Browse

    private var browseSection: some View {
        Section("Browse") {
            Stepper(value: $filterHistorySize, in: 1 ... 50) {
                HStack {
                    Text("Filter history size")
                    Spacer()
                    Text("\(filterHistorySize)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("How many recent filter terms each browse screen's search box remembers. Each screen keeps its own history.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Clear filter history", role: .destructive) { FilterHistory.clearAll() }
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
        }
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
