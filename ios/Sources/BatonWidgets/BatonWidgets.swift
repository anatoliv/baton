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
    /// Filename in the App Group container. Read from disk, not fetched: a widget's
    /// network access is throttled and its body builds synchronously, which is why the
    /// snapshot carried an artwork URL for months while the widget drew a music note.
    var artworkFile: String?
    var updatedAt: Date
}

/// The cover, straight off the shared container.
struct WidgetArtwork: View {
    let file: String?
    var corner: CGFloat = 8

    private var image: UIImage? {
        guard let file,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.io.tonebox.baton")
        else { return nil }
        return UIImage(contentsOfFile: container.appendingPathComponent(file).path)
    }

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: corner))
        } else {
            RoundedRectangle(cornerRadius: corner)
                .fill(.quaternary)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
    }
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: WidgetSnapshot(
            title: "Nothing playing", artist: nil, songID: "", isPlaying: false,
            artworkURL: nil, artworkFile: nil, updatedAt: .now
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
        // The accessory families are the lock screen and StandBy — where a music app is
        // actually glanced at. Shipping only the home-screen sizes meant Baton was absent
        // from every surface someone looks at without unlocking.
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.songID.isEmpty {
            content(snapshot)
                // Not `baton://play/<id>` — that re-plays the track from the start with a
                // one-item queue. The widget shows what is playing; tapping it should take
                // you there, not restart it.
                .widgetURL(URL(string: "baton://player"))
        } else {
            idle
        }
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        switch family {
        // One line, no room for anything but words.
        case .accessoryInline:
            Text("\(snapshot.title) — \(snapshot.artist ?? "")")

        // A ring on the lock screen. The glyph carries the state; there is no space
        // for a title anybody could read.
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: snapshot.isPlaying ? "waveform" : "pause.fill")
                    .font(.title3)
            }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title).font(.headline).lineLimit(1)
                if let artist = snapshot.artist {
                    Text(artist).font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        // Home screen. Cover first — it is what makes a music widget recognisable at a
        // glance — with transport where the size allows.
        case .systemLarge:
            VStack(alignment: .leading, spacing: 10) {
                WidgetArtwork(file: snapshot.artworkFile, corner: 14)
                    .frame(maxWidth: .infinity)
                titles(snapshot, titleFont: .headline)
                transport(snapshot)
            }

        case .systemMedium:
            HStack(spacing: 12) {
                WidgetArtwork(file: snapshot.artworkFile)
                    .frame(width: 64, height: 64)
                titles(snapshot, titleFont: .headline)
                Spacer(minLength: 0)
                transport(snapshot)
            }

        default:
            VStack(alignment: .leading, spacing: 8) {
                WidgetArtwork(file: snapshot.artworkFile)
                    .frame(width: 52, height: 52)
                Spacer(minLength: 0)
                titles(snapshot, titleFont: .subheadline)
            }
        }
    }

    private func titles(_ snapshot: WidgetSnapshot, titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.title).font(titleFont).lineLimit(2)
            if let artist = snapshot.artist {
                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Play/pause and next, run in the app without opening it.
    ///
    /// The `AudioPlaybackIntent`s these call have existed since the Shortcuts work; the
    /// widget just never offered them, so the only way to skip a track from the home
    /// screen was to launch the app and skip it there.
    private func transport(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 14) {
            Button(intent: TogglePlayPauseIntent()) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Next track")
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    private var idle: some View {
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


/// Lock Screen / Dynamic Island now-playing. Static content — the engine updates the
/// activity on every track/pause change, and the system Now Playing controls remain
/// the interactive surface.
struct NowPlayingLiveActivity: Widget {
    /// The window the progress bar animates across, anchored to when this state was
    /// pushed. Clamped to a sane length so a stream reporting a nonsense duration cannot
    /// leave a bar creeping for hours.
    private func progressRange(_ state: NowPlayingActivityAttributes.ContentState) -> ClosedRange<Date> {
        let now = Date()
        let remaining = max(1, min(state.duration - state.elapsed, 60 * 60 * 6))
        return now ... now.addingTimeInterval(remaining)
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            // Quiet on purpose. This sits on someone's lock screen under whatever they
            // chose to look at, and it is telling them something they already know —
            // what is playing. A bold headline at full contrast, a tinted icon, and a
            // second icon repeating the first read as an announcement rather than a
            // label. One muted glyph, plain text, and the artist a step down is enough
            // to be found at a glance and easy to ignore the rest of the time.
            HStack(spacing: 10) {
                WidgetArtwork(file: context.state.artworkFile, corner: 6)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(context.state.artist ?? context.attributes.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    // A bar that moves on its own. Without it the card is only truthful at
                    // the instant it was pushed, and pushing every second to animate a
                    // progress bar is exactly what ActivityKit budgets are there to stop.
                    if context.state.duration > 0 {
                        ProgressView(timerInterval: progressRange(context.state),
                                     countsDown: false)
                            .labelsHidden()
                            .tint(.secondary)
                            .opacity(context.state.isPlaying ? 1 : 0.45)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetArtwork(file: context.state.artworkFile, corner: 6)
                        .frame(width: 40, height: 40)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                // The expanded island is the one place with room for controls, and it is
                // what a long-press on the island is *for*. It had none.
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 28) {
                        Button(intent: PreviousTrackIntent()) {
                            Image(systemName: "backward.fill")
                        }
                        .accessibilityLabel("Previous track")
                        Button(intent: TogglePlayPauseIntent()) {
                            Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .accessibilityLabel(context.state.isPlaying ? "Pause" : "Play")
                        Button(intent: NextTrackIntent()) {
                            Image(systemName: "forward.fill")
                        }
                        .accessibilityLabel("Next track")
                        Button(intent: LikeCurrentTrackIntent()) {
                            Image(systemName: "heart")
                        }
                        .accessibilityLabel("Like this track")
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .frame(maxWidth: .infinity)
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
