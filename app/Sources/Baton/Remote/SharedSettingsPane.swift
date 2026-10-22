import SwiftUI
import BatonPlaybackKit

/// Shared settings — the Mac half of "see my preferences from both devices".
///
/// Likes, ratings, playlists and play counts already follow you: they live on Navidrome,
/// keyed to your user, and both apps write them. What didn't were the settings Baton keeps
/// locally — the EQ curve, radio bans, crossfade, the agent's provider — because Navidrome
/// has no client-preference API to keep them in.
///
/// Those go through the gateway, the one place both devices already authenticate. It is
/// entirely optional: leave this blank and everything works exactly as before, on both
/// machines. Sync is an upgrade, not a dependency.
struct SharedSettingsPane: View {
    @Environment(MusicModel.self) private var model
    @AppStorage("baton.agent.gatewayURL") private var gatewayURL = ""
    @State private var token = BearerGateway.savedToken() ?? ""
    @State private var status: String?
    @State private var isSyncing = false

    /// Whether the gateway is there and takes this token — asked without writing anything.
    /// Before this the only way to find out was to press **Sync now**, which is a write.
    @State private var gatewayStatus: ServiceStatus = .unknown

    /// @State, not a stored `let`: a `View` struct is rebuilt on every render, and a sync
    /// object that quietly starts caching would then lose its cache constantly.
    @State private var sync = PreferenceSync(deviceName: Host.current().localizedName ?? "Mac")

    var body: some View {
        Section("Baton server") {
            TextField("Baton server address", text: $gatewayURL, prompt: Text("https://baton.home.example"))
            Text("Just the host and port. The Baton server listens on 8788 by default. A trailing /v1 is dropped if you paste one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Baton server token", text: $token)
            Button("Save token") {
                NavidromeKeychain.setSecret(token, account: BearerGateway.tokenAccount)
                status = "Saved."
            }
            .disabled(token == (BearerGateway.savedToken() ?? ""))

            LabeledContent("Connection") {
                HStack(spacing: 10) {
                    Button(gatewayStatus.isChecking ? "Checking…" : "Test") { Task { await check() } }
                        .disabled(gatewayStatus.isChecking || gatewayURL.isEmpty || token.isEmpty)
                    Label(gatewayStatus.label, systemImage: gatewayStatus.symbol)
                        .foregroundStyle(gatewayStatus.tint)
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
            }
            if let detail = gatewayStatus.detail {
                Text(detail).font(.callout).foregroundStyle(gatewayStatus.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(isSyncing ? "Syncing…" : "Sync now") { Task { await runSync() } }
                    .disabled(isSyncing || gatewayURL.isEmpty || token.isEmpty)
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }

            Text("""
            Your Baton server is the small Baton program you run at home, often on the same \
            machine as your music server. It makes books from documents, keeps your place \
            in them, and carries your equalizer, crossfade, loudness, radio bans, podcast \
            subscriptions, search history and the music friend's provider and model \
            between this Mac and your iPhone. Your likes, ratings, playlists and \
            play counts already sync, because those live on your music server. Downloads, \
            offline mode and this Mac's own paths stay where they are, because they \
            describe a device rather than you. API keys never travel through here; \
            pairing carries those, encrypted.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                HelpTopicButton(topicSlug: HelpGuide.twoServersTopic, label: "About the two servers")
            }
        }
        .onAppear { Task { await check() } }
        // A green light belongs to the address and token that were checked, not to the
        // fields. Editing either makes the old answer a claim about something else.
        .onChange(of: gatewayURL) { gatewayStatus = .unknown }
        .onChange(of: token) { gatewayStatus = .unknown }
    }

    private func check() async {
        let trimmed = gatewayURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !token.isEmpty else {
            gatewayStatus = .notConfigured("No Baton server yet")
            return
        }
        guard let url = URL(string: trimmed), url.host != nil else {
            gatewayStatus = .unreachable("That doesn't look like a URL.")
            return
        }
        guard let gateway = BearerGateway.resolve(address: trimmed, token: token) else {
            gatewayStatus = .refused(Self.notSentReason(address: trimmed, token: token) ?? Self.clearTextRefusal(url))
            return
        }
        gatewayStatus = .checking
        switch await sync.check(gatewayURL: gateway.url, token: gateway.token) {
        case let .ok(entries):
            gatewayStatus = .ok(detail: entries == 0
                ? "Reachable. Nothing shared yet. This would be the first device."
                : "Reachable. \(entries) settings shared.")
        case .rejected:
            gatewayStatus = .refused("The Baton server didn't accept this token.")
        case let .failed(why):
            gatewayStatus = .unreachable(why)
        }
    }

    private func runSync() async {
        guard let url = URL(string: gatewayURL.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            status = "That doesn't look like a URL."
            return
        }
        guard let gateway = BearerGateway.resolve(address: gatewayURL, token: token) else {
            status = Self.notSentReason(address: gatewayURL, token: token) ?? Self.clearTextRefusal(url)
            return
        }
        isSyncing = true
        status = nil
        let ok = await sync.sync(gatewayURL: gateway.url, token: gateway.token)
        // A sync merges the phone's search history straight into UserDefaults, which the
        // in-memory list can't see. Without this it only appears after a relaunch.
        model.searchRecents.reload()
        isSyncing = false
        // Reports what happened rather than a spinner that stops: a sync that silently
        // fails is indistinguishable from one that had nothing to do.
        status = ok ? "Settings exchanged." : "Couldn't reach the Baton server."
    }

    /// Why the token would not be sent to `address`, or nil when it would be.
    static func notSentReason(address: String, token: String) -> String? {
        guard BearerGateway.resolve(address: address, token: token) == nil else { return nil }
        if token.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Not sent: the token is empty. Paste the Baton server's token and save it."
        }
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.host != nil,
              let scheme = url.scheme?.lowercased() else {
            return "That doesn't look like a URL."
        }
        guard scheme == "http" || scheme == "https" else {
            return "Not sent: the Baton server's address has to start with http:// or https://."
        }
        return clearTextRefusal(url)
    }

    /// Why the token was not sent: plain HTTP to an address off the home network would carry it
    /// across the internet in the clear (`BearerGateway`).
    static func clearTextRefusal(_ url: URL) -> String {
        "Not sent: \(url.host ?? "this address") is outside your home network, so the token would travel unencrypted. Use https://, or the server's home or Tailscale address."
    }
}
