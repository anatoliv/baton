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
    /// Which field is focused on open — the URL, unless it's already prefilled, then the username.
    @FocusState private var focus: Field?

    private enum Field { case url, username, password }

    private var urlIsValid: Bool { NavidromeConfig.validatedURL(urlString) != nil }
    private var isInsecure: Bool { NavidromeConfig.isInsecure(urlString) }

    /// The public Navidrome demo, offered on first run so someone without a server of their own
    /// can still evaluate Baton. This is **third-party infrastructure** — the Navidrome project
    /// runs it for their own purposes and can take it down or change its sign-in without notice —
    /// so a failure against it is attributed explicitly rather than reading as a bug in Baton.
    static let demoHost = "demo.navidrome.org"

    /// Whether a URL points at the public demo. Matches on **host**, so a user who edited the
    /// scheme, port, or path still gets the demo-specific failure message. Static (not inlined
    /// into the view) so it can be unit-tested.
    static func isDemoServer(_ urlString: String) -> Bool {
        NavidromeConfig.validatedURL(urlString)?.host?.lowercased() == demoHost
    }

    private var isDemoTarget: Bool { Self.isDemoServer(urlString) }

    private var canConnect: Bool {
        !connecting
            && urlIsValid
            && !password.isEmpty
            && (authMode == .apiKey || !username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your music").font(.title3.bold())
                Text("Baton plays your own library from any Navidrome or Subsonic-compatible server.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // First-run help for the not-yet-self-hosting downloader.
                HStack(spacing: 12) {
                    Link("What's a Navidrome server?", destination: URL(string: "https://www.navidrome.org")!)
                    Button("Try the demo server") { fillDemo() }
                        .buttonStyle(.link)
                        .help("Fills the public Navidrome demo (read-only; availability isn't guaranteed)")
                }
                .font(.callout)
            }

            Form {
                Picker("Sign in with", selection: $authMode) {
                    Text("Username & password").tag(NavidromeAuthMode.tokenSalt)
                    Text("API key").tag(NavidromeAuthMode.apiKey)
                }
                TextField("Server URL", text: $urlString, prompt: Text("https://music.example.com"))
                    .textContentType(.URL)
                    .focused($focus, equals: .url)
                if authMode == .tokenSalt {
                    TextField("Username", text: $username)
                        .focused($focus, equals: .username)
                }
                SecureField(authMode == .apiKey ? "API key" : "Password", text: $password)
                    .focused($focus, equals: .password)
            }
            .formStyle(.grouped)

            if !urlString.trimmingCharacters(in: .whitespaces).isEmpty, !urlIsValid {
                Label("Enter a full server URL, including https:// (or http:// for a local server).", systemImage: "link")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isInsecure {
                Label("This is an unencrypted (http) connection — your \(authMode == .apiKey ? "API key" : "username and password") are sent in the clear. Prefer https unless this server is on your local network.", systemImage: "lock.open")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        .onAppear {
            // Land on the first empty field so the user can type immediately.
            focus = urlString.trimmingCharacters(in: .whitespaces).isEmpty ? .url
                : (authMode == .tokenSalt && username.isEmpty ? .username : .password)
        }
    }

    /// Prefill the public Navidrome demo so a curious downloader can evaluate Baton with no setup.
    /// It's a read-only public server whose availability isn't under our control.
    private func fillDemo() {
        authMode = .tokenSalt
        urlString = "https://\(Self.demoHost)"
        username = "demo"
        password = "demo"
        errorText = nil
        focus = nil
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
            await model.selectServer(id: entry.id)
            dismiss()
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Don't let someone else's downtime look like our bug: the demo is a public server we
            // don't run, and it's the very first thing a new user is invited to click.
            errorText = isDemoTarget
                ? "Couldn't reach the public Navidrome demo. That server is run by the Navidrome "
                    + "project, not by Baton, and it can be offline or change its sign-in at any "
                    + "time — connect your own server to get started. (\(detail))"
                : detail
        }
    }
}
