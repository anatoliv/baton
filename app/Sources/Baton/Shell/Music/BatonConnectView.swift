import SwiftUI
import BatonSubsonicKit

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

    // The demo server's details and its failure copy live in `NavidromeDemoServer`, shared with
    // Settings → Add Server so the two entry points can't drift apart.

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
                Text("Baton plays your own library from your music server: Navidrome or any Subsonic-compatible server.")
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
                Label("This is an unencrypted (http) connection. Your \(authMode == .apiKey ? "API key" : "username and password") are sent in the clear. Prefer https unless this server is on your local network.", systemImage: "lock.open")
                    .font(.callout).foregroundStyle(Color.warningTint)
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
        authMode = NavidromeDemoServer.authMode
        urlString = NavidromeDemoServer.urlString
        username = NavidromeDemoServer.username
        password = NavidromeDemoServer.password
        errorText = nil
        focus = nil
    }

    /// Saves a verified connection (TBX-1000000504, A-22).
    ///
    /// The sheet opens filled in with the active server, so reconnecting is "type the secret,
    /// press Connect". Adding every time listed the server twice, each copy with its own Keychain
    /// secret. The same server, account and sign-in method now update the entry they already have
    /// (the active one, if there are several), keeping its name and any proxy headers; anything
    /// else, including a blank username, is a new server. A local helper over
    /// `updateServer`/`addServer`, because BatonSubsonicKit has no add-or-update of its own.
    @discardableResult
    static func saveConnection(urlString: String, username: String, secret: String,
                               authMode: NavidromeAuthMode) -> NavidromeServerEntry {
        let url = urlString.trimmingCharacters(in: .whitespaces)
        let user = username.trimmingCharacters(in: .whitespaces)
        func key(_ raw: String) -> String {
            var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        // A blank username identifies nobody: two API-key accounts on one server may both have
        // one, and merging them would overwrite the first account's key.
        let matches = user.isEmpty ? [] : NavidromeConfig.servers().filter {
            key($0.urlString) == key(url) && $0.authMode == authMode
                && $0.username.trimmingCharacters(in: .whitespaces) == user
        }
        // The active copy first, for anyone the old bug already gave duplicates: updating another
        // copy would read as a server change and clear the queue.
        let activeID = NavidromeConfig.activeServerID()
        if let existing = matches.first(where: { $0.id == activeID }) ?? matches.first {
            NavidromeConfig.updateServer(id: existing.id, displayName: existing.displayName, urlString: url,
                                         username: username, authMode: authMode, secret: secret)
            return NavidromeConfig.servers().first { $0.id == existing.id } ?? existing
        }
        return NavidromeConfig.addServer(
            displayName: NavidromeConfig.defaultName(urlString: urlString, username: username),
            urlString: urlString, username: username, secret: secret, authMode: authMode)
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
            //
            // Read the active server *before* adding: `addServer` makes the new one active
            // when none was, so asking afterwards always answers "nothing changed" and a
            // stale queue from a previous server survives into this connection.
            let previousActiveID = NavidromeConfig.activeServerID()
            let entry = Self.saveConnection(urlString: urlString, username: username,
                                            secret: password, authMode: authMode)
            await model.selectServer(id: entry.id, previousActiveID: previousActiveID)
            dismiss()
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Don't let someone else's downtime look like our bug: the demo is a public server we
            // don't run, and it's the very first thing a new user is invited to click.
            var message = NavidromeDemoServer.errorText(forURL: urlString, detail: detail)
            // There's no prior probe to consult here — `verify` only reaches the extensions
            // check after a successful ping, and an unsupported API key normally fails the
            // ping itself. So this is a hint from the failure's shape, not a probe result: a
            // classic Subsonic server rejects an API key exactly like a wrong password, and
            // the generic message alone doesn't say why.
            if authMode == .apiKey, !NavidromeDemoServer.matches(urlString),
               let navError = error as? NavidromeError, navError.isAuthFailure {
                message += " If this server doesn't support API key sign-in, try Username & password instead."
            }
            errorText = message
        }
    }
}
