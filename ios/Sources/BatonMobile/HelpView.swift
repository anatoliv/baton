import MarkdownUI
import SwiftUI

/// In-app Help: the same HELP.md and FAQ.md the repo root carries and the website
/// publishes, copied into the bundle by a prebuild step so they can never drift
/// from the docs we actually edit. Same library and pin as the Mac app, so the
/// two apps render identically.
struct HelpView: View {
    enum Guide: String, CaseIterable, Identifiable {
        case help = "Guide"
        case faq = "FAQ"

        var id: String { rawValue }
        var resource: String { self == .help ? "HELP" : "FAQ" }
    }

    @State private var guide: Guide = .help
    @State private var text = ""

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownTextStyle(\.text) { FontSize(15) }
                .padding()
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $guide) {
                    ForEach(Guide.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .task(id: guide) { load() }
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: guide.resource, withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            text = "The \(guide.rawValue.lowercased()) didn't make it into this build."
            return
        }
        text = contents
    }
}

/// What's New — the release notes for the version the user just updated to,
/// shown once per version. The Mac app keeps richer cards; the phone shows the
/// same words without the artwork, which is what fits a phone screen.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    static let currentVersion = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Last version whose notes were shown. Empty on a fresh install, which is
    /// why a first launch shows nothing — a new user needs onboarding, not a
    /// changelog.
    @AppStorage("baton.whatsNew.lastShownVersion") private static var lastShown = ""

    static var shouldShow: Bool {
        !lastShown.isEmpty && lastShown != currentVersion
    }

    static func markShown() { lastShown = currentVersion }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.notes, id: \.title) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(note.title, systemImage: note.symbol)
                                .font(.headline)
                            Text(note.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { Self.markShown(); dismiss() }
                }
            }
        }
    }

    struct Note {
        let title: String
        let detail: String
        let symbol: String
    }

    /// Update these with each release, newest first — the phone equivalent of the
    /// Mac's What's New cards.
    static let notes: [Note] = [
        .init(title: "Set up by scanning",
              detail: "Open Baton on your Mac, show a pairing code, and point this phone at it. No typing a server address or a password.",
              symbol: "qrcode.viewfinder"),
        .init(title: "The whole app takes its colour from the cover",
              detail: "Not just the player — every screen now shifts with what's playing, the way the Mac does.",
              symbol: "paintpalette"),
        .init(title: "Your top tracks count every device",
              detail: "All-time favourites now come from your server, so what you played on the Mac counts too.",
              symbol: "chart.bar"),
        .init(title: "Settings that follow you",
              detail: "Equalizer, crossfade, radio bans and your music friend's setup can travel between your devices through your Baton gateway.",
              symbol: "arrow.triangle.2.circlepath"),
        .init(title: "Disconnect really disconnects",
              detail: "Leaving a server now removes its downloads, history and accounts from this iPhone — and tells you exactly what it will delete first.",
              symbol: "trash"),
        .init(title: "Face ID on your keys",
              detail: "Your music friend's API key and gateway token stay hidden until you unlock them. Playing music never asks.",
              symbol: "faceid"),
        .init(title: "Opens even with no signal",
              detail: "A dropped connection no longer sends you back to the sign-in screen. Your downloads are right where you left them.",
              symbol: "wifi.slash"),
    ]
}
