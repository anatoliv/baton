import AppKit
import BatonSubsonicKit
import SwiftUI
import Foundation
import Testing
@testable import Baton

/// Scene-level appearance propagation cannot be instantiated as a unit-test Scene.
/// These guards cover the wiring; the synthetic native walk covers live switching.
@MainActor
@Suite("Player appearance")
struct PlayerAppearanceTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Neither Mac player overrides the app appearance")
    func playersInheritAppearance() throws {
        for name in ["FullScreenNowPlaying", "MiniPlayerWindowView"] {
            let text = try source("app/Sources/Baton/Shell/Music/\(name).swift")
            #expect(!text.contains(".preferredColorScheme(.dark)"))
            #expect(!text.contains("AdaptiveBackdrop(palette: palette, tone: .dark)"))
        }
        let app = try source("app/Sources/Baton/BatonApp.swift")
        let mini = try #require(app.range(of: "Window(\"Mini Player\""))
        let scene = app[mini.lowerBound...].components(separatedBy: ".defaultSize")[0]
        #expect(scene.contains(".batonChrome()"))
    }

    @Test("Quick Appearance uses the same live defaults store and choices as Settings")
    func quickSwitchSharesPreference() throws {
        let text = try source("app/Sources/Baton/Shell/Music/FullScreenNowPlaying.swift")
        #expect(text.contains("@AppStorage(AppearanceSetting.key, store: BatonStorage.defaults)"))
        #expect(text.contains("ForEach(AppearanceSetting.allCases)"))
        #expect(text.contains("Picker(\"Appearance\", selection: $appearanceRaw)"))
        #expect(text.contains("SleepTimerMenu("), "the crescent remains Sleep Timer")
    }
    @Test("Both open native windows follow app Light, Dark and System together")
    func openWindowsFollowAppAppearance() {
        let savedAppearance = NSApp.appearance
        let windows = (0..<2).map { _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        defer {
            NSApp.appearance = savedAppearance
            for window in windows { window.close() }
        }
        // Synchronous on MainActor: no other UI test interleaves while the host's appearance changes.
        NSApp.appearance = nil
        let systemTone = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        for setting in [AppearanceSetting.light, .dark, .system] {
            BatonChrome.applyAppearance(setting)
            let expected: NSAppearance.Name? = switch setting {
            case .light: .aqua
            case .dark: .darkAqua
            case .system: systemTone
            }
            for window in windows {
                #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            }
            if setting == .system { #expect(NSApp.appearance == nil) }
        }
    }

    @Test("Bright artwork stays charcoal behind Dark player text")
    func brightDarkArtworkContrast() {
        for color in [Color.white, .yellow, .red, .blue, .black] {
            let palette = ArtworkPalette(primary: color, secondary: color, accent: color)
            let displayed = FullScreenNowPlaying.backdropPalette(palette, for: .dark)
            let ground = displayed.backdropWorstCase(for: .dark)
            #expect(Contrast.ratio(.white, ground) >= 7)
            #expect(Contrast.ratio(Contrast.composite(.white.opacity(0.55), over: ground), ground) >= 4.5)
            #expect(FullScreenNowPlaying.backdropPalette(palette, for: .light) == palette)
        }
    }

    @Test("Both players and the queue render in Light and Dark without changing the queue")
    func playerSnapshots() throws {
        let configSuite = ThrowawayDefaults.name("player-config")
        let configDefaults = try #require(UserDefaults(suiteName: configSuite))
        let savedConfig = NavidromeConfig.defaults
        let savedSecrets = NavidromeKeychain.inMemoryStore
        NavidromeConfig.defaults = configDefaults
        NavidromeKeychain.inMemoryStore = [:]
        defer {
            NavidromeConfig.defaults = savedConfig
            NavidromeKeychain.inMemoryStore = savedSecrets
            configDefaults.removePersistentDomain(forName: configSuite)
        }
        let model = MusicModel(environment: .testing)
        let songs = (1...8).map { i in
            NavidromeSong(id: "appearance-\(i)", title: i == 1 ? "Evening Light" : "Queued track \(i)",
                          artist: "Baton appearance fixture", album: "Theme study", duration: 268,
                          coverArtID: nil)
        }
        model.music.play(songs, source: .init(label: "Theme study", kind: .playlist, id: "appearance"))
        let queue = model.music.queue.map(\.id)
        let state = model.music.state
        let suite = ThrowawayDefaults.name("player-appearance")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "tonebox.miniPlayer.expanded")
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            let full = FullScreenNowPlaying(isPresented: .constant(true), previewPalette: .neutral)
                .environment(model).environment(\.colorScheme, scheme)
            try snapshot(full, width: 1200, height: 850, name: "player-\(name)", scheme: scheme)
            for (artName, palette) in [
                ("red", ArtworkPalette(primary: .red, secondary: Color(red: 0.45, green: 0, blue: 0), accent: .red)),
                ("white", ArtworkPalette(primary: .white, secondary: Color(white: 0.45), accent: .white))
            ] {
                let vivid = FullScreenNowPlaying(isPresented: .constant(true), previewPalette: palette)
                    .environment(model).environment(\.colorScheme, scheme)
                try snapshot(vivid, width: 1200, height: 850, name: "player-\(artName)-\(name)", scheme: scheme)
            }
            let mini = MiniPlayerWindowView().environment(model)
                .defaultAppStorage(defaults).environment(\.colorScheme, scheme)
            try snapshot(mini, width: 320, height: 410, name: "mini-\(name)", scheme: scheme)
            #expect(model.music.queue.map(\.id) == queue)
            #expect(model.music.state == state)
        }
        model.music.stop()
    }

    @Test("Populated lyrics, seekable transcript lines and Mini ratings render in both themes")
    func panelTextSnapshots() throws {
        let lines = NavidromeLyrics(synced: true, lines: [
            .init(start: 0, text: "Previous line remains readable"),
            .init(start: 10, text: "Current line carries the emphasis"),
            .init(start: 20, text: "Upcoming line remains readable")
        ])
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            let accent = ArtworkPalette.neutral.uiAccent(for: .resolved(for: scheme))
            let panel = VStack(alignment: .leading, spacing: 8) {
                Text("Lyrics").font(.headline).padding(.horizontal, 20)
                MusicLyricLines(lyrics: lines, currentLine: 1)
                Divider()
                Text("Transcript").font(.headline).padding(.horizontal, 20)
                MusicLyricLines(lyrics: lines, currentLine: 1, onSelectLine: { _ in })
                Divider()
                MusicStarRating(rating: 3, tint: accent, unselectedTint: .primary, onRate: { _ in })
                    .padding(20)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.primary)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            try snapshot(panel, width: 440, height: 450, name: "panel-text-\(name)", scheme: scheme)
        }
    }

    private func snapshot(_ view: some View, width: CGFloat, height: CGFloat,
                          name: String, scheme: ColorScheme) throws {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 1500)
        try png.write(to: URL(fileURLWithPath: "/private/tmp/baton-1000000149-player-theme/\(name).png"))
        window.close()
    }
}
