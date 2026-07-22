import SwiftUI

/// The **Later** screen — a unified, cross-type list of everything you've pinned to come back
/// to: songs, albums, artists, playlists, podcasts, and radio stations. A pin is a local
/// save-for-later, distinct from Liked (a server taste star) and the transient Queue. Its chrome
/// mirrors the **Liked** collection: title + inline kind segments + filter, then a width-capped
/// table (or a card grid) at the same density. Play resolves the pin's typed reference.
struct MusicPinnedView: View {
    @Environment(MusicModel.self) private var model

    @State private var filterText = ""
    @State private var kindFilter: PinnedItem.Kind?
    @State private var showClearConfirm = false
    @FocusState private var filterFocused: Bool
    @AppStorage("tonebox.music.laterLayout") private var layout: MusicBrowseLayout = .list

    private var store: PinStore { model.pins }

    private var visiblePins: [PinnedItem] {
        var list = store.ordered
        if let kindFilter { list = list.filter { $0.kind == kindFilter } }
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) || ($0.subtitle ?? "").lowercased().contains(query)
            }
        }
        return list
    }

    /// The kinds actually present, for the segmented filter (so it never shows empty buckets).
    private var presentKinds: [PinnedItem.Kind] {
        PinnedItem.Kind.allCases.filter { kind in store.pins.contains { $0.kind == kind } }
    }

    private func count(_ kind: PinnedItem.Kind?) -> Int {
        guard let kind else { return store.pins.count }
        return store.pins.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.pins.isEmpty {
                emptyState("bookmark", "Nothing saved yet",
                           "Right-click any song, album, podcast, or station and choose “Save to Later”.")
            } else {
                MusicBrowseHeader(
                    title: "Later",
                    count: visiblePins.count,
                    filter: $filterText,
                    filterPrompt: "Filter saved",
                    filterFocused: $filterFocused,
                    filterHistoryKey: "later",
                    layout: $layout,
                    accessory: {
                        if presentKinds.count > 1 {
                            HStack(spacing: 12) {
                                Divider().frame(height: 20)
                                kindSegments
                            }
                        }
                    },
                    leading: { clearMenu },
                    sortMenu: { EmptyView() }
                )
                content
            }
        }
        .task { store.loadIfNeeded() }
        // Destructive, so confirm — matching History/Downloads/Playlists clear flows.
        .confirmationDialog("Clear all saved items?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { store.clear() }
        } message: {
            Text("Removes all \(store.pins.count) items from Later. The songs, albums, and shows themselves aren't affected.")
        }
    }

    /// Inline All / Album / Episode … segmented pills — the Later analogue of Liked's
    /// Songs / Albums / Artists switcher (same rounded container + accent-fill selection).
    private var kindSegments: some View {
        HStack(spacing: 3) {
            segment(nil, label: "All", icon: "square.grid.2x2")
            ForEach(presentKinds) { kind in segment(kind, label: kind.label, icon: kind.icon) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.hoverTint))
        .fixedSize()
    }

    private func segment(_ kind: PinnedItem.Kind?, label: String, icon: String) -> some View {
        let active = kindFilter == kind
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { kindFilter = kind }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text("\(label) \(count(kind))")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? Color.white : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var clearMenu: some View {
        Menu {
            Button("Clear All…", role: .destructive) { showClearConfirm = true }
        } label: {
            Image(systemName: "ellipsis.circle").font(.callout).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Later actions")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if visiblePins.isEmpty {
            emptyState("magnifyingglass", "No matches", "Nothing saved matches your filter.")
        } else if layout == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(visiblePins) { pin in
                        PinnedCard(pin: pin, onPlay: { PinPlayback.play(pin, model) }, onUnpin: { store.unpin(id: pin.id) })
                    }
                }
                .padding(12)
            }
        } else {
            // Width-capped table shell (column header + scrolling rows), matching Liked's list.
            VStack(spacing: 0) {
                tableHeader.padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visiblePins) { pin in
                            PinnedRow(pin: pin, onPlay: { PinPlayback.play(pin, model) }, onUnpin: { store.unpin(id: pin.id) })
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 16)
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 40, height: 1) // cover-thumb slot
                Text("Title")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Kind").frame(width: 120, alignment: .leading)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func emptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            Text(subtitle).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 40)
    }
}

// MARK: - Table row (Liked density)

/// A pinned-item row matching `MusicLikedSongRow`'s density: a cover thumbnail (play on hover /
/// now-playing indicator), title + source subtitle, a right-aligned **Kind** column, and a ⋯
/// menu — inside the width-capped table so nothing is flung to the window edge.
private struct PinnedRow: View {
    @Environment(MusicModel.self) private var model
    let pin: PinnedItem
    let onPlay: () -> Void
    let onUnpin: () -> Void
    @State private var hovering = false

    private var isCurrent: Bool { model.music.nowPlaying?.id == pin.refID }
    private var artURL: URL? {
        if let direct = pin.artworkURL { return direct }
        return pin.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 88) }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                thumbnail
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        if hovering || isCurrent {
                            ZStack {
                                Color.black.opacity(0.34)
                                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                                    .font(.caption).foregroundStyle(.white)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(pin.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if let subtitle = pin.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Label(pin.kind.label, systemImage: pin.kind.icon)
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                .frame(width: 120, alignment: .leading)

            Menu {
                Button("Play", action: onPlay)
                Button("Remove from Later", systemImage: "bookmark.slash", role: .destructive, action: onUnpin)
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.selectionTint() : (hovering ? Color.hoverTint : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: isCurrent)
        .contextMenu {
            Button("Play", action: onPlay)
            Button("Remove from Later", systemImage: "bookmark.slash", role: .destructive, action: onUnpin)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let artURL {
            AsyncImage(url: artURL) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack { Color.secondary.opacity(0.12); Image(systemName: pin.kind.icon).foregroundStyle(.secondary) }
    }
}

// MARK: - Grid card

/// The card form for the Later grid — the shared `MusicMediaCard` (like Liked's grid cells),
/// with the kind + source as its subtitle and play-on-click.
private struct PinnedCard: View {
    @Environment(MusicModel.self) private var model
    let pin: PinnedItem
    let onPlay: () -> Void
    let onUnpin: () -> Void
    @State private var hover = false

    private var isCurrent: Bool { model.music.nowPlaying?.id == pin.refID }
    private var artURL: URL? {
        if let direct = pin.artworkURL { return direct }
        return pin.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 400) }
    }

    var body: some View {
        MusicMediaCard(
            coverURL: artURL,
            aspect: 1,
            placeholder: pin.kind.icon,
            title: pin.title,
            subtitle: pin.subtitle.map { "\(pin.kind.label) · \($0)" } ?? pin.kind.label,
            isHovering: hover,
            isPlayingSource: isCurrent,
            onPlay: onPlay
        )
        .hoverLift(hover)
        .zIndex(hover ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: hover)
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("Play", action: onPlay)
            Button("Remove from Later", systemImage: "bookmark.slash", role: .destructive, action: onUnpin)
        }
    }
}
