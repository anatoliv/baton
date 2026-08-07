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

            HStack(spacing: 10) {
                Button(isSyncing ? "Syncing…" : "Sync now") { Task { await runSync() } }
                    .disabled(isSyncing || gatewayURL.isEmpty || token.isEmpty)
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }

            Text("""
            Carries your equalizer, crossfade, loudness, radio bans, search history and \
            music-friend settings between this Mac and your iPhone. Your likes, ratings, \
            playlists and \
            play counts already sync — those live on your Navidrome server. Downloads, \
            offline mode and this Mac's own paths stay where they are, because they \
            describe a device rather than you.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
