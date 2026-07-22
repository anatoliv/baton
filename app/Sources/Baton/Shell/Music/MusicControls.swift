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
    /// Cursor x within the track while hovering — drives the "seek to" time bubble.
    @State private var hoverX: CGFloat?
    @State private var scroll = ScrollAdjustRelay()

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
        // Keep the scroll relay pinned to live state each render (±5s per detent).
        scroll.sync(currentTime, lower: 0, upper: max(duration, 0), step: 5, onSet: onSeek)
        return VStack(spacing: 5) {
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
                .scrollWheelAdjust { if duration > 0 { scroll.tick($0) } } // scroll to seek ±5s
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
                // Hover preview: the time you'd seek to, floating above the cursor.
                .onContinuousHover { phase in
                    guard duration > 0 else { hoverX = nil; return }
                    switch phase {
                    case let .active(point): hoverX = min(max(point.x, 0), width)
                    case .ended: hoverX = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hoverX, dragProgress == nil, duration > 0 {
                        Text(Self.time((hoverX / max(width, 1)) * duration))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                            .offset(x: hoverX - 16, y: -22)
                            .allowsHitTesting(false)
                    }
                }
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
        // VoiceOver: one adjustable element (the custom drag track has no built-in a11y). Rotor
        // up/down seeks ±10s; the value reads elapsed-of-total.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(duration > 0 ? "\(Self.time(shownTime)) of \(Self.time(duration))" : "No track")
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            switch direction {
            case .increment: onSeek(min(currentTime + 10, duration))
            case .decrement: onSeek(max(currentTime - 10, 0))
            @unknown default: break
            }
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

    @State private var scroll = ScrollAdjustRelay()

    private var showSlash: Bool { isMuted || percent == 0 }
    /// The filled portion — collapsed to a stub while muted so the mute state reads.
    private var fillFraction: CGFloat { isMuted ? 0 : CGFloat(percent) / 100 }

    var body: some View {
        // Keep the scroll relay pinned to live state each render (±2% per detent).
        scroll.sync(Double(percent), lower: 0, upper: 100, step: 2) { onChange(Int($0)) }
        return HStack(spacing: 7) {
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
            .accessibilityLabel(isMuted ? "Unmute" : "Mute")

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
            .scrollWheelAdjust { scroll.tick($0) } // scroll over the slider to change volume
            // VoiceOver: rotor up/down adjusts volume ±5%.
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(percent)%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(min(percent + 5, 100))
                case .decrement: onChange(max(percent - 5, 0))
                @unknown default: break
                }
            }
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

// MARK: - Scroll-wheel adjustment

import AppKit

/// Adjusts a value by the scroll wheel while the cursor is over a control — the standard macOS
/// convention that custom (non-AppKit) sliders otherwise lack. A hover-scoped local event monitor
/// forwards wheel deltas to `onTick(dir)` (±1 per detent), consuming them so a parent scroll view
/// doesn't also move. Precise (trackpad) deltas are accumulated to a threshold; mouse notches step
/// directly. `onTick` should apply against a reference holder so it reads live state, not a stale
/// capture (see `MusicVolumeControl` / `MusicScrubber`).
struct ScrollWheelAdjust: ViewModifier {
    let onTick: (Int) -> Void
    @State private var monitor: Any?
    @State private var accum: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        handle(event)
                        return nil // consume — don't also scroll an ancestor
                    }
                } else if !inside {
                    removeMonitor()
                }
            }
            .onDisappear { removeMonitor() }
    }

    private func handle(_ event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            accum += event.scrollingDeltaY
            let step: CGFloat = 10
            while abs(accum) >= step {
                let dir = accum > 0 ? 1 : -1
                accum -= CGFloat(dir) * step
                onTick(event.isDirectionInvertedFromDevice ? -dir : dir)
            }
        } else {
            let raw = event.deltaY
            guard raw != 0 else { return }
            let dir = raw > 0 ? 1 : -1
            onTick(event.isDirectionInvertedFromDevice ? -dir : dir)
        }
    }

    private func removeMonitor() {
        accum = 0
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Scroll-wheel over this control emits ±1 detents to `onTick`.
    func scrollWheelAdjust(_ onTick: @escaping (Int) -> Void) -> some View {
        modifier(ScrollWheelAdjust(onTick: onTick))
    }
}

/// A stable reference the scroll monitor calls into. `sync(...)` is called each render to reset the
/// working value to the live truth; `tick(dir)` then accumulates from there, so multiple detents in
/// one gesture (before the next render) compound correctly instead of all computing off a stale base.
@MainActor final class ScrollAdjustRelay {
    private var value = 0.0
    private var lower = 0.0
    private var upper = 100.0
    private var step = 1.0
    private var onSet: (Double) -> Void = { _ in }

    func sync(_ v: Double, lower: Double, upper: Double, step: Double, onSet: @escaping (Double) -> Void) {
        value = v; self.lower = lower; self.upper = upper; self.step = step; self.onSet = onSet
    }

    func tick(_ dir: Int) {
        value = min(max(value + Double(dir) * step, lower), upper)
        onSet(value)
    }
}
