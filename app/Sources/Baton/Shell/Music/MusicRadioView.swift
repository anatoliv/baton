import SwiftUI

/// The **Radio** screen — internet-radio stations kept on the Navidrome server, shown as a
/// card grid with a live "Now Playing" hero. Stations, the raw-stream player, and the lazily
/// resolved extras (logo, genre/bitrate, the current ICY track) all live on
/// `model.internetRadio` (`InternetRadioStore`) so the sidebar badge and the global player
/// bar read the same state. A station is a raw stream URL, not a Subsonic song, so it plays
/// through the store's `RadioPlaybackEngine` and ducks the library transport while on air.
struct MusicRadioView: View {
    @Environment(MusicModel.self) private var model

    @State private var showEditor = false
    @State private var editing: NavidromeRadioStation?
    @State private var pendingDelete: NavidromeRadioStation?
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    /// List ⇄ grid + sort, persisted like the other browse screens (Playlists/Artists/…).
    @AppStorage("tonebox.music.radioLayout") private var layout: MusicBrowseLayout = .grid
    @AppStorage("tonebox.music.radioSort") private var sortField: RadioSort = .name
    @AppStorage("tonebox.music.radioSortAscending") private var sortAscending = true

    private var store: InternetRadioStore { model.internetRadio }

    /// The sort fields available on the Radio screen (mirrors the other browse screens).
    enum RadioSort: String, CaseIterable, Identifiable, MusicSortField {
        case name, website
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: "Name"
            case .website: "Website"
            }
        }
    }

    /// Stations after the header's filter + sort controls are applied.
    private var filteredStations: [NavidromeRadioStation] {
        var list = store.stations
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { list = list.filter { $0.name.lowercased().contains(query) } }
        switch sortField {
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .website:
            // Stations with no homepage sort last (empty host → end of an ascending list).
            list.sort {
                let a = $0.homepageHost ?? "\u{10FFFF}"
                let b = $1.homepageHost ?? "\u{10FFFF}"
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        if !sortAscending { list.reverse() }
        return list
    }

    var body: some View {
        Group {
            if store.loading, store.stations.isEmpty {
                centered { ProgressView() }
            } else if let loadError = store.loadError, store.stations.isEmpty {
                centered {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                        Text(loadError).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { Task { await store.reload() } }
                    }
                }
            } else if store.stations.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    // Shared browse header (title · count badge · filter, then the layout
                    // toggle on the second row) so Radio lines up with Albums/Artists/etc.
                    MusicBrowseHeader(
                        title: "Radio",
                        count: filteredStations.count,
                        filter: $filterText,
                        filterPrompt: "Filter stations",
                        filterFocused: $filterFocused,
                        filterHistoryKey: "radio",
                        layout: $layout,
                        accessory: { EmptyView() },
                        leading: {
                            Button { editing = nil; showEditor = true } label: {
                                Label("Add Station", systemImage: "plus")
                            }
                            .buttonStyle(.borderless)
                        },
                        sortMenu: { MusicSortControls(ascending: $sortAscending, selection: $sortField) }
                    )
                    stationsScroll
                }
            }
        }
        .task { await store.loadIfNeeded() }
        // Keep the store's prev/next order in step with what's on screen (filter + sort),
        // so the bottom bar's station arrows match the visible list.
        .onChange(of: filteredStations.map(\.id), initial: true) { _, _ in
            store.orderedStations = filteredStations
        }
        .sheet(isPresented: $showEditor) {
            RadioStationEditor(station: editing) { name, streamURL, homepage in
                if let editing {
                    await store.update(editing, name: name, streamURL: streamURL, homepage: homepage)
                } else {
                    await store.add(name: name, streamURL: streamURL, homepage: homepage)
                }
            }
        }
        .confirmationDialog(
            "Delete this station?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let station = pendingDelete { Task { await store.delete(station); pendingDelete = nil } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "“\($0.name)” will be removed from the server." } ?? "")
        }
    }

    // MARK: - Content

    /// Grid of cards or a table of rows — the now-playing station is reflected in the shared
    /// bottom player bar (and highlighted here), so there's no separate top "hero" section.
    private var stationsScroll: some View {
        ScrollView {
            if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 16) {
                    ForEach(filteredStations) { station in
                        RadioStationCard(
                            station: station,
                            onPlay: { store.toggle(station) },
                            onEdit: { editing = station; showEditor = true },
                            onDelete: { pendingDelete = station }
                        )
                    }
                }
                .padding(16)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(filteredStations) { station in
                        RadioStationListRow(
                            station: station,
                            onPlay: { store.toggle(station) },
                            onEdit: { editing = station; showEditor = true },
                            onDelete: { pendingDelete = station }
                        )
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
            }
        }
    }

    private var emptyState: some View {
        centered {
            VStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
                Text("No radio stations").font(.headline)
                Text("Add an internet-radio stream URL to listen here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { editing = nil; showEditor = true } label: {
                    Label("Add Station", systemImage: "plus")
                }
                .buttonStyle(.borderless).padding(.top, 4)
            }
        }
    }

    private func centered(@ViewBuilder _ body: () -> some View) -> some View {
        VStack { Spacer(); body(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension NavidromeRadioStation {
    /// The station website as an openable URL, if a homepage was set.
    var homepageURL: URL? { homepageUrl.flatMap(URL.init(string:)) }
    /// A clean host for the website column/link (e.g. "https://www.1.fm/" → "1.fm").
    var homepageHost: String? {
        guard let host = homepageURL?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Station card

private struct RadioStationCard: View {
    @Environment(MusicModel.self) private var model
    let station: NavidromeRadioStation
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private var store: InternetRadioStore { model.internetRadio }
    private var isOnAir: Bool { store.isOnAir(station) }
    private var isPlaying: Bool { store.isPlaying(station) }

    /// Live track while on air; otherwise genre·bitrate, falling back to the stream host.
    private var subtitle: String {
        if isOnAir, let track = store.engine.nowPlayingTitle { return track }
        if isOnAir { return "On air" }
        if let meta = store.meta[station.id]?.subtitle { return meta }
        return station.streamURL?.host ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RadioArtworkView(station: station, cornerRadius: 12)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: isOnAir ? 3 : 0)
                    }
                    .shadow(
                        color: isOnAir ? Color.accentColor.opacity(0.45) : .black.opacity(hover ? 0.4 : 0.2),
                        radius: isOnAir ? 14 : (hover ? 14 : 7), y: hover ? 6 : 3
                    )
                // Hover / on-air play-stop overlay.
                if hover || isOnAir {
                    ZStack {
                        Color.black.opacity(hover ? 0.34 : 0.16)
                        Button(action: onPlay) {
                            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                .font(.title3).foregroundStyle(.black)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(.white).shadow(radius: 6, y: 3))
                        }
                        .buttonStyle(.plain)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                // Live equalizer badge, top-trailing, while playing.
                if isPlaying {
                    VStack {
                        HStack {
                            Spacer()
                            EqualizerBars(active: true, color: .white)
                                .padding(6)
                                .background(.black.opacity(0.35), in: Capsule())
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .animation(.easeOut(duration: 0.16), value: hover)
            .animation(.easeInOut(duration: 0.2), value: isOnAir)

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOnAir ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button(isPlaying ? "Stop" : "Play", action: onPlay)
            PinMenuButton(item: .station(station), model: model)
            Button("Edit…", action: onEdit)
            if let home = station.homepageUrl, let url = URL(string: home) {
                Link("Open Homepage", destination: url)
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .task(id: station.id) {
            store.resolveArtwork(for: station)
            store.resolveMeta(for: station)
        }
    }
}

// MARK: - Station list row

/// A compact row for the list layout: logo/monogram thumbnail, name, genre·bitrate (or the
/// live track while on air), a play/stop control, and the same context menu as the cards.
private struct RadioStationListRow: View {
    @Environment(MusicModel.self) private var model
    let station: NavidromeRadioStation
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private var store: InternetRadioStore { model.internetRadio }
    private var isOnAir: Bool { store.isOnAir(station) }
    private var isPlaying: Bool { store.isPlaying(station) }

    /// Genre · bitrate, or the live track while on air (the stream host lives in the website
    /// column now).
    private var subtitle: String {
        if isOnAir, let track = store.engine.nowPlayingTitle { return track }
        if isOnAir { return "On air" }
        return store.meta[station.id]?.subtitle ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                RadioArtworkView(station: station, cornerRadius: 8)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if hover || isOnAir {
                            ZStack {
                                Color.black.opacity(0.34)
                                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                    .font(.caption).foregroundStyle(.white)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Stop \(station.name)" : "Play \(station.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isOnAir ? Color.accentColor : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if isOnAir {
                        Label("On air", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(station.name)\(isOnAir ? ", on air" : "")\(subtitle.isEmpty ? "" : ", \(subtitle)")")

            // Fixed-width slot for the on-air equalizer so the website column stays
            // vertically aligned across rows whether or not a station is playing.
            ZStack {
                if isPlaying { EqualizerBars(active: true, color: Color.accentColor) }
            }
            .frame(width: 24)

            // Website column — a clickable link to the station's homepage.
            websiteColumn.frame(width: 150, alignment: .leading)

            Menu {
                Button(isPlaying ? "Stop" : "Play", action: onPlay)
                PinMenuButton(item: .station(station), model: model)
                Button("Edit…", action: onEdit)
                if let home = station.homepageUrl, let url = URL(string: home) {
                    Link("Open Homepage", destination: url)
                }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
        .task(id: station.id) {
            store.resolveArtwork(for: station)
            store.resolveMeta(for: station)
        }
    }

    @ViewBuilder private var websiteColumn: some View {
        if let host = station.homepageHost, let url = station.homepageURL {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Image(systemName: "safari").font(.caption2)
                    Text(host).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Open \(host)")
        } else {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Reusable bits

/// A station's logo when one can be resolved from its homepage, otherwise a deterministic
/// gradient monogram (station initial + color-from-name), matching the album/artist placeholders.
struct RadioArtworkView: View {
    @Environment(MusicModel.self) private var model
    let station: NavidromeRadioStation
    var cornerRadius: CGFloat = 10

    var body: some View {
        let art = model.internetRadio.artwork[station.id] ?? .unresolved
        ZStack {
            monogram
            if case .logo(let url) = art {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear // keep the monogram visible while loading / on failure
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: station.id) { model.internetRadio.resolveArtwork(for: station) }
    }

    private var monogram: some View {
        let color = ArtistMonogram.color(station.name)
        return LinearGradient(
            colors: [color.opacity(0.95), color.opacity(0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Text(ArtistMonogram.initial(station.name))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .minimumScaleFactor(0.5)
        )
    }
}

/// A tiny animated equalizer — four bars that dance while `active`, flat otherwise.
struct EqualizerBars: View {
    var active: Bool
    var color: Color

    var body: some View {
        if active {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                bars { i in 0.3 + 0.7 * abs(sin(t * 3.0 + Double(i) * 0.7)) }
            }
        } else {
            bars { _ in 0.32 }
        }
    }

    private func bars(_ height: @escaping (Int) -> Double) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< 4, id: \.self) { i in
                Capsule().fill(color).frame(width: 3, height: 13 * height(i))
            }
        }
        .frame(width: 21, height: 13)
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
