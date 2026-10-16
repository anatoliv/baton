import BatonDocuments
import SwiftUI

/// The voice picker on both apps: the suggested voices on top, then every voice the
/// renderer offers under All voices, grouped by accent or language and gender
/// (`VoiceDirectory`), searchable, each one a tap to choose and a button to hear.
///
/// One picker for the import sheet, Change Voice and a cast member's voice, so a voice is chosen
/// the same way everywhere. Hearing a voice is the caller's: each screen already has its own way
/// to make a preview (the Mac's configured engine, or the Baton server), and `onPreview` reaches it.
/// On the phone the picker is a run of `List` sections; on the Mac it is a column for a sheet.
struct VoicePicker: View {
    /// Shown on top, in this order.
    let suggested: [String]
    /// Every voice the renderer offers; nil when it did not say.
    let all: [String]?
    /// Still asking for `all`.
    var loading = false
    /// Why `all` is missing, said under the suggested voices.
    var unavailable: String? = nil
    @Binding var chosen: String?
    /// The voice whose preview is playing.
    let playing: String?
    /// The heading over the suggested voices ("Narrator"), and a line under them.
    var title = "Suggested"
    var footer: String? = nil
    /// A word after a voice's name, such as "suggested" or "now".
    var tag: (String) -> String? = { _ in nil }
    /// A line under a suggested voice, such as what it suits.
    var detail: (String) -> String? = { _ in nil }
    let onPreview: (String) -> Void

    @State private var showAll = false
    @State private var query = ""

    private var groups: [VoiceGroup] { VoiceDirectory.groups(all ?? [], matching: query) }

    /// The suggested voices, and below them the one chosen from All voices when it is not
    /// among them, so the choice stays in sight with All voices closed.
    private var top: [String] {
        guard let chosen, !suggested.contains(chosen) else { return suggested }
        return suggested + [chosen]
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        phoneBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(top, id: \.self) { voice in
                NarratorOptionRow(voice: voice, chosen: $chosen, playing: playing == voice,
                                  detail: detail(voice), tag: tag(voice)) { onPreview(voice) }
            }
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking for every voice…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let all, !all.isEmpty {
                allToggle(all.count)
                if showAll {
                    VStack(alignment: .leading, spacing: 8) {
                        searchField
                        ScrollView {
                            allVoices.padding(.trailing, 12)
                        }
                        .frame(height: 240)
                    }
                    .padding(.leading, 18)
                }
            } else if let unavailable {
                Label(unavailable, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var allVoices: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(groups) { group in
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.voices) { entry in
                    NarratorOptionRow(voice: entry.spec, chosen: $chosen, playing: playing == entry.spec,
                                      tag: tag(entry.spec), inGroup: true) { onPreview(entry.spec) }
                }
            }
            if groups.isEmpty { noMatch }
        }
    }
    #else
    @ViewBuilder
    private var phoneBody: some View {
        Section {
            ForEach(top, id: \.self) { voice in
                NarratorOptionRow(voice: voice, chosen: $chosen, playing: playing == voice,
                                  detail: detail(voice), tag: tag(voice)) { onPreview(voice) }
            }
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking for every voice…") }
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let unavailable, all?.isEmpty ?? true {
                Label(unavailable, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
        if let all, !all.isEmpty, !loading {
            Section {
                allToggle(all.count)
                if showAll { searchField }
            }
            if showAll {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.voices) { entry in
                            NarratorOptionRow(voice: entry.spec, chosen: $chosen, playing: playing == entry.spec,
                                              tag: tag(entry.spec), inGroup: true) { onPreview(entry.spec) }
                        }
                    }
                }
                if groups.isEmpty { Section { noMatch } }
            }
        }
    }
    #endif

    /// "All voices (68)", opening and closing the list: a button, so VoiceOver and the probes
    /// can press it by name on both apps.
    private func allToggle(_ count: Int) -> some View {
        Button {
            withAnimation { showAll.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(showAll ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(allTitle(count))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(allTitle(count))
        .accessibilityIdentifier("all-voices")
        .accessibilityValue(showAll ? "Shown" : "Hidden")
        .accessibilityHint(showAll ? "Hides every voice" : "Shows every voice, by accent and gender")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search by name, accent or language", text: $query)
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #else
                .textFieldStyle(.plain)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel("Search voices")
                .accessibilityIdentifier("voice-search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
            }
        }
    }

    private var noMatch: some View {
        Text("No voice matches \u{201C}\(query)\u{201D}.").font(.callout).foregroundStyle(.secondary)
    }

    private func allTitle(_ count: Int) -> String {
        count == 1 ? "All voices (1)" : "All voices (\(count))"
    }
}

/// One voice to choose (a tap anywhere on its name) and hear (its play button), on both apps:
/// in the suggested voices with its whole name ("Heart, American, female"), and inside a group
/// of All voices by its name alone, the group's title saying the rest.
struct NarratorOptionRow: View {
    let voice: String
    @Binding var chosen: String?
    /// Its preview is playing.
    var playing: Bool
    /// A line under the name.
    var detail: String? = nil
    /// "now", "suggested": a word after the name.
    var tag: String? = nil
    /// Listed under a group's title, so the name alone is shown.
    var inGroup = false
    let onPreview: () -> Void

    var body: some View {
        let entry = VoiceDirectory.entry(voice)
        let selected = chosen == voice
        HStack(spacing: 8) {
            Button {
                chosen = voice
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: selected ? Self.selectedSymbol : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(inGroup ? entry.name : entry.label)
                            if let tag { Text(tag).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([entry.label, tag].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("\(inGroup ? "voice" : "narrator")-\(voice)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: onPreview) {
                Image(systemName: playing ? "stop.circle" : "play.circle").font(Self.playFont)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playing ? "Stop the preview" : "Hear \(entry.label)")
        }
        .font(Self.rowFont)
    }

    #if os(macOS)
    private static let selectedSymbol = "largecircle.fill.circle"
    private static let rowFont: Font = .callout
    private static let playFont: Font = .body
    #else
    private static let selectedSymbol = "checkmark.circle.fill"
    private static let rowFont: Font = .body
    private static let playFont: Font = .title2
    #endif
}
