import AppKit
import SwiftUI

/// Choosing an SF Symbol by typing its exact name is a guessing game: get it wrong and
/// `Image(systemName:)` renders *nothing at all*, with no error anywhere. This gives the name
/// field a live preview, tells you when a name doesn't resolve, and offers a browsable set of
/// symbols that actually suit an action — so the common case never involves typing a name.
///
/// Deliberately curated rather than exhaustive: SF Symbols runs to thousands of names, which is
/// unusable in a popover and impossible to search without shipping a name catalogue. These are the
/// ones that read clearly at menu size for "do something with this item".
enum SFSymbolCatalog {
    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let symbols: [String]
    }

    static let groups: [Group] = [
        .init(title: "Transcribe & text", symbols: [
            "doc.text", "doc.plaintext", "text.viewfinder", "captions.bubble",
            "quote.bubble", "character.bubble", "text.badge.checkmark", "list.bullet.rectangle",
        ]),
        .init(title: "Send & share", symbols: [
            "paperplane", "paperplane.fill", "arrow.up.forward.app", "square.and.arrow.up",
            "link", "network", "antenna.radiowaves.left.and.right", "arrow.turn.up.right",
        ]),
        .init(title: "Save & archive", symbols: [
            "tray.and.arrow.down", "archivebox", "bookmark", "folder",
            "internaldrive", "square.and.arrow.down", "externaldrive", "shippingbox",
        ]),
        .init(title: "Automation", symbols: [
            "bolt.horizontal.circle", "bolt", "gearshape.2", "wand.and.stars",
            "sparkles", "cpu", "terminal", "arrow.triangle.2.circlepath",
        ]),
        .init(title: "Media", symbols: [
            "waveform", "music.note", "mic", "headphones",
            "play.rectangle", "speaker.wave.2", "video", "photo",
        ]),
        .init(title: "Status & flags", symbols: [
            "checkmark.seal", "flag", "star", "bell",
            "tag", "heart", "exclamationmark.bubble", "clock",
        ]),
    ]

    /// Fallback used wherever an action's icon is drawn, so a blank or bogus name never renders
    /// an invisible image.
    static let fallback = "bolt.horizontal.circle"

    /// Whether the system can actually draw this symbol. `Image(systemName:)` fails silently, so
    /// this is the only way to tell a typo from a valid name.
    static func isValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil
    }

    /// The name to actually render for a stored icon value.
    static func resolved(_ name: String) -> String {
        isValid(name) ? name.trimmingCharacters(in: .whitespaces) : fallback
    }

    /// Curated symbols matching `query` (name substring or its group's title), all when empty.
    static func search(_ query: String) -> [Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.title.lowercased().contains(q) { return group }
            let hits = group.symbols.filter { $0.lowercased().contains(q) }
            return hits.isEmpty ? nil : Group(title: group.title, symbols: hits)
        }
    }
}

/// A name field with a live preview swatch that opens a browsable symbol grid.
///
/// Keeps free text — any SF Symbol is allowed, not just the curated ones — but makes an
/// unrenderable name visible instead of silently blank.
struct SymbolField: View {
    @Binding var symbol: String
    var label: String = "Icon"
    @State private var showingPicker = false

    private var isBlank: Bool { symbol.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isBroken: Bool { !isBlank && !SFSymbolCatalog.isValid(symbol) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // The preview doubles as the picker button, so the icon you see is the control
                // you press to change it.
                Button { showingPicker = true } label: {
                    Image(systemName: SFSymbolCatalog.resolved(symbol))
                        .font(.system(size: 15))
                        .foregroundStyle(isBroken ? Color.orange : Color.accentColor)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Choose a symbol")
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    SymbolPickerPopover(symbol: $symbol)
                }

                TextField(label, text: $symbol, prompt: Text(SFSymbolCatalog.fallback))
            }
            if isBroken {
                Text("No SF Symbol called “\(symbol.trimmingCharacters(in: .whitespaces))” — the \(SFSymbolCatalog.fallback) icon will be used instead.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The grid shown in the popover: sectioned, searchable, drawn at final size.
private struct SymbolPickerPopover: View {
    @Binding var symbol: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search symbols", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    let groups = SFSymbolCatalog.search(query)
                    if groups.isEmpty {
                        Text("No matches. You can still type any SF Symbol name.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(groups) { group in
                        Section {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(group.symbols, id: \.self) { name in
                                    Button {
                                        symbol = name
                                        dismiss()
                                    } label: {
                                        Image(systemName: name)
                                            .font(.system(size: 15))
                                            .frame(width: 30, height: 26)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(name == symbol
                                                          ? Color.accentColor.opacity(0.22) : Color.clear)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help(name)
                                }
                            }
                        } header: {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, height: 300)
    }
}
