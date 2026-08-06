import SwiftUI

/// What you've actually listened to — the phone's counterpart to the Mac's History tab.
///
/// The data was already being recorded on every track start (`MusicPlayHistory`, shared);
/// there was simply no screen showing it, which meant the phone silently accumulated a
/// listening log its owner couldn't read.
struct HistoryView: View {
    let model: MobileModel

    enum Window: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .week: "This Week"
            case .month: "This Month"
            case .all: "All Time"
            }
        }

        var since: Date {
            switch self {
            case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            case .all: .distantPast
            }
        }
    }

    enum Segment: String, CaseIterable, Identifiable {
        case recent, tracks, artists
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: "Recent"
            case .tracks: "Top Tracks"
            case .artists: "Top Artists"
            }
        }
    }

    @State private var segment: Segment = .recent
    @State private var window: Window = .month
    @State private var showsClearConfirm = false
    /// Server-ranked top tracks — counts every device, not just this one.
    @State private var serverTop: [NavidromeSong] = []
    @State private var loadingServerTop = false

    var body: some View {
        List {
            Section {
                Picker("View", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                if segment != .recent {
                    Picker("Window", selection: $window) {
                        ForEach(Window.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }
            }

            switch segment {
            case .recent: recentSection
            case .tracks: topTracksSection
            case .artists: topArtistsSection
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Record history", isOn: Binding(
                        get: { model.history.isEnabled },
                        set: { model.history.isEnabled = $0 }
                    ))
                    Button("Clear history…", role: .destructive) { showsClearConfirm = true }
                        .disabled(model.history.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: "\(segment.rawValue)-\(window.rawValue)") {
            await loadServerTopIfNeeded()
        }
        .refreshable {
            // Pull-to-refresh must reach the server ranking too — it was previously
            // fetched once per screen and then frozen, so playing more music never
            // changed it.
            serverTop = []
            await loadServerTopIfNeeded()
        }
        .confirmationDialog("Clear listening history?", isPresented: $showsClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.history.clear() }
        } message: {
            Text("This only clears the log on this phone. Your server's play counts are untouched.")
        }
        .overlay {
            if model.history.entries.isEmpty {
                ContentUnavailableView("Nothing played yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Play something and it'll show up here."))
            }
        }
    }

    private func loadServerTopIfNeeded() async {
        guard segment == .tracks, window == .all, serverTop.isEmpty, !loadingServerTop else { return }
        loadingServerTop = true
        serverTop = await model.musicLibrary.serverTopSongs()
        loadingServerTop = false
    }

    @ViewBuilder
    private var recentSection: some View {
        let songs = model.history.recentlyPlayed
        Section {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                SongRow(song: song, model: model)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.music.play(songs, startAt: index, source: .init(label: "History", kind: .search))
                    }
                    .songContextMenu(song, model: model)
            }
        } header: {
            // Says whose plays these are. The all-time Top Tracks view answers from the
            // server and counts every device, so an unlabelled "plays" here would invite
            // the reader to compare two numbers that mean different things.
            Text("\(model.history.lifetimeCount) plays on this iPhone")
                .textCase(nil)
        }
    }

    /// All-time top tracks come from the server, so they include what you played on the
    /// Mac. Windowed ones can't: Subsonic keeps a running count, not an event log.
    @ViewBuilder
    private var topTracksSection: some View {
        if window == .all, !serverTop.isEmpty {
            Section {
                ForEach(Array(serverTop.enumerated()), id: \.element.id) { index, song in
                    HStack {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        SongRow(song: song, model: model)
                        Text("\(song.playCount ?? 0)×")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.music.play(serverTop, startAt: index,
                                         source: .init(label: "Top Tracks", kind: .search))
                    }
                    .songContextMenu(song, model: model)
                }
            } header: {
                Label("Across all your devices", systemImage: "icloud")
                    .font(.caption)
                    .textCase(nil)
            }
        } else {
            localTopTracks
        }
    }

    @ViewBuilder
    private var localTopTracks: some View {
        let ranked = model.history.topTracks(since: window.since, limit: 50)
        Section {
            ForEach(Array(ranked.enumerated()), id: \.offset) { index, entry in
                HStack {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    SongRow(song: entry.song, model: model)
                    Text("\(entry.count)×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.music.play(ranked.map(\.song), startAt: index,
                                     source: .init(label: "Top Tracks", kind: .search))
                }
                .songContextMenu(entry.song, model: model)
            }
        } header: {
            // Saying which device a number describes is the difference between a stat and
            // a puzzle, now that the all-time view answers from the server.
            Text(window == .all
                 ? "\(model.history.playCount(since: window.since)) plays on this iPhone"
                 : "\(model.history.playCount(since: window.since)) plays on this iPhone \u{00b7} \(window.label.lowercased())")
                .textCase(nil)
        }
    }

    @ViewBuilder
    private var topArtistsSection: some View {
        let ranked = model.history.topArtists(since: window.since, limit: 50)
        Section {
            ForEach(Array(ranked.enumerated()), id: \.offset) { index, entry in
                HStack {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    Text(entry.artist).lineLimit(1)
                    Spacer()
                    Text("\(entry.count)×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
