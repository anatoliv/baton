import AppKit
import SwiftUI

/// Reusable multi-select state for any music browse list (songs, albums, artists,
/// playlists). Holds a set of selected ids + the range anchor, and delegates the click
/// math (plain toggle / Shift-range) to the pure, unit-tested `MusicSelectionMath`.
///
/// Extracted from the Liked/Search Songs collection so every screen gets the same
/// gesture model (⌘A, Shift-range, Esc) instead of re-implementing it per entity.
@MainActor
@Observable
final class MusicMultiSelect {
    private(set) var ids: Set<String> = []
    private(set) var anchor: String?

    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// How many of `ordered` are selected — the count to show in the bar (a filtered
    /// list can hide selected ids, so this is derived from what's on screen).
    func selectedCount(in ordered: [String]) -> Int { ordered.reduce(0) { $0 + (ids.contains($1) ? 1 : 0) } }

    func allSelected(_ ordered: [String]) -> Bool { !ordered.isEmpty && ordered.allSatisfy { ids.contains($0) } }

    /// A modifier-aware click: plain click toggles one item + moves the anchor;
    /// Shift-click adds the contiguous range from the anchor to here. Reads the live
    /// Shift flag off `NSEvent` so callers don't have to.
    func clicked(_ id: String, ordered: [String]) {
        let result = MusicSelectionMath.afterClick(
            id: id, orderedIDs: ordered, selection: ids, anchor: anchor,
            shift: NSEvent.modifierFlags.contains(.shift)
        )
        ids = result.selection
        anchor = result.anchor
    }

    /// Select-all toggle for the header: selects every displayed id, or clears them if
    /// all are already selected.
    func toggleSelectAll(_ ordered: [String]) {
        if allSelected(ordered) { ids.subtract(ordered) } else { ids.formUnion(ordered) }
    }

    /// Select every displayed id (⌘A) and park the anchor on the last one.
    func selectAll(_ ordered: [String]) {
        ids.formUnion(ordered)
        anchor = ordered.last
    }

    func clear() {
        ids.removeAll()
        anchor = nil
    }

    /// Drop any selected ids that are no longer visible (after a filter/search/sort
    /// change) so the selection — and the "N selected" count — never refers to hidden
    /// items. Keeps still-visible picks; the anchor is dropped if it vanished.
    func reconcile(_ visible: [String]) {
        let set = Set(visible)
        ids.formIntersection(set)
        if let anchor, !set.contains(anchor) { self.anchor = nil }
    }
}

/// Shared batch operations over a set of songs, so every browse screen's selection bar
/// (songs, albums, artists, playlists) runs identical play/queue/download/save/remove
/// logic instead of re-implementing it. Callers pass a `gather` closure that resolves
/// their selection to songs (a per-entity, possibly-async fetch); the action owns the
/// Task, empty-guard, and toast.
@MainActor
enum MusicBatchActions {
    static func songs(ofAlbums albums: [NavidromeAlbum], _ model: MusicModel) async -> [NavidromeSong] {
        var all: [NavidromeSong] = []
        for album in albums { all += await model.musicLibrary.albumSongs(id: album.id) }
        return all
    }

    static func songs(ofArtists artists: [NavidromeArtist], _ model: MusicModel) async -> [NavidromeSong] {
        var all: [NavidromeSong] = []
        for artist in artists { all += await model.musicLibrary.artistSongs(id: artist.id) }
        return all
    }

    static func songs(ofPlaylists playlists: [NavidromePlaylist], _ model: MusicModel) async -> [NavidromeSong] {
        var all: [NavidromeSong] = []
        for playlist in playlists { all += (await model.musicLibrary.playlist(id: playlist.id)?.songs ?? []) }
        return all
    }

    static func play(
        _ model: MusicModel, shuffle: Bool, label: String,
        kind: StreamingPlaybackController.QueueSource.Kind = .song,
        gather: @escaping () async -> [NavidromeSong]
    ) {
        Task {
            var songs = await gather()
            guard !songs.isEmpty else { return }
            if shuffle { songs.shuffle() }
            model.music.play(songs, source: .init(label: label, kind: kind, id: nil))
        }
    }

    static func queue(_ model: MusicModel, gather: @escaping () async -> [NavidromeSong]) {
        Task { let songs = await gather(); if !songs.isEmpty { model.music.enqueue(songs) } }
    }

    static func download(_ model: MusicModel, gather: @escaping () async -> [NavidromeSong]) {
        Task {
            let songs = await gather()
            guard !songs.isEmpty else { return }
            model.music.postToast("Downloading \(songs.count) song\(songs.count == 1 ? "" : "s")…", symbol: "arrow.down.circle")
            await MusicDownloadStore.shared.download(songs)
        }
    }

    static func save(_ model: MusicModel, name: String, gather: @escaping () async -> [NavidromeSong]) {
        Task {
            let songs = await gather()
            guard !songs.isEmpty else { return }
            _ = await model.musicLibrary.createPlaylist(name: name, songIDs: songs.map(\.id))
            await model.musicLibrary.loadPlaylists()
            model.music.postToast("Saved playlist “\(name)”", symbol: "square.and.arrow.down")
        }
    }

    static func markForRemoval(
        _ model: MusicModel, gather: @escaping () async -> [NavidromeSong], onDone: @escaping () -> Void = {}
    ) {
        Task {
            let songs = await gather()
            model.music.postToast("Marked \(songs.count) track\(songs.count == 1 ? "" : "s") for removal", symbol: "xmark.bin")
            for song in songs { await model.musicLibrary.markForRemoval(song) }
            onDone()
        }
    }
}

/// The shared batch action-bar chrome shown while a selection is active: a select-all
/// toggle, a count, the caller-supplied `actions` (entity-specific batch buttons), and a
/// Clear (Esc). Replaces the transport in a browse header, identically on every screen.
struct MusicSelectionBar<Actions: View>: View {
    let count: Int
    let allSelected: Bool
    /// When true, the select-all toggle also answers ⌘A (suppressed while a text field
    /// is focused so ⌘A selects text instead).
    var selectAllShortcut: Bool = false
    let onToggleSelectAll: () -> Void
    let onClear: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleSelectAll) {
                Image(systemName: allSelected ? "checkmark.circle.fill" : "minus.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(selectAllShortcut ? KeyboardShortcut("a", modifiers: .command) : nil)
            .help(allSelected ? "Deselect all" : "Select all displayed (⌘A)")

            Text("\(count) selected").font(.caption).foregroundStyle(.secondary)

            Divider().frame(height: 16)

            actions()

            Divider().frame(height: 16)

            Button(action: onClear) {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Clear selection (Esc)")
        }
    }
}

/// A batch "Add to Playlist" menu for the selection bar — lists existing playlists and adds
/// the gathered selection to the chosen one (deduped by the store). "New Playlist" is
/// intentionally omitted here — that's the adjacent "Save as playlist" button.
struct MusicBatchAddToPlaylistMenu: View {
    @Environment(MusicModel.self) private var model
    let gather: () async -> [NavidromeSong]

    var body: some View {
        Menu {
            if model.musicLibrary.playlists.isEmpty {
                Text("No playlists yet")
            } else {
                ForEach(model.musicLibrary.playlists) { playlist in
                    Button(playlist.name) { add(to: playlist) }
                }
            }
        } label: {
            Image(systemName: "music.note.list").font(.body).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Add selection to a playlist")
        .task { if model.musicLibrary.playlists.isEmpty { await model.musicLibrary.loadPlaylists() } }
    }

    private func add(to playlist: NavidromePlaylist) {
        Task {
            let songs = await gather()
            guard !songs.isEmpty else { return }
            let added = await model.musicLibrary.addToPlaylist(id: playlist.id, songIDs: songs.map(\.id))
            if added == 0 {
                model.music.postToast("Already in “\(playlist.name)”", symbol: "checkmark.circle")
            } else {
                model.music.postToast("Added \(added) track\(added == 1 ? "" : "s") to “\(playlist.name)”", symbol: "music.note.list")
            }
        }
    }
}

/// One batch action button in a `MusicSelectionBar` — a fixed-size icon with a tooltip.
struct MusicBatchButton: View {
    let system: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.body).foregroundStyle(tint)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The selection checkbox shown at the leading edge of a selectable browse row/card.
/// Visible on hover or when selected (keeps its slot so the row doesn't shift).
struct MusicSelectCheckbox: View {
    let isSelected: Bool
    /// Reveal even when unselected (e.g. on row hover). Selected always shows.
    var visible: Bool = true
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .opacity(isSelected || visible ? 1 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).frame(width: 18).help("Select")
    }
}
