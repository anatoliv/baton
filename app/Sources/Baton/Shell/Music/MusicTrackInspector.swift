import SwiftUI

/// The **track inspector** — a "Get Info" sheet surfacing the technical + library metadata a
/// self-hosted FLAC library owner actually cares about: codec, bitrate, bit depth, sample rate,
/// channels, size, play count, last played, and (when downloaded) the on-disk path. All fields read
/// straight off `NavidromeSong`; nothing is fetched or invented. Opened via ⌘I or a row's "Get Info".
struct MusicTrackInspector: View {
    let song: NavidromeSong
    @Environment(\.dismiss) private var dismiss

    private var downloadPath: String? {
        MusicDownloadStore.shared.localURL(for: song.id)?.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Track") {
                        row("Title", song.title)
                        row("Artist", song.displayArtistName)
                        row("Album", song.album)
                        row("Genre", genreText)
                        row("Year", song.year.map(String.init))
                        row("Track", trackDiscText)
                        row("Duration", song.duration.map(Self.duration))
                        row("BPM", song.bpm.map(String.init))
                    }
                    section("Quality") {
                        row("Format", formatText)
                        row("Bitrate", song.bitRate.map { "\($0) kbps" })
                        row("Bit depth", song.bitDepth.map { "\($0)-bit" })
                        row("Sample rate", song.samplingRate.map { String(format: "%.1f kHz", Double($0) / 1000) })
                        row("Channels", channelsText)
                        row("Size", song.size.map(Self.byteSize))
                    }
                    section("Library") {
                        row("Play count", song.playCount.map(String.init))
                        row("Last played", song.played.map { $0.formatted(date: .abbreviated, time: .shortened) })
                        row("Rating", song.userRating.map { String(repeating: "★", count: $0) })
                        row("MusicBrainz ID", song.musicBrainzID)
                        if let comment = song.comment, !comment.isEmpty { row("Comment", comment) }
                    }
                    if let downloadPath {
                        section("Downloaded") {
                            pathRow(downloadPath)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 520)
    }

    private var header: some View {
        HStack {
            Image(systemName: "info.circle").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.headline).lineLimit(1)
                Text(song.displayArtistName ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Rows

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) { rows() }
        }
    }

    /// A label/value row — omitted entirely when the value is missing, so empty fields don't clutter.
    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).font(.callout).foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(value).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The on-disk path — selectable, with a "Reveal in Finder" affordance.
    private func pathRow(_ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Path").font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(path).font(.callout.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain).foregroundStyle(.tint).help("Reveal in Finder")
        }
    }

    // MARK: - Derived text

    private var genreText: String? {
        if !song.genres.isEmpty { return song.genres.joined(separator: ", ") }
        return song.genre
    }

    private var trackDiscText: String? {
        switch (song.track, song.discNumber) {
        case let (t?, d?): "\(t) (disc \(d))"
        case let (t?, nil): String(t)
        default: nil
        }
    }

    private var formatText: String? {
        song.suffix?.uppercased() ?? song.contentType
    }

    private var channelsText: String? {
        switch song.channelCount {
        case 1: "Mono"
        case 2: "Stereo"
        case let c?: "\(c) channels"
        default: nil
        }
    }

    static func duration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    static func byteSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
