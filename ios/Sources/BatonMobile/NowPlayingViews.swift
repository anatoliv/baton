import AVKit
import SwiftUI

/// The floating mini-bar above the tab bar: artwork, title, a live progress
/// hairline, play/pause, next, close. Tapping it opens the full player.
struct NowPlayingBar: View {
    let model: MobileModel
    var onOpen: () -> Void

    var body: some View {
        if let song = model.music.nowPlaying {
            VStack(spacing: 0) {
                // The hairline is the bar's one always-moving element — brand orange,
                // because it's chrome (the *player's* fills are the dynamic accent,
                // per the design doc's Brand ⇄ Dynamic rule).
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * progress), height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 3)
                .padding(.horizontal, 14)

                HStack(spacing: 12) {
                    ArtworkView(url: artworkURL(for: song))
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    VStack(alignment: .leading) {
                        Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        model.music.isPlaying ? model.music.pause() : model.music.resume()
                    } label: {
                        Image(systemName: model.music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel(model.music.isPlaying ? "Pause" : "Play")
                    Button {
                        model.music.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("Next track")
                    // Dismissing the bar means ending the session — it can only disappear
                    // when nothing is playing. Clearing the queue is what the Mac's
                    // equivalent xmark does, so both apps mean the same thing by it.
                    // Not `role: .destructive` — a red X in a mini player reads as "delete
                    // this track", which isn't what it does. Grey reads as dismiss.
                    Button {
                        model.music.clearQueue()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            // Icon-sized hit targets are painful on a moving phone; pad
                            // out to something thumb-sized without growing the bar.
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Stop and close the player")
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 10)
            }
            .background(.bar, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            // Stable handle for the UI audit, and the element VoiceOver
            // lands on when it reaches the mini player.
            .accessibilityIdentifier("NowPlayingBar")
        }
    }

    private var progress: CGFloat {
        let duration = model.music.duration
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, model.music.currentTime / duration)))
    }

    private func artworkURL(for song: NavidromeSong) -> URL? {
        model.musicLibrary.coverArtURL(id: song.coverArtID ?? song.id, size: 120)
    }
}

/// The full player: an immersive dark surface over the artwork-derived
/// `AdaptiveBackdrop`, exactly as the design doc specifies for player context —
/// dynamic accent on the continuous fills and state toggles, breathing artwork,
/// transport, and the queue below. Shares the Mac's palette extractor, so the
/// same cover produces the same accent on both devices.
struct FullPlayerView: View {
    let model: MobileModel
    @Environment(\.dismiss) private var dismiss
    /// Local scrub position while the finger is down, so the slider doesn't fight
    /// the 4 Hz clock updates mid-drag.
    @State private var scrubTime: TimeInterval?
    @State private var showsLyrics = false
    @State private var isEditingQueue = false
    /// Real peaks for the scrubber, when the track is downloaded. A live stream can't be
    /// analysed, so streams keep the capsule — the same rule the Mac follows.
    @State private var waveform: [Float]?
    @State private var paletteLoader = ArtworkPaletteLoader()
    /// Drives the artwork "breathing" (design doc: easeInOut 3.4 s, 0.98↔1.02).
    /// A dedicated animated value, NOT `.animation(value:)` on the view — a
    /// repeatForever transaction attached to the view also captures its slide-in
    /// position from the sheet presentation and replays it forever, which pinned
    /// the artwork to the top-left corner.
    @State private var breatheScale: CGFloat = 0.985

    var body: some View {
        NavigationStack {
            ZStack {
                AdaptiveBackdrop(palette: paletteLoader.palette)

                VStack(spacing: 22) {
                    if let song = model.music.nowPlaying {
                        artwork(for: song)

                        VStack(spacing: 4) {
                            Text(song.title)
                                .font(.title3.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                            Text(song.artist ?? "")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .padding(.horizontal)

                        scrubber
                        transport
                        secondaryControls(for: song)
                        queueList
                    } else {
                        ContentUnavailableView("Nothing playing", systemImage: "music.note")
                    }
                }
                .padding(.top, 12)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .sheet(isPresented: $showsLyrics) {
                if let song = model.music.nowPlaying {
                    LyricsSheet(song: song, model: model)
                }
            }
        }
        // The player is a deliberately immersive dark surface (design doc): its
        // legibility comes from the contrast-corrected accent + the backdrop scrim,
        // not from appearance switching.
        .preferredColorScheme(.dark)
        .task(id: coverURL) { paletteLoader.update(url: coverURL) }
        .task(id: model.music.nowPlaying?.id) { await loadWaveform() }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) {
                breatheScale = 1.0
            }
        }
    }

    /// The palette is extracted at the canonical size so this sheet, the Mac window
    /// and the widgets all derive the same accent for a given track.
    private var progressFraction: Double {
        let duration = model.music.duration
        guard duration > 0 else { return 0 }
        return min(1, max(0, (scrubTime ?? model.music.currentTime) / duration))
    }

    /// Compute the waveform when the current track is on this device. Guards against a
    /// track change mid-load, so a slow analysis can't paint the wrong song's peaks.
    ///
    /// The rule is "local content gets a real waveform, streams get the capsule" — a
    /// stream has no file to analyse and inventing peaks would be a decorative lie about
    /// the audio. Downloads are the usual local case, but a bundled demo track is local
    /// too, so it qualifies on the same grounds.
    private func loadWaveform() async {
        waveform = nil
        guard let song = model.music.nowPlaying, let url = localURL(for: song) else { return }
        let bars = await WaveformExtractor.bars(forSongID: song.id, url: url)
        if model.music.nowPlaying?.id == song.id { waveform = bars }
    }

    private func localURL(for song: NavidromeSong) -> URL? {
        if let downloaded = MusicDownloadStore.shared.localURL(for: song.id) { return downloaded }
        guard MediaKind(id: song.id) == .localFile else { return nil }
        return URL(string: song.id)
    }

    private var coverURL: URL? {
        guard let song = model.music.nowPlaying else { return nil }
        return model.musicLibrary.coverArtURL(
            id: song.coverArtID ?? song.id,
            size: ArtworkColorExtractor.coverSize
        )
    }

    /// The dynamic accent for foreground controls — grayscale art falls back to
    /// brand orange, everything else is lightened until it clears AA contrast.
    private var accent: Color { paletteLoader.palette.uiAccent }

    private func artwork(for song: NavidromeSong) -> some View {
        // Fixed size, not maxWidth/maxHeight: the queue List below is greedy, and a
        // flexible frame lets it squeeze the artwork into a clipped sliver.
        ArtworkView(url: model.musicLibrary.coverArtURL(id: song.coverArtID ?? song.id, size: 800))
            .frame(width: 272, height: 272)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color.playingGlowTint(accent), radius: 24, y: 8)
            .scaleEffect(breatheScale)
            .frame(maxWidth: .infinity)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            if let waveform, waveform.count > 1 {
                WaveformScrubber(
                    bars: waveform,
                    progress: progressFraction,
                    accent: accent,
                    duration: model.music.duration
                ) { fraction in
                    model.music.seek(to: fraction * model.music.duration)
                }
                .frame(height: 44)
            } else {
                Slider(
                    value: Binding(
                        get: { scrubTime ?? model.music.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0 ... max(model.music.duration, 1)
                ) { editing in
                    if !editing, let target = scrubTime {
                        model.music.seek(to: target)
                        scrubTime = nil
                    }
                }
                // Progress is a continuous fill visualizing the playing track —
                // dynamic accent, per the Brand ⇄ Dynamic rule.
                .tint(accent)
            }
            HStack {
                Text(timeString(scrubTime ?? model.music.currentTime))
                Spacer()
                Text(timeString(model.music.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 28)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            // Shuffle/repeat reflect *state*, so they carry the dynamic accent when
            // active; the neutral transport actions stay white.
            Button { model.music.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(model.music.isShuffled ? accent : .white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(model.music.isShuffled ? "Shuffle on" : "Shuffle off")

            Button { model.music.previous() } label: {
                Image(systemName: "backward.fill").font(.title).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Previous track")

            Button {
                model.music.isPlaying ? model.music.pause() : model.music.resume()
            } label: {
                Image(systemName: model.music.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(model.music.isPlaying ? "Pause" : "Play")

            Button { model.music.next() } label: {
                Image(systemName: "forward.fill").font(.title).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Next track")

            Button { model.music.cycleRepeat() } label: {
                Image(systemName: model.music.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(model.music.repeatMode == .off ? .white.opacity(0.6) : accent)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Repeat \(model.music.repeatMode.rawValue)")
        }
        .padding(.horizontal, 16)
    }

    /// Like, lyrics, AirPlay, sleep — the row under the transport. On the Mac these
    /// live across the expanded bar; the phone gathers them where the thumb is.
    private func secondaryControls(for song: NavidromeSong) -> some View {
        HStack(spacing: 0) {
            // Like drives a server-side star; in demo mode there is no server, so
            // showing a heart that silently reverts would be worse than none.
            if !model.isDemoMode {
                Button {
                    Task { await model.musicLibrary.toggleLike(song) }
                } label: {
                    let liked = model.musicLibrary.isLiked(song)
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? accent : .white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Like")
            }

            if !model.isDemoMode {
                Menu {
                    ForEach((1 ... 5).reversed(), id: \.self) { stars in
                        Button {
                            Task { await model.musicLibrary.setRating(song, rating: stars) }
                        } label: { Label(String(repeating: "★", count: stars), systemImage: "star") }
                    }
                    Button {
                        Task { await model.musicLibrary.setRating(song, rating: 0) }
                    } label: { Label("Clear rating", systemImage: "star.slash") }
                } label: {
                    let rating = model.musicLibrary.rating(song)
                    Image(systemName: rating > 0 ? "star.fill" : "star")
                        .foregroundStyle(rating > 0 ? accent : .white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Rate")
            }

            Button { showsLyrics = true } label: {
                Image(systemName: "quote.bubble").foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Lyrics")

            AirPlayButton()
                .frame(width: 44, height: 24)
                .frame(maxWidth: .infinity)

            sleepMenu
                .frame(maxWidth: .infinity)
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 40)
    }

    private var sleepMenu: some View {
        Menu {
            if model.music.sleepTimerArmed {
                Button("Cancel sleep timer", role: .destructive) { model.music.cancelSleepTimer() }
            }
            Button("In 15 minutes") { model.music.setSleepTimer(minutes: 15) }
            Button("In 30 minutes") { model.music.setSleepTimer(minutes: 30) }
            Button("In 1 hour") { model.music.setSleepTimer(minutes: 60) }
            Button("After this track") { model.music.sleepAtEndOfTrack() }
        } label: {
            Image(systemName: model.music.sleepTimerArmed ? "moon.zzz.fill" : "moon.zzz")
                .foregroundStyle(model.music.sleepTimerArmed ? accent : .white.opacity(0.6))
        }
        .accessibilityLabel("Sleep timer")
    }

    private var queueList: some View {
        List {
            Section {
                let queue = model.music.queue
                ForEach(Array(queue.enumerated()), id: \.element.id) { index, song in
                    HStack {
                        Text(song.title).lineLimit(1)
                            .foregroundStyle(index == model.music.currentIndex ? accent : .white)
                        Spacer()
                        Text(song.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.music.jump(to: index) }
                    .listRowBackground(
                        index == model.music.currentIndex
                            ? Color.nowPlayingRowTint(accent)
                            : Color.clear
                    )
                    .songContextMenu(song, model: model)
                }
                // Reordering and removal are the two things a queue is for. The engine
                // has had both since the Mac shipped; the phone just never offered them.
                .onMove { source, destination in
                    model.music.moveQueueItem(from: source, to: destination)
                }
                .onDelete { offsets in
                    model.music.removeFromQueue(at: offsets)
                }
            } header: {
                HStack {
                    Text("Up Next").foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button(isEditingQueue ? "Done" : "Edit") { isEditingQueue.toggle() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(isEditingQueue ? .active : .inactive))
        // The backdrop paints the surface; the list must not repaint it opaque.
        .scrollContentBackground(.hidden)
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The system AirPlay route picker — the same control the Mac's bar exposes,
/// wrapped for SwiftUI. White to sit on the dark player surface.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = UIColor(Color.batonOrange)
        view.tintColor = UIColor.white.withAlphaComponent(0.6)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Lyrics for the current track — synced lines highlight and auto-scroll with the
/// engine clock (tap a line to seek); plain lyrics just scroll.
struct LyricsSheet: View {
    let song: NavidromeSong
    let model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: NavidromeLyrics?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if let lyrics {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                                    Text(line.text.isEmpty ? " " : line.text)
                                        .font(.title3.weight(currentIndex == index ? .bold : .regular))
                                        .foregroundStyle(currentIndex == index ? .primary : .secondary)
                                        .id(index)
                                        .onTapGesture {
                                            if let start = line.start { model.music.seek(to: start) }
                                        }
                                }
                            }
                            .padding()
                        }
                        .onChange(of: currentIndex) { _, index in
                            guard let index, lyrics.synced else { return }
                            withAnimation { proxy.scrollTo(index, anchor: .center) }
                        }
                    }
                } else if loaded {
                    ContentUnavailableView("No lyrics for this track", systemImage: "quote.bubble")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(song.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                lyrics = await model.musicLibrary.lyrics(for: song.id)
                loaded = true
            }
        }
    }

    /// The line the playhead is inside, for synced lyrics.
    private var currentIndex: Int? {
        guard let lyrics, lyrics.synced else { return nil }
        let time = model.music.currentTime
        var current: Int?
        for (index, line) in lyrics.lines.enumerated() {
            if let start = line.start, start <= time { current = index } else if line.start ?? 0 > time { break }
        }
        return current
    }
}


/// A waveform scrubber: real peaks for the played and unplayed halves, drag to seek.
///
/// Only shown for downloaded tracks — a stream has no file to analyse, and drawing
/// invented peaks would be a decorative lie about the audio.
private struct WaveformScrubber: View {
    let bars: [Float]
    let progress: Double
    let accent: Color
    let duration: TimeInterval
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = dragFraction ?? progress
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, peak in
                    let fraction = Double(index) / Double(max(bars.count - 1, 1))
                    Capsule()
                        .fill(fraction <= shown ? accent : Color.white.opacity(0.28))
                        .frame(height: max(3, CGFloat(peak) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = min(1, max(0, value.location.x / geo.size.width))
                    }
                    .onEnded { value in
                        let fraction = min(1, max(0, value.location.x / geo.size.width))
                        dragFraction = nil
                        onSeek(fraction)
                    }
            )
        }
    }
}
