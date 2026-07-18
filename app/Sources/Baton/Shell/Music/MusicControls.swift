import SwiftUI

/// A custom progress scrubber — a thin rounded track with a draggable knob and
/// elapsed / remaining time labels. Custom-drawn (no AppKit `Slider`) so it looks
/// premium AND renders in snapshots. Shows real time from `currentTime`/`duration`.
struct MusicScrubber: View {
    let currentTime: Double
    let duration: Double
    var tint: Color = .white
    /// Normalized amplitude bars (0…1) for a real waveform — supplied for downloaded
    /// tracks; nil renders the plain capsule track (streams can't be analyzed).
    var waveform: [Float]?
    var onSeek: (Double) -> Void

    @State private var dragProgress: Double?

    private var progress: Double {
        if let dragProgress { return dragProgress }
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private var shownTime: Double {
        if let dragProgress { return dragProgress * duration }
        return currentTime
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                Group {
                    if let waveform, !waveform.isEmpty {
                        waveformTrack(waveform, width: width)
                    } else {
                        capsuleTrack(width: width)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragProgress = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard duration > 0 else { return }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            onSeek(fraction * duration)
                            dragProgress = nil
                        }
                )
            }
            .frame(height: waveform == nil ? 16 : 30)

            HStack {
                Text(Self.time(shownTime))
                Spacer()
                Text("-" + Self.time(max(0, duration - shownTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint.opacity(0.75))
        }
    }

    @ViewBuilder private func capsuleTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(tint.opacity(0.22)).frame(height: 4)
            Capsule().fill(tint).frame(width: max(0, width * progress), height: 4)
            Circle().fill(tint)
                .frame(width: dragProgress == nil ? 11 : 15, height: dragProgress == nil ? 11 : 15)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .offset(x: max(0, width * progress) - (dragProgress == nil ? 5.5 : 7.5))
                .animation(.easeOut(duration: 0.12), value: dragProgress == nil)
        }
    }

    private func waveformTrack(_ bars: [Float], width: CGFloat) -> some View {
        Canvas { ctx, size in
            let n = bars.count
            let gap: CGFloat = 1.5
            let barW = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let playedTo = progress * Double(n)
            for (i, amp) in bars.enumerated() {
                let h = max(2, CGFloat(amp) * size.height)
                let x = CGFloat(i) * (barW + gap)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                let color = Double(i) <= playedTo ? tint : tint.opacity(0.28)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(color))
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Compact custom volume control — mute-toggle icon + thin custom slider, adjustable
/// by drag/click. Renders in snapshots.
struct MusicVolumeControl: View {
    let percent: Int
    var isMuted: Bool = false
    var tint: Color = .primary
    var onChange: (Int) -> Void
    /// Optional mute toggle. When nil the speaker icon is inert (legacy callers).
    var onToggleMute: (() -> Void)?

    private var showSlash: Bool { isMuted || percent == 0 }
    /// The filled portion — collapsed to a stub while muted so the mute state reads.
    private var fillFraction: CGFloat { isMuted ? 0 : CGFloat(percent) / 100 }

    var body: some View {
        HStack(spacing: 7) {
            Button { onToggleMute?() } label: {
                Image(systemName: showSlash ? "speaker.slash.fill" : "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(tint.opacity(isMuted ? 1 : 0.7))
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onToggleMute == nil)
            .help(isMuted ? "Unmute" : "Mute")

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.2)).frame(height: 4)
                    Capsule().fill(tint.opacity(0.9)).frame(width: width * fillFraction, height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        onChange(Int(min(max(value.location.x / width, 0), 1) * 100))
                    }
                )
            }
            .frame(height: 14)
        }
    }
}

/// Shared sleep-timer durations + labels, so the moon menu and the Playback menu
/// offer the same choices.
enum SleepTimerOptions {
    static let minutes = [15, 30, 45, 60, 120, 180]

    static func label(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }
}

/// Sleep-timer menu (moon icon): fixed durations, "end of track", or off. The moon
/// fills + tints accent when a timer is armed. Shared by the full-screen and bottom
/// players so a sleep timer is always reachable.
struct SleepTimerMenu: View {
    @Environment(MusicModel.self) private var model
    var font: Font = .title3
    var tint: Color = .secondary

    private var player: StreamingPlaybackController { model.music }

    var body: some View {
        Menu {
            ForEach(SleepTimerOptions.minutes, id: \.self) { minutes in
                Button(SleepTimerOptions.label(minutes)) { player.setSleepTimer(minutes: minutes) }
            }
            Button("End of track") { player.sleepAtEndOfTrack() }
            if player.sleepTimerArmed {
                Divider()
                Button("Turn off sleep timer", role: .destructive) { player.cancelSleepTimer() }
            }
        } label: {
            Image(systemName: player.sleepTimerArmed ? "moon.fill" : "moon")
                .font(font)
                .foregroundStyle(player.sleepTimerArmed ? Color.accentColor : tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sleep timer")
    }
}

/// A prominent, easy-to-hit like + 5-star rating cluster for the now-playing
/// surfaces. Larger tap targets than the row control.
struct MusicRatingCluster: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    var tint: Color = .white

    var body: some View {
        let liked = model.musicLibrary.isLiked(song)
        let rating = model.musicLibrary.rating(song)
        HStack(spacing: 18) {
            Button { Task { await model.musicLibrary.toggleLike(song) } } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(liked ? Color.pink : tint.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(liked ? "Unlike" : "Like")

            HStack(spacing: 6) {
                ForEach(1 ... 5, id: \.self) { star in
                    Button {
                        Task { await model.musicLibrary.setRating(song, rating: rating == star ? 0 : star) }
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.body)
                            .foregroundStyle(star <= rating ? Color.yellow : tint.opacity(0.55))
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rate \(star)")
                }
            }
        }
    }
}
