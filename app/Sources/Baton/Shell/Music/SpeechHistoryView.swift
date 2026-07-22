import AppKit
import SwiftUI

/// The "Spoken Summaries" window — a two-pane replay surface. The **left pane** is the scrollable
/// history of summaries spoken through the `speak_summary` MCP tool (newest first); the **right
/// pane** embeds the same player card as the floating speaking HUD, so replaying a row plays *here,
/// inline* instead of popping the HUD on top of this window. A draggable divider resizes the panes,
/// and both the split width and the window frame are remembered across launches. Opened from the
/// Playback menu, the menu-bar controller, and the speaking HUD's history glyph. Backed by
/// `MusicModel.speechHistory` + `MusicModel.speech`.
///
/// While this window is focused it sets `model.summariesWindowIsForeground`, which the
/// `SpeakingHUDPresenter` reads to keep the floating HUD hidden (the inline pane covers it). When
/// the window loses focus or closes, the HUD resumes its normal ambient behavior.
struct SpeechHistoryView: View {
    static let windowID = "speech-history"

    /// The list pane's floor + the detail pane's floor; the divider and window mins derive from these.
    private static let listMin: CGFloat = 240
    private static let detailMin: CGFloat = 320
    /// The split's reset target (double-click the divider) and first-run default.
    private static let defaultListWidth: Double = 300

    @Environment(MusicModel.self) private var model
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The list pane's width — the draggable split, remembered across launches.
    @AppStorage("baton.summaries.listWidth") private var listWidth: Double = SpeechHistoryView.defaultListWidth
    @State private var showClearConfirm = false
    /// Free-text filter over the summary text + category (history is append-forever).
    @State private var filter = ""
    /// The row the user has clicked — a list affordance for keyboard actions (Return replays,
    /// Delete removes). Distinct from the now-playing row, exactly as Music.app separates the two.
    @State private var selection: SpeechHistoryStore.Entry.ID?

    private var entries: [SpeechHistoryStore.Entry] { model.speechHistory.entries }

    /// Entries after the filter — matched against the spoken text and the category.
    private var filteredEntries: [SpeechHistoryStore.Entry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.text.lowercased().contains(q) || ($0.category?.lowercased().contains(q) ?? false)
        }
    }

    /// The history entry the player pane is showing — the now-playing / last-played one — so the
    /// detail pane can surface its metadata and the list can highlight it.
    private var activeEntry: SpeechHistoryStore.Entry? {
        entries.first { $0.id == model.nowPlayingSummaryID }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                // No history at all → one full-window empty state, not two side by side.
                ContentUnavailableView(
                    "No spoken summaries yet",
                    systemImage: "waveform",
                    description: Text("Summaries an agent speaks through Baton appear here, so you can replay any of them.")
                )
            } else {
                splitPanes
            }
        }
        .frame(minWidth: Self.listMin + Self.detailMin, minHeight: 360)
        .background(SummariesWindowAccessor())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openBatonSettings(.speech, using: openWindow) } label: {
                    Label("Speech Settings", systemImage: "gearshape")
                }
                .help("Voices & delivery in Settings → Speech")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
                .help("Clear the spoken-summary history")
            }
        }
        .confirmationDialog("Clear spoken-summary history?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.clearSpokenSummaries() }
        } message: {
            Text("Removes the list of recent spoken summaries. It doesn't affect anything else.")
        }
        .navigationTitle("Spoken Summaries")
        // Suppress the floating HUD only while this window is the *key* window — so an agent
        // speaking while the user is off in another app still gets the ambient HUD.
        .onChange(of: controlActiveState, initial: true) { _, state in
            model.summariesWindowIsForeground = (state == .key)
        }
        .onDisappear { model.summariesWindowIsForeground = false }
    }

    /// The two-pane layout (only rendered when there's history): resizable list + player detail.
    private var splitPanes: some View {
        GeometryReader { geo in
            // Keep the detail pane at or above its floor even as the divider drags / the window
            // shrinks — the list clamps rather than squeezing the player off-screen.
            let maxList = max(Self.listMin, geo.size.width - Self.detailMin)
            HStack(spacing: 0) {
                listPane
                    .frame(width: min(max(listWidth, Self.listMin), maxList))
                PaneDivider(width: $listWidth, range: Self.listMin ... maxList) {
                    listWidth = Self.defaultListWidth // double-click the divider to reset the split
                }
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Left pane — a filter field over the history list. Highlights the now-playing row, auto-scrolls.
    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Filter summaries", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear filter")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            ScrollViewReader { proxy in
                // Single-click selects a row and loads it into the player pane (no audio); Replay/Copy
                // also select it. Audio starts only on Replay, the pane's Play, or Return. Delete
                // removes the selection.
                List(selection: $selection) {
                    ForEach(filteredEntries) { entry in
                        SpeechHistoryRow(
                            entry: entry,
                            isActive: entry.id == model.nowPlayingSummaryID,
                            isSpeaking: model.speech.isSpeaking,
                            onReplay: { selection = entry.id; model.replaySpokenSummary(entry) },
                            onCopy: { selection = entry.id; copy(entry) },
                            onDelete: { delete(entry) }
                        )
                        .tag(entry.id)
                        .id(entry.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if filteredEntries.isEmpty {
                        ContentUnavailableView.search(text: filter)
                    }
                }
                // Whatever starts playing (a replay or a fresh agent summary) becomes the loaded
                // selection, so the player pane follows the audio and the row scrolls into view.
                .onChange(of: model.nowPlayingSummaryID, initial: true) { _, id in
                    guard let id else { return }
                    selection = id
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onDeleteCommand { if let entry = selectedEntry { delete(entry) } }
                .onKeyPress(.return) {
                    guard let entry = selectedEntry else { return .ignored }
                    model.replaySpokenSummary(entry)
                    return .handled
                }
                // First open with nothing ever played: load the newest so the pane isn't empty.
                .onAppear { if selection == nil { selection = model.nowPlayingSummaryID ?? entries.first?.id } }
            }
        }
    }

    /// Right pane — the loaded (selected) summary: a metadata header over the shared player card, with
    /// a **Play** button that starts *this* summary. Audio never starts from selection alone.
    private var detailPane: some View {
        Group {
            if let entry = loadedEntry {
                VStack(spacing: 0) {
                    detailHeader(for: entry)
                    SpeakingPlayerView(
                        idleText: entry.text,
                        idlePlay: .init(icon: "play.circle.fill", help: "Play this summary") {
                            model.replaySpokenSummary(entry)
                        },
                        // Live controls only when the engine is actually playing *this* entry.
                        live: model.speech.isSpeaking && entry.id == model.nowPlayingSummaryID
                    )
                    .padding(16)
                    .speakingCardSurface(cornerRadius: 16)
                    .padding([.horizontal, .bottom], 16)
                }
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "waveform.slash",
                    description: Text("Select a summary from the list to load it here.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The summary loaded into the player pane — the selection, then now-playing, then the newest, so
    /// the pane is never blank while there's history (auto-select can lag the first render frame).
    private var loadedEntry: SpeechHistoryStore.Entry? { selectedEntry ?? activeEntry ?? entries.first }

    /// A small header above the player card: a status word only while it's actually playing/paused
    /// (nothing when merely selected — that's obvious), plus the summary's timestamp and badges.
    private func detailHeader(for entry: SpeechHistoryStore.Entry) -> some View {
        let speech = model.speech
        let isPlayingThis = speech.isSpeaking && entry.id == model.nowPlayingSummaryID
        let status: String? = isPlayingThis ? (speech.isPaused ? "Paused" : "Now playing") : nil
        return HStack(spacing: 8) {
            Image(systemName: isPlayingThis && !speech.isPaused ? "speaker.wave.2.fill" : "waveform")
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, isActive: isPlayingThis && !speech.isPaused && !reduceMotion)
            if let status {
                Text(status).font(.subheadline.weight(.semibold))
                Text("·").foregroundStyle(.tertiary)
            }
            Text(entry.date, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            SummaryBadge(text: entry.engine, tint: entry.engine == "system" ? .secondary : .blue)
            if let category = entry.category, !category.isEmpty {
                SummaryBadge(text: category, tint: .green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    /// The entry matching the current selection, if any.
    private var selectedEntry: SpeechHistoryStore.Entry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    /// Copy a summary's text to the pasteboard.
    private func copy(_ entry: SpeechHistoryStore.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    /// Delete an entry, advancing the selection to a neighbor so the highlight doesn't vanish.
    private func delete(_ entry: SpeechHistoryStore.Entry) {
        if selection == entry.id, let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            let neighbor = entries[safe: idx + 1] ?? entries[safe: idx - 1]
            selection = neighbor?.id
        }
        model.deleteSpokenSummary(entry)
    }
}

private extension Array {
    /// Bounds-checked subscript — nil instead of trapping, for picking a post-delete neighbor.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A thin, draggable divider that resizes the pane to its left by adjusting `width` (clamped to
/// `range`). The caller persists `width` (`@AppStorage`), so the split is remembered across
/// launches. Shows the horizontal-resize cursor on hover and a wide invisible hit area.
private struct PaneDivider: View {
    @Binding var width: Double
    let range: ClosedRange<CGFloat>
    /// Double-click to reset the split to its default.
    let onReset: () -> Void
    /// The pane width captured at the drag's start, so `translation` (cumulative) applies from there.
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.2)) { onReset() } }
                    // Measure the drag in GLOBAL space: the divider itself shifts as `width`
                    // changes, so a local translation would chase a moving origin and the panes
                    // would shake. Global space stays fixed, so `translation` tracks the cursor.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                width = min(max(base + value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

/// Persists the Spoken Summaries window's size + position across launches via AppKit frame autosave,
/// so it reopens where you left it. Matches the app's window-accessor pattern (see `HelpWindowSizer`).
private struct SummariesWindowAccessor: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView { SummariesWindowAccessorView() }
    func updateNSView(_: NSView, context _: Context) {}
}

private final class SummariesWindowAccessorView: NSView {
    private var didAttach = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didAttach, let window else { return }
        didAttach = true
        // Load any saved frame first, then keep saving on move/resize under the same name.
        window.setFrameUsingName("BatonSpokenSummaries")
        window.setFrameAutosaveName("BatonSpokenSummaries")
    }
}

/// One summary row: an active marker + relative time + engine/category badges, the text, and
/// hover-revealed Replay / Copy / Delete actions (matching the app's other list rows). Double-click
/// the row replays it; right-click (or swipe) exposes the same actions with no hover needed.
private struct SpeechHistoryRow: View {
    let entry: SpeechHistoryStore.Entry
    /// The now-playing / last-played row — tinted and marked.
    let isActive: Bool
    /// Whether a summary is speaking right now (drives the active marker's animation).
    let isSpeaking: Bool
    let onReplay: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isActive {
                    Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "waveform")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, isActive: isSpeaking && !reduceMotion)
                        .help(isSpeaking ? "Playing now" : "Last played")
                }
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
                SummaryBadge(text: entry.engine, tint: entry.engine == "system" ? .secondary : .blue)
                if let category = entry.category, !category.isEmpty {
                    SummaryBadge(text: category, tint: .green)
                }
                Spacer()
                // Actions reveal on hover so N rows don't read as a toolbar stack; the context menu,
                // swipe, and keyboard paths carry the same actions without hovering.
                actions
                    .opacity(hover ? 1 : 0)
                    .allowsHitTesting(hover)
            }
            Text(entry.text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onReplay) // double-click the row to replay immediately
        .contextMenu {
            Button(action: onReplay) { Label("Replay", systemImage: "play.circle") }
            Button(action: onCopy) { Label("Copy Text", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onReplay) { Label("Replay", systemImage: "play.circle") }
                .buttonStyle(.borderless)
                .help("Replay this summary")
            Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy the text")
                .labelStyle(.iconOnly)
            Button(action: onDelete) { Label("Delete", systemImage: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this summary")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary) // subtle — a destructive action shouldn't shout
        }
    }
}

/// A small capsule badge (engine / category) shared by the list rows and the detail header.
private struct SummaryBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
