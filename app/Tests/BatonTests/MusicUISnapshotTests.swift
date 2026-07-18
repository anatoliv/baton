import AppKit
import SwiftUI
import Testing
@testable import Baton

/// Color-extraction correctness + snapshot renders of the new music UI (adaptive
/// backdrop, full-screen player). PNGs are written to /tmp for eyeball inspection.
@MainActor
@Suite("Music UI")
struct MusicUISnapshotTests {
    private func solidImage(_ color: NSColor, size: Int = 48) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    private func components(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? .black
    }

    private func render(_ view: some View, width: CGFloat, height: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func writePNG(_ image: NSImage, _ path: String) throws {
        let rep = try #require(
            image.representations.first as? NSBitmapImageRep
                ?? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        )
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 1500)
        try png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Extraction correctness

    @Test("Palette from a red cover is red-dominant")
    func redDominant() {
        let color = components(ArtworkColorExtractor.palette(from: solidImage(.red)).primary)
        #expect(color.redComponent > color.greenComponent)
        #expect(color.redComponent > color.blueComponent)
    }

    @Test("Palette from a blue cover is blue-dominant")
    func blueDominant() {
        let color = components(ArtworkColorExtractor.palette(from: solidImage(.systemBlue)).primary)
        #expect(color.blueComponent > color.redComponent)
    }

    @Test("Palette from black art doesn't crash and stays dark")
    func blackSafe() {
        let color = components(ArtworkColorExtractor.palette(from: solidImage(.black)).primary)
        #expect(color.redComponent < 0.3 && color.greenComponent < 0.3 && color.blueComponent < 0.3)
    }

    // MARK: - Snapshots (written to /tmp for visual inspection)

    @Test("Adaptive backdrop renders the artwork gradient")
    func backdropSnapshot() throws {
        let palette = ArtworkPalette(
            primary: Color(red: 0.42, green: 0.24, blue: 1.0),
            secondary: Color(red: 0.06, green: 0.05, blue: 0.12),
            accent: Color(red: 1.0, green: 0.24, blue: 0.47)
        )
        let image = try #require(render(AdaptiveBackdrop(palette: palette), width: 600, height: 400))
        try writePNG(image, "/tmp/tonebox-music-backdrop.png")
    }

    @Test("Full-screen player renders with a queued track")
    func fullScreenSnapshot() throws {
        let model = MusicModel()
        model.music.play([
            NavidromeSong(
                id: "s1",
                title: "Players Only",
                artist: "LNRT",
                album: "Eurodance Classics",
                duration: 268,
                coverArtID: nil
            ),
            NavidromeSong(
                id: "s2",
                title: "Better Off Alone",
                artist: "Alice DJ",
                album: nil,
                duration: 221,
                coverArtID: nil
            ),
        ])
        model.music.seek(to: 107) // ~40% in → the scrubber must show 1:47 / -2:41
        let vivid = ArtworkPalette(
            primary: Color(red: 0.42, green: 0.24, blue: 1.0),
            secondary: Color(red: 0.08, green: 0.05, blue: 0.16),
            accent: Color(red: 1.0, green: 0.28, blue: 0.5)
        )
        let view = FullScreenNowPlaying(isPresented: .constant(true), previewPalette: vivid).environment(model)
        // Under the 900pt threshold so the queue panel (a List, unrenderable in
        // ImageRenderer) stays hidden and the hero renders cleanly.
        let image = try #require(render(view, width: 820, height: 680))
        #expect(image.size.width >= 800)
        try writePNG(image, "/tmp/tonebox-music-fullscreen.png")
    }

    @Test("Now-playing bar renders with the custom controls")
    func barSnapshot() throws {
        let model = MusicModel()
        model.music.play([
            NavidromeSong(
                id: "s1",
                title: "Players Only",
                artist: "LNRT",
                album: "Eurodance Classics",
                duration: 268,
                coverArtID: nil
            ),
        ])
        model.music.seek(to: 107)
        let view = NowPlayingBar().environment(model)
            .frame(width: 780)
            .background(Color(white: 0.11))
        let image = try #require(render(view, width: 780, height: 80))
        try writePNG(image, "/tmp/tonebox-music-bar.png")
    }

    @Test("Scrubber shows real elapsed/remaining time")
    func scrubberSnapshot() throws {
        let view = MusicScrubber(currentTime: 107, duration: 268, tint: .white) { _ in }
            .frame(width: 460)
            .padding(30)
            .background(Color(red: 0.12, green: 0.08, blue: 0.2))
        let image = try #require(render(view, width: 520, height: 90))
        try writePNG(image, "/tmp/tonebox-music-scrubber.png")
    }

    @Test("Track rows: ratings + like reachable and clear")
    func trackRowsSnapshot() throws {
        let model = MusicModel()
        let songs = [
            NavidromeSong(
                id: "s1",
                title: "Better Off Alone",
                artist: "Alice DJ",
                album: nil,
                duration: 221,
                coverArtID: nil,
                isLiked: true,
                userRating: 5
            ),
            NavidromeSong(
                id: "s2",
                title: "Around the World",
                artist: "ATC",
                album: nil,
                duration: 226,
                coverArtID: nil,
                isLiked: false,
                userRating: 3
            ),
            NavidromeSong(
                id: "s3",
                title: "Blue (Da Ba Dee)",
                artist: "Eiffel 65",
                album: nil,
                duration: 209,
                coverArtID: nil
            ),
        ]
        let view = VStack(spacing: 2) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { _, song in
                MusicTrackRow(song: song) {}.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .environment(model)
        .background(Color(white: 0.12))
        let image = try #require(render(view, width: 640, height: 170))
        try writePNG(image, "/tmp/tonebox-music-rows.png")
    }

    @Test("Lyrics view highlights the current synced line")
    func lyricsSnapshot() throws {
        let model = MusicModel()
        model.music.play([NavidromeSong(id: "s1", title: "T", artist: "A", album: nil, duration: 200, coverArtID: nil)])
        model.music.seek(to: 107)
        let lyrics = NavidromeLyrics(synced: true, lines: [
            .init(start: 96, text: "We're the players, we play all night"),
            .init(start: 101, text: "Neon city, everything's bright"),
            .init(start: 105, text: "Turn it up, feel the bassline drop"),
            .init(start: 112, text: "Hands in the air and we don't stop"),
            .init(start: 118, text: "Till the morning, we won't come down"),
        ])
        _ = model // (currentLine computed here directly since ScrollView won't render)
        // time 107 → last line with start ≤ 107 is index 2 ("Turn it up…").
        let view = MusicLyricLines(lyrics: lyrics, currentLine: 2)
            .background(Color(red: 0.1, green: 0.06, blue: 0.2))
        let image = try #require(render(view, width: 460, height: 260))
        try writePNG(image, "/tmp/tonebox-music-lyrics.png")
    }

    @Test("Artist hero banner")
    func artistHeroSnapshot() throws {
        let view = MusicArtistBanner(
            name: "Eiffel 65",
            meta: "ARTIST · 12 albums · 148 tracks",
            heroImage: nil,
            monogramInitial: "E",
            monogramColor: Color(hue: 0.62, saturation: 0.6, brightness: 0.7),
            isAutoImport: false,
            onBack: {}
        )
        .frame(width: 640)
        let image = try #require(render(view, width: 640, height: 148))
        try writePNG(image, "/tmp/tonebox-music-artist.png")
    }

    @Test("Album grid card layout + spacing")
    func albumGridSnapshot() throws {
        let model = MusicModel()
        let albums = (1 ... 4).map { NavidromeAlbum(
            id: "a\($0)",
            name: "Eurodance Hits Vol \($0)",
            artist: "Various Artists",
            songCount: 8 + $0,
            duration: 2600 + $0 * 700
        ) }
        // Non-lazy HStack so ImageRenderer actually rasterizes the cards.
        let view = HStack(spacing: 16) {
            ForEach(albums) { MusicAlbumCard(album: $0).frame(width: 170) }
        }
        .padding(18)
        .environment(model)
        .background(Color(white: 0.1))
        .environment(\.colorScheme, .dark)
        let image = try #require(render(view, width: 780, height: 220))
        try writePNG(image, "/tmp/tonebox-music-grid.png")
    }

    @Test("Hovered card lifts in front with a centered play button")
    func albumHoverSnapshot() throws {
        let model = MusicModel()
        let albums = (1 ... 4).map { NavidromeAlbum(id: "a\($0)", name: "Album \($0)", artist: "Artist \($0)") }
        // Tight spacing + the 2nd card scaled & zIndex-lifted: later siblings
        // (Album 3/4) would normally draw on top — this proves the lift renders
        // the hovered card IN FRONT, with its centered play button unclipped.
        let view = HStack(spacing: 4) {
            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                let hovered = index == 1
                MusicAlbumCard(album: album, previewHovering: hovered)
                    .frame(width: 150)
                    .scaleEffect(hovered ? 1.07 : 1)
                    .zIndex(hovered ? 1 : 0)
            }
        }
        .padding(24)
        .environment(model)
        .background(Color(white: 0.12))
        let image = try #require(render(view, width: 660, height: 250))
        try writePNG(image, "/tmp/tonebox-music-hover.png")
    }

    /// A REAL bitmap (CGImage renders in ImageRenderer, unlike NSImage.lockFocus):
    /// tall portrait, red top / green middle / blue bottom. Missing red or blue in
    /// the render == top/bottom was cropped.
    private func portraitBands() -> Image {
        let width = 120, height = 360
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(NSColor.systemRed.cgColor); ctx.fill(CGRect(x: 0, y: 240, width: 120, height: 120))
        ctx.setFillColor(NSColor.systemGreen.cgColor); ctx.fill(CGRect(x: 0, y: 120, width: 120, height: 120))
        ctx.setFillColor(NSColor.systemBlue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        return Image(decorative: ctx.makeImage()!, scale: 1)
    }

    @Test("16:9 card shows a portrait image in full (no top/bottom crop)")
    func fitNoCropSnapshot() throws {
        let cover = portraitBands()
        // Candidate fix: two separate .overlay layers (each sized to the 16:9 box)
        // instead of a ZStack — blurred fill behind, full scaledToFit image on top.
        let cardFix = Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { cover.resizable().scaledToFill().blur(radius: 18).overlay(Color.black.opacity(0.15)) }
            .overlay { cover.resizable().scaledToFit() }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: 240)
        let view = cardFix.padding(20).background(Color(white: 0.12))
        let image = try #require(render(view, width: 300, height: 200))
        try writePNG(image, "/tmp/tonebox-fit-nocrop.png")
    }

    @Test("Sidebar navigation rail")
    func sidebarSnapshot() throws {
        let selected = MusicView.MusicTab.albums
        let view = VStack(alignment: .leading, spacing: 3) {
            ForEach(MusicView.MusicTab.allCases) { item in
                Label(item.label, systemImage: item.icon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(item == selected ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        item == selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        .frame(width: 176, height: 280)
        .background(Color(white: 0.14))
        let image = try #require(render(view, width: 176, height: 280))
        try writePNG(image, "/tmp/tonebox-music-sidebar.png")
    }

    /// Solid CGImage of a given pixel size (renders in ImageRenderer).
    private func solidCGImage(width: Int, height: Int, _ color: NSColor) -> Image {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return Image(decorative: ctx.makeImage()!, scale: 1)
    }

    @Test("Fixed height, width follows aspect (no crop, no frame)")
    func fixedHeightArtworkSnapshot() throws {
        /// Wide (16:9), square, and tall covers — all should render at the SAME
        /// height with proportional widths, none cropped, none letterboxed.
        func art(_ image: Image) -> some View {
            image.resizable().aspectRatio(contentMode: .fit)
                .frame(height: 150)
                .frame(maxWidth: 260)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        let view = HStack(alignment: .center, spacing: 16) {
            art(solidCGImage(width: 320, height: 180, .systemBlue)) // 16:9
            art(solidCGImage(width: 200, height: 200, .systemGreen)) // square
            art(solidCGImage(width: 140, height: 220, .systemPink)) // tall
        }
        .padding(20).background(Color(white: 0.12))
        let image = try #require(render(view, width: 640, height: 200))
        try writePNG(image, "/tmp/tonebox-fixedheight.png")
    }

    @Test("Artist list rows: avatar, name, count, hover")
    func artistRowsSnapshot() throws {
        let artists = [
            NavidromeArtist(id: "1", name: "2 Unlimited", albumCount: 4),
            NavidromeArtist(id: "2", name: "\" Seven Nation Army \"", albumCount: 1),
            NavidromeArtist(id: "3", name: "040_Scooter", albumCount: 12),
            NavidromeArtist(id: "4", name: "Faithless", albumCount: nil),
        ]
        let view = VStack(spacing: 1) {
            ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                MusicArtistRow(artist: artist, previewHovering: index == 1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .frame(width: 460)
        .background(Color(white: 0.16))
        .environment(\.colorScheme, .dark) // the music view forces dark
        let image = try #require(render(view, width: 460, height: 230))
        try writePNG(image, "/tmp/tonebox-music-artists.png")
    }
}
