import AppKit
import SwiftUI

/// The "Spoken Summaries" window — a scrollable list of recent summaries spoken through the
/// `speak_summary` MCP tool, newest first, so any one can be replayed (re-synthesized in its
/// original voice) or copied. Opened from the Playback menu and the menu-bar controller. Backed by
/// `MusicModel.speechHistory`.
struct SpeechHistoryView: View {
    static let windowID = "speech-history"

    @Environment(MusicModel.self) private var model
    @State private var showClearConfirm = false

    private var entries: [SpeechHistoryStore.Entry] { model.speechHistory.entries }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No spoken summaries yet",
                    systemImage: "waveform",
                    description: Text("Summaries an agent speaks through Baton appear here, so you can replay any of them.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        SpeechHistoryRow(entry: entry) { model.replaySpokenSummary(entry) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
                .help("Clear the spoken-summary history")
            }
        }
        .confirmationDialog("Clear spoken-summary history?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.speechHistory.clear() }
        } message: {
            Text("Removes the list of recent spoken summaries. It doesn't affect anything else.")
        }
        .navigationTitle("Spoken Summaries")
    }
}

/// One summary row: relative time + engine/category badges, the text, and Replay / Copy actions.
private struct SpeechHistoryRow: View {
    let entry: SpeechHistoryStore.Entry
    let onReplay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
                badge(entry.engine, tint: entry.engine == "system" ? .secondary : .blue)
                if let category = entry.category, !category.isEmpty {
                    badge(category, tint: .green)
                }
                Spacer()
                Button(action: onReplay) {
                    Label("Replay", systemImage: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Replay this summary")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the text")
                .labelStyle(.iconOnly)
            }
            Text(entry.text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
