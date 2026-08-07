import SwiftUI

/// Internet radio — the stations saved on your Navidrome server, played as raw streams.
///
/// A station is deliberately not a queue item: it's an endless stream with no song id,
/// duration or "next". That's why it runs on `RadioPlaybackEngine` rather than the
/// library transport, and why tuning one in ducks the library player rather than
/// enqueuing anything. Both the store and the engine are shared with the Mac.
struct RadioView: View {
    let model: MobileModel
    @State private var query = ""
    @State private var showsAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var editing: NavidromeRadioStation?

    var body: some View {
        List {
            if let station = model.radio.onAirStation { onAir(station) }

            Section {
                ForEach(filtered) { station in
                    Button {
                        model.radio.toggle(station)
                    } label: {
                        HStack(spacing: 12) {
                            stationArtwork(station)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(station.name).lineLimit(1)
                                if let subtitle = model.radio.meta[station.id]?.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 6)
                            if model.radio.isPlaying(station) {
                                Image(systemName: "waveform").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            editing = station
                            newName = station.name
                            newURL = station.streamUrl
                        } label: { Label("Edit…", systemImage: "pencil") }
                        if let home = station.homepageUrl, let url = URL(string: home) {
                            Link(destination: url) { Label("Open homepage", systemImage: "safari") }
                        }
                        Button(role: .destructive) {
                            Task { await model.radio.delete(station) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    .task {
                        // Genre/bitrate and a logo aren't in Navidrome's station record;
                        // both are resolved off the stream and cached.
                        model.radio.resolveMeta(for: station)
                        model.radio.resolveArtwork(for: station)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Stations")
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""; newURL = ""; showsAdd = true
                } label: { Image(systemName: "plus") }
                .disabled(model.isDemoMode)
            }
        }
        .overlay {
            if model.radio.loading {
                ProgressView()
            } else if model.radio.stations.isEmpty {
                ContentUnavailableView(
                    "No stations",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(model.radio.loadError
                                      ?? "Add a stream URL here, or save stations on your server.")
                )
            }
        }
        .task { await model.radio.loadIfNeeded() }
        .refreshable { await model.radio.reload() }
        .alert("Add station", isPresented: $showsAdd) {
            TextField("Name", text: $newName)
            TextField("Stream URL", text: $newURL)
            Button("Add") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                let url = newURL.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !url.isEmpty else { return }
                Task { await model.radio.add(name: name, streamURL: url, homepage: nil) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit station", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $newName)
            TextField("Stream URL", text: $newURL)
            Button("Save") {
                guard let station = editing else { return }
                Task {
                    await model.radio.update(station,
                                             name: newName.trimmingCharacters(in: .whitespaces),
                                             streamURL: newURL.trimmingCharacters(in: .whitespaces),
                                             homepage: station.homepageUrl)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The on-air banner: what's playing right now, and the stop control. Stations
    /// broadcast their current track over ICY, which is the only "now playing" a raw
    /// stream has.
    private func onAir(_ station: NavidromeRadioStation) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("On air", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(station.name).font(.headline)
                if let title = model.radio.engine.nowPlayingTitle {
                    Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Button {
                        model.radio.engine.isPlaying ? model.radio.engine.pause() : model.radio.engine.resume()
                    } label: {
                        Label(model.radio.engine.isPlaying ? "Pause" : "Play",
                              systemImage: model.radio.engine.isPlaying ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        model.radio.stop()
                    } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func stationArtwork(_ station: NavidromeRadioStation) -> some View {
        switch model.radio.artwork[station.id] {
        case .logo(let url):
            ArtworkView(url: url)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        default:
            // A monogram beats a grey box when a station simply has no logo to find.
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.18))
                Text(String(station.name.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 44, height: 44)
        }
    }

    private var filtered: [NavidromeRadioStation] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return model.radio.stations }
        return model.radio.stations.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }
}
