import ActivityKit
import SwiftUI
import WidgetKit

/// The Now Playing widget: what's on, tap to open the app (deep-linked to the
/// playing song). Reads only the App-Group snapshot the app publishes — this
/// process never sees credentials or the library.
@main
struct BatonWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        NowPlayingLiveActivity()
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Local copy of the bridge's snapshot shape (widget targets don't share the app's
/// module; the JSON contract is the interface).
struct WidgetSnapshot: Codable {
    var title: String
    var artist: String?
    var songID: String
    var isPlaying: Bool
    var artworkURL: URL?
    var updatedAt: Date
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: WidgetSnapshot(
            title: "Nothing playing", artist: nil, songID: "", isPlaying: false, artworkURL: nil, updatedAt: .now
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, snapshot: read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // The app reloads this timeline on every track change; the entry itself
        // never needs future dates.
        completion(Timeline(entries: [NowPlayingEntry(date: .now, snapshot: read())], policy: .never))
    }

    private func read() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: "group.io.tonebox.baton")?.data(forKey: "baton.widget.nowPlaying")
        else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BatonNowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("What Baton is playing.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.songID.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: snapshot.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(2)
                if let artist = snapshot.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .widgetURL(URL(string: "baton://play/\(snapshot.songID)"))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Nothing playing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


/// Lock Screen / Dynamic Island now-playing. Static content — the engine updates the
/// activity on every track/pause change, and the system Now Playing controls remain
/// the interactive surface.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            HStack(spacing: 10) {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                    Text(context.state.artist ?? context.attributes.sourceLabel)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "music.note")
            }
            .padding(14)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
            } compactTrailing: {
                Image(systemName: "music.note")
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}
