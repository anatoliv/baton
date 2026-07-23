import Foundation
import Observation
import OSLog
import SwiftUI

private let supportLog = Logger(subsystem: "io.tonebox.baton", category: "Support")

// MARK: - Donation links

/// The tip-jar destinations shown in the About pane. Baton is free and MIT-licensed; these let
/// people who want to support the project choose whichever platform they prefer.
///
/// To turn a button on, set its handle to your account name (leave `nil` to hide the button).
/// GitHub Sponsors is the natural fit for an open-source project (no fees, one-time or monthly);
/// the others are here so users aren't forced onto a single service.
enum SupportLinks {
    /// github.com/sponsors/<handle> — inferred from the repo; change if your Sponsors handle differs.
    static let gitHubSponsorsHandle: String? = "anatoliv"
    /// ko-fi.com/<handle>
    static let koFiHandle: String? = "anatolivishnyakov"
    /// buymeacoffee.com/<handle>
    static let buyMeACoffeeHandle: String? = nil // TODO: set your Buy Me a Coffee handle
    /// paypal.me/<handle>
    static let payPalHandle: String? = "anatolivishnyakov"

    /// Where users vote on what to build next — open issues labelled `roadmap`, sorted by 👍
    /// reactions. The label filter keeps bug reports out so the page is purely candidate features.
    /// Kept separate from the tip buttons on purpose: tips fund the project as a whole, they don't
    /// buy a feature.
    static let roadmapURL = URL(string: "https://github.com/anatoliv/baton/issues?q=is%3Aissue+is%3Aopen+label%3Aroadmap+sort%3Areactions-%2B1-desc")!

    /// One tappable destination in the support row.
    struct Option: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let url: URL
    }

    /// Only the platforms you've configured a handle for, in a stable display order.
    static var options: [Option] {
        var out: [Option] = []
        if let h = gitHubSponsorsHandle, let url = URL(string: "https://github.com/sponsors/\(h)") {
            out.append(.init(id: "github", title: "GitHub Sponsors", symbol: "heart.fill", url: url))
        }
        if let h = koFiHandle, let url = URL(string: "https://ko-fi.com/\(h)") {
            out.append(.init(id: "kofi", title: "Ko-fi", symbol: "cup.and.saucer.fill", url: url))
        }
        if let h = buyMeACoffeeHandle, let url = URL(string: "https://www.buymeacoffee.com/\(h)") {
            out.append(.init(id: "bmc", title: "Buy Me a Coffee", symbol: "cup.and.saucer.fill", url: url))
        }
        if let h = payPalHandle, let url = URL(string: "https://www.paypal.com/paypalme/\(h)") {
            out.append(.init(id: "paypal", title: "PayPal", symbol: "dollarsign.circle.fill", url: url))
        }
        return out
    }
}

// MARK: - Supporters (remote, opt-in recognition)

/// One name to thank in the About pane. `url` is optional — when present the name links out
/// (e.g. to the supporter's site or profile). Recognition is opt-in: people appear here only
/// after they ask to be listed.
struct Supporter: Decodable, Identifiable, Hashable {
    let name: String
    let url: URL?
    var id: String { name }
}

/// The `supporters.json` document served from the Baton site.
private struct SupporterList: Decodable {
    let version: Int?
    let supporters: [Supporter]
}

/// Loads the "Thanks to our supporters" list from `baton.tonebox.io/supporters.json` so names can
/// be added by redeploying the site (via publish-site.sh) — no app release required. The last good
/// copy is cached in Application Support, so the list paints instantly and survives offline; a
/// background refresh keeps it current. If the fetch fails and there's no cache, the section simply
/// hides — never an error in the user's face.
@MainActor
@Observable
final class SupportersStore {
    private(set) var supporters: [Supporter] = []

    private var loaded = false
    private let remoteURL: URL
    private let cacheURL: URL
    private let fetch: (URL) async throws -> Data

    init(
        remoteURL: URL = URL(string: "https://baton.tonebox.io/supporters.json")!,
        directory: URL? = nil,
        fetch: @escaping (URL) async throws -> Data = { url in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue("Baton (macOS; Support)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
    ) {
        self.remoteURL = remoteURL
        self.fetch = fetch
        let dir = directory ?? Self.defaultDirectory()
        cacheURL = dir.appendingPathComponent("supporters.json")
    }

    /// Paints the cached list, then refreshes from the site in the background. Safe to call from
    /// `.task` on every appearance — the cache read happens once.
    func loadIfNeeded() async {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: cacheURL), let list = try? JSONDecoder().decode(SupporterList.self, from: data) {
                supporters = list.supporters
            }
        }
        await refresh()
    }

    private func refresh() async {
        do {
            let data = try await fetch(remoteURL)
            let list = try JSONDecoder().decode(SupporterList.self, from: data)
            supporters = list.supporters
            try? data.write(to: cacheURL, options: .atomic) // best-effort cache; a write failure just means a stale list
        } catch {
            supportLog.debug("supporters refresh skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Baton", isDirectory: true)
    }
}

// MARK: - About-pane section

/// "Support Baton" — the tip-jar buttons plus an opt-in supporter thank-you list. Designed to drop
/// straight into the grouped `Form` of the About pane. Baton stays free and MIT under all of this;
/// tips fund sustainability, and the list is recognition, not a paywall.
struct SupportBatonSection: View {
    @Environment(\.openURL) private var openURL
    @State private var store = SupportersStore()

    private let options = SupportLinks.options

    var body: some View {
        Section("Support Baton") {
            Text("Baton is free and open source. If it earns a place in your day, a one-time tip helps keep it maintained — entirely optional, and it never unlocks anything.")
                .font(.callout).foregroundStyle(.secondary)

            if options.isEmpty {
                Text("No donation options are configured in this build yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // All donation buttons on one row, sharing width equally.
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        Button {
                            openURL(option.url)
                        } label: {
                            Label(option.title, systemImage: option.symbol)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .help("Opens \(option.url.host ?? option.title) in your browser")
                    }
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 2)
            }

            Link(destination: SupportLinks.roadmapURL) {
                Label("Vote on what's next", systemImage: "arrow.up.heart")
                    .font(.callout)
            }

            if !store.supporters.isEmpty {
                Divider()
                Text("Thanks to our supporters")
                    .font(.callout.weight(.semibold))
                SupportersFlow(supporters: store.supporters)
            }
        }
        .task { await store.loadIfNeeded() }
    }
}

/// The supporter names as a soft, wrapping run of chips. Names with a `url` link out; the rest are
/// plain text. Kept deliberately understated — a thank-you, not a leaderboard.
private struct SupportersFlow: View {
    let supporters: [Supporter]

    var body: some View {
        Text(attributed)
            .font(.callout)
            .foregroundStyle(.secondary)
            .tint(.accentColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Builds "Name · Name · Name", linking any supporter that supplied a URL.
    private var attributed: AttributedString {
        var out = AttributedString()
        for (index, supporter) in supporters.enumerated() {
            if index > 0 { out += AttributedString("  ·  ") }
            var chip = AttributedString(supporter.name)
            if let url = supporter.url { chip.link = url }
            out += chip
        }
        return out
    }
}
