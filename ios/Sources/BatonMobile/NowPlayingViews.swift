import AVKit
import BatonSubsonicModels
import BatonPlaybackKit
import SwiftUI

/// The floating mini-bar above the tab bar: artwork, title, a live progress
/// hairline, play/pause, next, close. Tapping it opens the full player.
struct NowPlayingBar: View {
    /// Who draws the container.
    ///
    /// iOS 26's `tabViewBottomAccessory` supplies its own capsule, with its own stroke and
    /// material. Drawing a second background inside it put a 16pt-radius rectangle on top of
    /// a fully-rounded capsule: the stroke showed through along the top and bottom, and the
    /// capsule's round ends stayed unpainted. On iOS 18-25 there is no system container, so
    /// the bar has to draw its own.
    enum Chrome {
        /// Hosted in the system accessory — contribute content only.
        case systemAccessory
        /// Floating above the tab bar on its own — draw the capsule.
        case standalone
    }

    let model: MobileModel
    var chrome: Chrome = .standalone
    /// True while the system accessory is in its *inline* placement — docked
    /// beside a minimized tab bar with roughly two-thirds of the expanded
    /// width. The bar sheds next and close and keeps artwork, title and
    /// play/pause, so the title still has room to be a title. Meaningless
    /// (and always false) for `.standalone` chrome.
    var compact: Bool = false
    var onOpen: () -> Void

    /// Artwork size.
    ///
    /// Measured against the accessory rather than guessed: the system capsule renders about
    /// 46pt tall, so its end caps are arcs of radius ~23. A near-full-height square placed
    /// at the leading inset has its corners *outside* that arc — which is what made the
    /// tile look like it was sitting on top of the stroke, with the rounded end missing.
    /// A shorter tile sits inside the curve.
    private var artworkSide: CGFloat { chrome == .systemAccessory ? 30 : 42 }

    /// Horizontal inset. A capsule curves away at the ends, so content needs to start
    /// further in than a rectangle would require — roughly the cap radius.
    private var sideInset: CGFloat { chrome == .systemAccessory ? 22 : 14 }

    var body: some View {
        if let song = model.music.nowPlaying {
            VStack(spacing: 0) {
                // The hairline is the bar's one always-moving element — brand orange,
                // because it's chrome (the *player's* fills are the dynamic accent,
                // per the design doc's Brand ⇄ Dynamic rule).
                //
                // Standalone only: the system accessory is a single short row, and a
                // second row is what pushed the content out of its capsule.
                if chrome == .standalone {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(4, geo.size.width * progress), height: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, sideInset)
                }

                HStack(spacing: 12) {
                    ArtworkView(url: artworkURL(for: song))
                        .frame(width: artworkSide, height: artworkSide)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    VStack(alignment: .leading) {
                        Text(DisplayName.title(song.title)).font(.subheadline.weight(.medium)).lineLimit(1)
                        if let artist = DisplayName.artist(song.artist) {
                            Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    // 44pt hit targets. These were the glyph's own ~20pt, which is a
                    // coin-sized target on a bus — and the mini bar is precisely where
                    // people tap without looking. The bar's height doesn't grow: the
                    // frame is the touch area, not the drawing.
                    Button {
                        model.music.isPlaying ? model.music.pause() : model.music.resume()
                    } label: {
                        Image(systemName: model.music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(model.music.isPlaying ? "Pause" : "Play")
                    .sensoryFeedback(.impact(weight: .light), trigger: model.music.isPlaying)
                    if !compact {
                        Button {
                            model.music.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Next track")
                        .sensoryFeedback(.selection, trigger: model.music.nowPlaying?.id)
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
                }
                .padding(.horizontal, sideInset)
                // The accessory sizes itself to its content, so vertical padding here is
                // what decides its height. Keep it tight: anything taller than the system
                // capsule expects spills past the stroke.
                .padding(.vertical, chrome == .systemAccessory ? 4 : 0)
                .padding(.top, chrome == .standalone ? 7 : 0)
                .padding(.bottom, chrome == .standalone ? 10 : 0)
            }
            // The system accessory already provides material, stroke and shape.
            .modifier(NowPlayingBarChrome(chrome: chrome))
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

/// Draws the bar's own container, or nothing when the system already did.
private struct NowPlayingBarChrome: ViewModifier {
    let chrome: NowPlayingBar.Chrome

    func body(content: Content) -> some View {
        switch chrome {
        case .systemAccessory:
            // Nothing: a background here lands *inside* the system capsule and covers
            // its stroke, while leaving the rounded ends bare.
            content
        case .standalone:
            // Capsule, not a rounded rectangle — it sits free above the tab bar and the
            // ends should be fully round, which is what the system accessory looks like.
            content
                .bottomChromeCapsule()
        }
    }
}

/// The full player: an immersive dark surface over the artwork-derived
/// `AdaptiveBackdrop`, exactly as the design doc specifies for player context —
/// dynamic accent on the continuous fills and state toggles, breathing artwork,
/// transport, and the queue below. Shares the Mac's palette extractor, so the
/// same cover produces the same accent on both devices.
struct FullPlayerView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The hero cover, *shrinking* as text grows.
    ///
    /// This was `@ScaledMetric`, which was exactly backwards: that scales a value **up**
    /// with the text size, so at accessibility sizes it made a 272pt cover into something
    /// wider than the phone — the artwork was clipped off both edges and the title with it,
    /// and the transport was pushed further down rather than nearer. The UI test caught it
    /// with a screenshot; the assertion alone would only have said "still unreachable".
    ///
    /// The relationship is inverse: bigger text needs *more* room for text, which has to
    /// come from the one element that is decoration. Clamped to the screen too, so it can
    /// never exceed the width available whatever the setting.
    private func heroArtworkSide(for width: CGFloat) -> CGFloat {
        let base: CGFloat = dynamicTypeSize.isAccessibilitySize ? 180 : 272
        return min(base, max(120, width - 48))
    }

    let model: MobileModel
    @Environment(\.dismiss) private var dismiss
    /// Local scrub position while the finger is down, so the slider doesn't fight
    /// the 4 Hz clock updates mid-drag.
    @State private var scrubTime: TimeInterval?
    @State private var showsLyrics = false
    @State private var showsTranscript = false
    @State private var showsRelated = false
    @State private var showsQueue = false
    @AppStorage("baton.player.showsRemaining") private var showsRemainingTime = false
    // `isEditingQueue` removed: declared, never read, never set. Up Next has used
    // swipe-to-delete and drag-to-reorder since it moved to its own screen, so there was
    // no edit mode for it to track.
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

                // Scrollable. The fixed VStack fitted at the default text size and at
                // nothing above it: at the largest accessibility size the labels grow, the
                // rows grow with them, and the transport left the screen entirely — the
                // controls, not the decoration. Scrolling costs nothing at normal sizes
                // (the content still fits) and is the difference between usable and not
                // at the top of the range.
                // Measured so the stack can *distribute* its slack instead of pooling it.
                //
                // The content used to be pinned to the top of the scroll view with a fixed
                // 12pt inset and nothing at all underneath it. That reads as a broad empty
                // band between the collapse chevron and the artwork while the last control —
                // the star rating — sits on the bottom edge with the home indicator running
                // through it. Both halves of that are fixed here: the content is given a
                // minimum height of the viewport and centred inside it, so when it fits, the
                // spare room is shared top and bottom rather than all landing in one place;
                // and it carries real padding at the bottom, which is what the overflowing
                // case (a small phone, or a large text size) actually needed.
                GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 22) {
                    if let song = model.music.nowPlaying {
                        artwork(for: song)

                        VStack(spacing: 4) {
                            Text(DisplayName.title(song.title))
                                .font(.title3.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                            // Absent, not blank. An `Text("")` still takes its frame and the
                            // stack's spacing, so a placeholder artist left a gap where the
                            // word "Unknown" had been — which reads as a layout bug rather
                            // than as a track that simply has no artist.
                            if let artist = DisplayName.artist(song.artist) {
                                Text(artist)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .padding(.horizontal)
                        // Long-press the title for everything a song row offers —
                        // including Go to Album / Go to Artist, which dismiss this sheet
                        // and open the target (RootTabView handles the handover).
                        .songContextMenu(song, model: model)

                        scrubber
                        transport
                        volumeRow
                        secondaryControls(for: song)
                        // The stars are five targets wide, so they get their own line
                        // rather than squeezing the icon row.
                        if !model.isDemoMode {
                            MobileStarRating(
                                rating: model.musicLibrary.rating(song),
                                tint: accent
                            ) { stars in
                                Task { await model.musicLibrary.setRating(song, rating: stars) }
                            }
                        }
                    } else {
                        ContentUnavailableView("Nothing playing", systemImage: "music.note")
                    }
                    }
                    // The trailing `Spacer(minLength: 0)` that used to close this stack did
                    // nothing: a scroll view proposes no height, so the spacer took its
                    // minimum and the content still ended flush against the last control.
                    // Padding is the thing that actually reserves room.
                    .padding(.top, 8)
                    // Roughly a home indicator's worth. The safe area already keeps content
                    // out of the indicator itself; this is the gap *above* it, so the last
                    // row reads as the end of the stack rather than as something the screen
                    // ran out of room for.
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity,
                           minHeight: viewport.size.height,
                           alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
                }
                .accessibilityIdentifier("FullPlayerContent")
            }
            .toolbar {
                // A chevron, not "Done", and leading rather than trailing.
                //
                // "Done" means *I have finished a task* — it belongs on a form or an edit
                // mode. Nothing is committed here: the music keeps playing and the player
                // shrinks back into the mini bar it came from. The queue sheet next door
                // uses "Done" for its Edit mode, so the same word meant two things two taps
                // apart. The Mac has always collapsed this view with `chevron.down`; this
                // is the same affordance, and the one Apple Music and Spotify teach.
                //
                // Leading, because trailing is where actions live and dismissal is
                // navigation. 44pt frame for the same reason the mini bar's buttons got one.
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("Minimize player")
                }
            }
            .sheet(isPresented: $showsQueue) {
                QueueSheet(model: model, accent: accent)
            }
            .sheet(isPresented: $showsRelated) {
                if let song = model.music.nowPlaying {
                    RelatedSheet(song: song, model: model)
                }
            }
            .sheet(isPresented: $showsLyrics) {
                if let song = model.music.nowPlaying {
                    LyricsSheet(song: song, model: model)
                }
            }
            .sheet(isPresented: $showsTranscript) {
                if let song = model.music.nowPlaying {
                    TranscriptSheet(song: song, model: model)
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
        // Measured, not assumed: the clamp needs the real width to keep the cover on screen
        // on every device from an SE to a Max.
        let side = heroArtworkSide(for: UIScreen.main.bounds.width)
        return artworkBody(for: song, side: side)
    }

    private func artworkBody(for song: NavidromeSong, side: CGFloat) -> some View {
        // Fixed size, not maxWidth/maxHeight: the queue List below is greedy, and a
        // flexible frame lets it squeeze the artwork into a clipped sliver.
        ArtworkView(url: model.musicLibrary.coverArtURL(id: song.coverArtID ?? song.id, size: 800), wholeCover: true)
            // Shrinks as text grows. At the largest accessibility sizes a fixed 272pt
            // cover plus grown labels and two rows of controls simply does not fit a
            // phone, and what fell off the bottom was the transport.
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color.playingGlowTint(accent), radius: 24, y: 8)
            // The heart belongs to the artwork, as it does on the Mac — a corner badge on
            // the cover rather than one more grey glyph in a row of five. Applied after
            // the clip so it sits on the corner of the image; inside the scale effect so
            // it breathes with the cover instead of drifting away from it.
            .overlay(alignment: .bottomTrailing) {
                if !model.isDemoMode {
                    let liked = model.musicLibrary.isLiked(song)
                    Button {
                        Task { await model.musicLibrary.toggleLike(song) }
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 15, weight: .semibold, design: .default))
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(liked ? accent : .white)
                            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(liked ? "Remove from Liked" : "Like")
                }
            }
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
                // What the stream actually is — "FLAC · 1017 kbps". The Mac has carried
                // this in its Track Inspector all along; on the phone the person on good
                // headphones had no way to know whether they were hearing the real file.
                if let quality = qualityLine {
                    Text(quality)
                }
                Spacer()
                // Total by default; tap for time remaining. Both answers to "how long",
                // and different people want different ones.
                Button {
                    showsRemainingTime.toggle()
                } label: {
                    Text(showsRemainingTime
                         ? "-" + timeString(max(model.music.duration - (scrubTime ?? model.music.currentTime), 0))
                         : timeString(model.music.duration))
                }
                .buttonStyle(.plain)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 28)
    }

    /// "FLAC · 1017 kbps", from what the server already told us about the file. Nil when
    /// it told us nothing — an empty badge would just be lint.
    private var qualityLine: String? {
        guard let song = model.music.nowPlaying else { return nil }
        let format = song.suffix?.uppercased()
        let rate = song.bitRate.map { "\($0) kbps" }
        return Counted.line([format, rate])
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

    /// Baton's own level, which the phone had no way to see or change.
    ///
    /// The Mac carries this in three places and a menu; the phone carried it nowhere, so
    /// `volumePercent` was reachable only through the music friend — meaning "turn it down"
    /// left you with a quiet player and no control to undo it. This is not the system
    /// volume (that is what the hardware buttons are for); it is Baton's own attenuation,
    /// the same value the Mac's slider drives, so the two platforms mean the same thing by
    /// the word.
    ///
    /// Not `MusicVolumeControl` from the Mac, deliberately: that one is built around a
    /// scroll wheel and hover tooltips, neither of which a phone has. Shared concept,
    /// different instrument.
    private var volumeRow: some View {
        HStack(spacing: 10) {
            Button { model.music.toggleMute() } label: {
                Image(systemName: model.music.isMuted || model.music.volumePercent == 0
                      ? "speaker.slash.fill" : "speaker.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(model.music.isMuted ? 1 : 0.6))
                    .frame(width: 18)
            }
            .accessibilityLabel(model.music.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(model.music.volumePercent) },
                    set: { model.music.setVolume(percent: Int($0)) }
                ),
                in: 0 ... 100
            )
            .tint(accent)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(model.music.volumePercent) percent")
        }
        .padding(.horizontal, 16)
    }

    /// Like, lyrics, AirPlay, sleep — the row under the transport. On the Mac these
    /// Playback speed. The same 0.5–2× the engine clamps to, so the menu cannot offer a
    /// rate that would be silently corrected.
    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                Button {
                    model.music.playbackRate = Float(rate)
                } label: {
                    if abs(Double(model.music.playbackRate) - rate) < 0.01 {
                        Label(Self.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(Self.rateLabel(Double(model.music.playbackRate)))
                .foregroundStyle(.white.opacity(0.6))
                .monospacedDigit()
        }
        .accessibilityLabel("Playback speed")
    }

    /// "1×", "1.5×" — no trailing zero on a whole number, which is how every podcast app
    /// writes it and how people say it.
    private static func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }

    /// live across the expanded bar; the phone gathers them where the thumb is.
    private func secondaryControls(for song: NavidromeSong) -> some View {
        HStack(spacing: 0) {
            // The like control now lives on the artwork's bottom-right corner, where the
            // Mac has always kept it. Leaving a second one here would be the same
            // affordance in two places — the drift this codebase keeps paying for.

            // Up Next opens a screen of its own. It used to be a List sharing this
            // view's VStack with the artwork, the scrubber and two rows of controls, so
            // it got whatever was left — about one and a half rows on an iPhone. A queue
            // you can't see is a queue you can't reorder.
            Button { showsQueue = true } label: {
                Image(systemName: "list.bullet").foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Up Next")

            Button { showsLyrics = true } label: {
                Image(systemName: "quote.bubble").foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Lyrics")

            // Shown for everything, as the Mac's Transcript panel always has been. Hiding it
            // on anything that wasn't a podcast episode was meant to stop someone spending a
            // GPU pass to learn that a synth record has no words in it — but nothing here
            // starts a transcription on its own, so the cost was never in the button. What it
            // actually did was make the feature unreachable on the phone for every song in
            // the library, with no way to find out it existed. The sheet still says plainly
            // that this isn't spoken-word audio before offering to do it anyway.
            Button { showsTranscript = true } label: {
                Image(systemName: "text.viewfinder").foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Transcript")

            // The Mac's player has three panels — Up Next, Lyrics, Related. The phone had
            // the first two. The similarity data was already being fetched here, but only
            // to feed autoplay: the queue would quietly fill with related tracks that you
            // could never ask to see.
            Button { showsRelated = true } label: {
                Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Related")

            // Speed, on the player, for podcasts only. It was settable from the show list
            // and nowhere else — so changing it meant leaving the thing you were listening
            // to, which is the one moment you know you want it faster.
            if song.isPodcastEpisode {
                rateMenu
                    .frame(maxWidth: .infinity)
            }

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


    // Was `%d:%02d` with no hour branch, so an hour-long mix read `70:23` here too — the
    // player is the one place the number has to be right.
    private func timeString(_ t: TimeInterval) -> String {
        PlayTime.track(seconds: t) ?? "0:00"
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

/// The queue, full height.
///
/// This was a `List` sharing the player's `VStack` with the artwork, the scrubber and two
/// rows of controls, so it rendered about one and a half rows on an iPhone — enough to
/// prove a queue existed and not enough to use one. Reordering a queue you can only see
/// one row of is not a feature. It gets a screen.
struct QueueSheet: View {
    let model: MobileModel
    var accent: Color = .accentColor

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    /// What is still to play from the current track onward. Nil when nothing in the queue
    /// reports a length — a "0m left" would be a worse answer than no answer.
    private var remainingTime: String? {
        let queue = model.music.queue
        guard model.music.currentIndex < queue.count else { return nil }
        let seconds = queue[model.music.currentIndex...].reduce(0) { $0 + ($1.duration ?? 0) }
        guard let total = PlayTime.total(seconds) else { return nil }
        return "\(Counted.phrase(queue.count - model.music.currentIndex, "track")) left · \(total)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.music.queue.isEmpty {
                    ContentUnavailableView(
                        "Nothing queued",
                        systemImage: "list.bullet",
                        description: Text("Play an album or a mix and what's coming up shows here.")
                    )
                } else {
                    List {
                        // The engine records a source on every play(); the queue is where
                        // "why is this song next" gets asked, so it is answered here.
                        if let source = model.music.queueSource {
                            Section {
                            } header: {
                                Text("Playing from \(source.label)")
                                    .textCase(nil)
                            }
                            .listSectionSpacing(0)
                        }
                        // Keyed by position, not by song id. A queue is the one list in the
                        // app where the same item legitimately appears twice — "Play Next"
                        // on something already queued does exactly that — and duplicate
                        // ForEach ids make SwiftUI render the wrong rows and hand `onMove`
                        // and `onDelete` the wrong index, so a reorder edits a different
                        // track than the one you dragged. Position is unique by definition.
                        ForEach(Array(model.music.queue.enumerated()), id: \.offset) { index, song in
                            HStack(spacing: 10) {
                                if index == model.music.currentIndex {
                                    // The same bars every other list uses. This row drew
                                    // `speaker.wave.2.fill` — a different symbol for the
                                    // same job, which is how it survived a sweep that
                                    // searched for "waveform": the queue and the search
                                    // results showed the same track two different ways at
                                    // the same moment.
                                    NowPlayingBars(isPlaying: model.music.state == .playing)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .lineLimit(1)
                                        .foregroundStyle(index == model.music.currentIndex ? accent : .primary)
                                    Text(song.artist ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if let time = PlayTime.track(song.duration) {
                                    Text(time)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.music.jump(to: index)
                                dismiss()
                            }
                            .songContextMenu(song, model: model)
                        }
                        // Reordering and removal are the two things a queue is for. The
                        // engine has had both since the Mac shipped.
                        .onMove { source, destination in
                            model.music.moveQueueItem(from: source, to: destination)
                        }
                        .onDelete { offsets in
                            model.music.removeFromQueue(at: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            // "How long until my track" is the queue's own question, so the answer goes
            // where the question is asked — everything still to play, current track
            // included, since that is what "left" means while it is playing.
            .safeAreaInset(edge: .bottom) {
                if let remaining = remainingTime {
                    Text(remaining)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .toolbar {
                if !model.music.queue.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .accessibilityIdentifier("QueueSheet")
        }
    }
}

/// The five-star control, matching the Mac's.
///
/// Tapping the star you are already on clears the rating, which is the Mac's behaviour and
/// the only way to get back to unrated without a separate "Clear" affordance taking up
/// room on a phone.
struct MobileStarRating: View {
    let rating: Int
    var tint: Color = .yellow
    var onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { star in
                Button {
                    onRate(rating == star ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.footnote)
                        .foregroundStyle(star <= rating ? tint : .white.opacity(0.45))
                        // Thumb-sized without making the row taller: the icon stays small
                        // while the tappable area does not.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star <= rating ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of 5 stars")
        .accessibilityIdentifier("StarRating")
        // Rating is a deliberate, aimed tap with no other confirmation — the stars simply
        // fill. A tick is what tells you it registered without watching for it.
        .sensoryFeedback(.selection, trigger: rating)
    }
}

/// Songs the server thinks belong with this one.
///
/// The counterpart to the Mac's Related panel. Radio bans are honoured here for the same
/// reason autoplay honours them: a track you told Baton to stop suggesting shouldn't
/// reappear in a list headed "because you're playing this".
struct RelatedSheet: View {
    let song: NavidromeSong
    let model: MobileModel
    @Environment(\.dismiss) private var dismiss

    @State private var related: [NavidromeSong] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if related.isEmpty {
                    ContentUnavailableView(
                        "No related tracks",
                        systemImage: "sparkles",
                        description: Text("Your server had no similar songs for this one.")
                    )
                } else {
                    List {
                        ForEach(related) { track in
                            Button {
                                model.music.play(related,
                                                 startAt: related.firstIndex(of: track) ?? 0,
                                                 source: .init(label: "Related to \(song.title)", kind: .radio))
                                dismiss()
                            } label: {
                                SongRow(song: track, model: model)
                            }
                            .buttonStyle(.plain)
                            .songContextMenu(track, model: model)
                        }
                    }
                }
            }
            .navigationTitle("Related")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                if !related.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Play All") {
                            model.music.play(related,
                                             source: .init(label: "Related to \(song.title)", kind: .radio))
                            dismiss()
                        }
                    }
                }
            }
        }
        .task {
            let found = await model.musicLibrary.similarSongs(seedID: song.id)
            related = model.radioBans.filtered(found)
            loading = false
        }
    }
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
                    if LRCLIBLyrics.isLikelyLyricless(durationSeconds: song.duration) {
                        ContentUnavailableView("Too long to have lyrics", systemImage: "quote.bubble",
                                               description: Text("Mixes and sets this length aren't written down anywhere."))
                    } else {
                        ContentUnavailableView("No lyrics for this track", systemImage: "quote.bubble")
                    }
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
                lyrics = await model.musicLibrary.lyrics(for: song.id, song: song)
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
