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
    @State private var token = NavidromeKeychain.secret(account: "baton.agent.gatewayToken") ?? ""
    @State private var status: String?
    @State private var isSyncing = false

    /// Whether the gateway is there and takes this token — asked without writing anything.
    /// Before this the only way to find out was to press **Sync now**, which is a write.
    @State private var gatewayStatus: ServiceStatus = .unknown

    /// @State, not a stored `let`: a `View` struct is rebuilt on every render, and a sync
    /// object that quietly starts caching would then lose its cache constantly.
    @State private var sync = PreferenceSync(deviceName: Host.current().localizedName ?? "Mac")

    var body: some View {
        Section("Shared settings") {
            TextField("Gateway URL", text: $gatewayURL, prompt: Text("https://baton.home.example"))
            SecureField("Gateway token", text: $token)
            Button("Save token") {
                NavidromeKeychain.setSecret(token, account: "baton.agent.gatewayToken")
                status = "Saved."
            }
            .disabled(token == (NavidromeKeychain.secret(account: "baton.agent.gatewayToken") ?? ""))

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
            Carries your equalizer, crossfade, loudness, radio bans, podcast \
            subscriptions, search history and the music friend's provider and model \
            between this Mac and your iPhone. Your likes, ratings, playlists and \
            play counts already sync — those live on your Navidrome server. Downloads, \
            offline mode and this Mac's own paths stay where they are, because they \
            describe a device rather than you. API keys never travel through here; \
            pairing carries those, encrypted.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
            gatewayStatus = .notConfigured("No gateway yet")
            return
        }
        guard let url = URL(string: trimmed), url.host != nil else {
            gatewayStatus = .unreachable("That doesn't look like a URL.")
            return
        }
        gatewayStatus = .checking
        switch await sync.check(gatewayURL: url, token: token) {
        case let .ok(entries):
            gatewayStatus = .ok(detail: entries == 0
                ? "Reachable. Nothing shared yet — this would be the first device."
                : "Reachable. \(entries) settings shared.")
        case .rejected:
            gatewayStatus = .refused("The gateway didn't accept this token.")
        case let .failed(why):
            gatewayStatus = .unreachable(why)
        }
    }

    private func runSync() async {
        guard let url = URL(string: gatewayURL.trimmingCharacters(in: .whitespaces)) else {
            status = "That doesn't look like a URL."
            return
        }
        isSyncing = true
        status = nil
        let ok = await sync.sync(gatewayURL: url, token: token)
        // A sync merges the phone's search history straight into UserDefaults, which the
        // in-memory list can't see. Without this it only appears after a relaunch.
        model.searchRecents.reload()
        isSyncing = false
        // Reports what happened rather than a spinner that stops: a sync that silently
        // fails is indistinguishable from one that had nothing to do.
        status = ok ? "Settings exchanged." : "Couldn't reach the gateway."
    }
}
