import BatonPlaybackKit
import BatonSubsonicModels
import SwiftUI

/// "Find more like this", pointed outward.
///
/// The sibling of Start Radio: same question, different range. Radio fills the queue from
/// the library; this lists what exists that the library hasn't got, with a link wherever the
/// source gives one — because a suggestion you then have to go and search for yourself is
/// only half an answer.
struct MusicDiscoveryView: View {
    let song: NavidromeSong
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var findings: ExternalDiscovery.Findings?
    @State private var loading = true
    @State private var refused: ExternalDiscovery.Failure?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 420)
        .task(id: song.id) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("More like \(DisplayName.title(song.title))")
                .font(.headline)
            if let artist = DisplayName.artist(song.artist) {
                Text("Looking outside your library, from \(artist)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if refused == .notEnabled {
            // Not an error state. Nothing went wrong; a switch is off.
            VStack(spacing: 10) {
                Image(systemName: "binoculars").font(.largeTitle).foregroundStyle(.secondary)
                Text("Looking outside your library is off")
                    .font(.headline)
                Text("This is the one lookup that talks to a service other than your own "
                     + "server. Turn it on in Settings, Playback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if let findings, findings.suggestions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("The catalogues had nothing for this artist")
                    .foregroundStyle(.secondary)
                Text("Normal for very obscure or mistagged names.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let findings {
            List(findings.suggestions) { suggestion in
                row(suggestion)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ suggestion: ExternalDiscovery.Suggestion) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
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
            Spacer()
            if let url = suggestion.url {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open at \(suggestion.source.label)")
            }
        }
        .padding(.vertical, 2)
    }

    /// Says which sources stayed quiet, so a short list reads as "two sources are off"
    /// rather than "there isn't much out there".
    ///
    /// The quiet-source note sits *beside* Done rather than instead of it. An earlier
    /// version swapped one for the other, which meant the common case — YouTube and Last.fm
    /// both unconfigured — was a sheet with no way to close it.
    private var footer: some View {
        HStack(alignment: .bottom) {
            if let findings, !findings.quietSources.isEmpty, refused == nil {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(findings.quietSources, id: \.source) { status in
                        Text("\(status.source.label): \(status.detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func load() async {
        loading = true
        refused = nil
        do {
            findings = try await ExternalDiscovery.similar(toTitle: song.title, artist: song.artist)
        } catch let failure as ExternalDiscovery.Failure {
            refused = failure
            findings = nil
        } catch {
            findings = .init(suggestions: [], quietSources: [])
        }
        loading = false
    }
}
