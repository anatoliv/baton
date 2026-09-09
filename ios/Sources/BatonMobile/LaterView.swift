import BatonPlaybackKit
import BatonSubsonicKit
import SwiftUI

/// **Later** — the cross-type save-for-later list, the phone's counterpart to the Mac's ⌘9
/// screen (`MusicPinnedView`).
///
/// `PinStore` was already constructed here, loaded from disk on launch and cleared on
/// sign-out; nothing else on the phone touched it. So anything saved on the Mac was
/// invisible on the phone, and there was no way to save anything from the phone either
/// (I-F18). This is the Mac's behaviour and no more of it: the same list, the same play
/// resolution, the same remove and clear.
struct LaterView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash
    @State private var showsClearConfirm = false

    private var store: PinStore { model.pins }
    private var pins: [PinnedItem] { store.ordered }

    var body: some View {
        List {
            ForEach(pins) { pin in
                Button { MobilePinPlayback.play(pin, model) } label: { row(pin) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.unpin(id: pin.id) } label: {
                            Label("Remove", systemImage: "bookmark.slash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if pins.isEmpty {
                ContentUnavailableView {
                    Label("Nothing saved yet", systemImage: "bookmark")
                } description: {
                    Text("Press and hold a song or album and choose Save to Later.")
                }
            }
        }
        .nowPlayingWash(wash)
        .navigationTitle("Later")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !pins.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear All", systemImage: "trash", role: .destructive) {
                            showsClearConfirm = true
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        // Destructive and not obviously reversible, so it asks — the same shape the Mac uses.
        .confirmationDialog("Clear all saved items?", isPresented: $showsClearConfirm,
                            titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { store.clear() }
        } message: {
            Text("Removes all \(store.pins.count) items from Later. "
                 + "The songs, albums and shows themselves aren't affected.")
        }
        .task { store.loadIfNeeded() }
    }

    private func row(_ pin: PinnedItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: artURL(pin), side: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(pin.title).lineLimit(1)
                // The kind is part of the subtitle rather than a second column: a list on a
                // phone has no room for the Mac's "Kind" column, and "Album · Dido" says the
                // same thing in the space there is.
                Text(pin.subtitle.map { "\(pin.kind.label) · \($0)" } ?? pin.kind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: pin.kind.icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func artURL(_ pin: PinnedItem) -> URL? {
        if let direct = pin.artworkURL { return direct }
        return pin.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 120) }
    }
}

// MARK: - Playback

/// Resolves a pin to playback, the phone's copy of the Mac's `PinPlayback`. Directly
/// playable kinds start now; collection kinds load their tracks first.
@MainActor
enum MobilePinPlayback {
    static func play(_ pin: PinnedItem, _ model: MobileModel) {
        let source = QueueSource(label: pin.title, kind: .playlist, id: pin.refID)
        switch pin.kind {
        case .song, .podcastEpisode:
            model.music.play([pin.asSong], source: source)
        case .radioStation:
            if let station = model.radio.stations.first(where: { $0.id == pin.refID }) {
                model.radio.play(station)
            }
        case .podcastChannel:
            guard let channel = model.podcastSubscriptions.channels
                .first(where: { $0.id == pin.refID }) else { return }
            // Episodes are stored newest-first; a whole show plays oldest-first so a
            // serialized podcast runs in order. Same rule as the Mac.
            let songs = channel.episodes.reversed().map {
                $0.asSong(channelTitle: channel.title, artwork: $0.imageURL ?? channel.imageURL)
            }
            play(songs, source, model)
        case .album:
            Task { play(await model.musicLibrary.albumSongs(id: pin.refID), source, model) }
        case .playlist:
            Task { play(await model.musicLibrary.playlist(id: pin.refID)?.songs ?? [], source, model) }
        case .artist:
            Task { play(await model.musicLibrary.artistSongs(id: pin.refID), source, model) }
        }
    }

    private static func play(_ songs: [NavidromeSong], _ source: QueueSource, _ model: MobileModel) {
        guard !songs.isEmpty else { return }
        model.music.play(songs, source: source)
    }
}

// MARK: - Save to Later

/// The pin toggle, for a row's long-press menu. Takes `model` explicitly rather than through
/// the environment, for the same reason the Mac's does: SwiftUI does not reliably carry an
/// observable environment value into context-menu content.
struct PinMenuButton: View {
    let item: PinnedItem
    let model: MobileModel

    var body: some View {
        let pinned = model.pins.isPinned(item.id)
        Button {
            model.pins.toggle(item)
        } label: {
            Label(pinned ? "Remove from Later" : "Save to Later",
                  systemImage: pinned ? "bookmark.slash" : "bookmark")
        }
    }
}
