import SwiftUI

/// Baton's connect flow. In Tonebox the music player borrows the app's Settings →
/// Music pane; standalone Baton has no Settings window (yet), so the "not connected"
/// gate presents this sheet directly. It verifies the connection before saving, then
/// refreshes the library so the player unlocks in place.
struct BatonConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicModel.self) private var model

    @State private var urlString = NavidromeConfig.serverURLString
    @State private var username = NavidromeConfig.username
    @State private var password = ""
    @State private var authMode: NavidromeAuthMode = NavidromeConfig.authMode
    @State private var connecting = false
    @State private var errorText: String?

    private var canConnect: Bool {
        !connecting
            && !urlString.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && (authMode == .apiKey || !username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your music").font(.title3.bold())
                Text("Baton plays your own library from any Navidrome or Subsonic-compatible server.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Picker("Sign in with", selection: $authMode) {
                    Text("Username & password").tag(NavidromeAuthMode.tokenSalt)
                    Text("API key").tag(NavidromeAuthMode.apiKey)
                }
                TextField("Server URL", text: $urlString, prompt: Text("https://music.example.com"))
                    .textContentType(.URL)
                if authMode == .tokenSalt {
                    TextField("Username", text: $username)
                }
                SecureField(authMode == .apiKey ? "API key" : "Password", text: $password)
            }
            .formStyle(.grouped)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if connecting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(connecting ? "Connecting…" : "Connect") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func connect() async {
        connecting = true
        errorText = nil
        defer { connecting = false }
        do {
            _ = try await NavidromeConfig.verify(
                urlString: urlString, username: username, secret: password, authMode: authMode)
            // Add to the server list (rather than overwriting a single slot) and
            // make it active. When there are no servers yet this is the first one,
            // preserving the original single-server connect behavior.
            let entry = NavidromeConfig.addServer(
                displayName: NavidromeConfig.defaultName(urlString: urlString, username: username),
                urlString: urlString, username: username, secret: password, authMode: authMode)
            NavidromeConfig.setActiveServer(id: entry.id)
            model.musicLibrary.refreshConnection()
            await model.musicLibrary.loadAlbums()
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
