import BatonPlaybackKit
import BatonSubsonicModels
import SwiftUI

/// "Find More Like This", pointed outward — the phone's half of the same feature the Mac
/// shows in `MusicDiscoveryView`.
///
/// Kept as its own small sheet rather than shared with the Mac's: the two are a `List` with
/// a tappable row and a windowed `List` with a hover-free link button, which is genuinely
/// different chrome. What *is* shared, and is the part that matters, is `ExternalDiscovery`
/// itself — one opt-in, one set of sources, one ranking.
struct MobileDiscoverySheet: View {
    let song: NavidromeSong
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var findings: ExternalDiscovery.Findings?
    @State private var loading = true
    @State private var isOff = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if isOff {
                    // A switch being off is not an error, and must not look like one.
                    ContentUnavailableView(
                        "Looking outside your library is off",
                        systemImage: "binoculars",
                        description: Text("This is the one lookup that talks to a service other "
                                          + "than your own server. Turn it on in Settings.")
                    )
                } else if let findings, findings.suggestions.isEmpty {
                    ContentUnavailableView(
                        "Nothing found",
                        systemImage: "questionmark.circle",
                        description: Text("The public catalogues had nothing for this artist. "
                                          + "That's normal for obscure or mistagged names.")
                    )
                } else if let findings {
                    List {
                        Section {
                            ForEach(findings.suggestions) { suggestion in
                                row(suggestion)
                            }
                        }
                        // Say which sources stayed quiet, so a short list reads as
                        // "two sources are off" rather than "there isn't much out there".
                        if !findings.quietSources.isEmpty {
                            Section("Sources that are off") {
                                ForEach(findings.quietSources, id: \.source) { status in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(status.source.label)
                                        Text(status.detail)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("More like this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task(id: song.id) { await load() }
        }
    }

    @ViewBuilder private func row(_ suggestion: ExternalDiscovery.Suggestion) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(suggestion.title).lineLimit(1)
            HStack(spacing: 6) {
                if let artist = suggestion.artist, !artist.isEmpty {
                    Text(artist).lineLimit(1)
                }
                Text(suggestion.source.label)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let url = suggestion.url {
            Button { openURL(url) } label: {
                HStack {
                    content
                    Spacer()
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary).font(.caption)
                }
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func load() async {
        loading = true
        isOff = false
        do {
            findings = try await ExternalDiscovery.similar(toTitle: song.title, artist: song.artist)
        } catch ExternalDiscovery.Failure.notEnabled {
            isOff = true
            findings = nil
        } catch {
            findings = .init(suggestions: [], quietSources: [])
        }
        loading = false
    }
}
