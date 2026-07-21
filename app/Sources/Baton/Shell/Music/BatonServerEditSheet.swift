import SwiftUI

/// Add/edit a single server. Lifts the connection fields from `BatonConnectSheet`;
/// verifies before saving. On save it makes the server active and refreshes the
/// library (same dance as the connect sheet), then calls `onSaved`.
struct BatonServerEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicModel.self) private var model

    /// nil = adding a new server; non-nil = editing that server.
    let existing: NavidromeServerEntry?
    let onSaved: () -> Void

    @State private var displayName: String
    @State private var urlString: String
    @State private var username: String
    @State private var password: String
    @State private var authMode: NavidromeAuthMode
    @State private var connecting = false
    @State private var errorText: String?

    init(existing: NavidromeServerEntry?, onSaved: @escaping () -> Void) {
        self.existing = existing
        self.onSaved = onSaved
        _displayName = State(initialValue: existing?.displayName ?? "")
        _urlString = State(initialValue: existing?.urlString ?? "")
        _username = State(initialValue: existing?.username ?? "")
        _password = State(initialValue: "")
        _authMode = State(initialValue: existing?.authMode ?? .tokenSalt)
    }

    private var canSave: Bool {
        !connecting
            && !urlString.trimmingCharacters(in: .whitespaces).isEmpty
            // Editing may keep the existing password (blank = unchanged); adding requires one.
            && (existing != nil || !password.isEmpty)
            && (authMode == .apiKey || !username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add a server" : "Edit server").font(.title3.bold())

            Form {
                TextField("Name", text: $displayName, prompt: Text("My Server"))
                Picker("Sign in with", selection: $authMode) {
                    Text("Username & password").tag(NavidromeAuthMode.tokenSalt)
                    Text("API key").tag(NavidromeAuthMode.apiKey)
                }
                .pickerStyle(.menu)
                TextField("Server URL", text: $urlString, prompt: Text("https://music.example.com"))
                    .textContentType(.URL)
                if authMode == .tokenSalt {
                    TextField("Username", text: $username)
                }
                SecureField(
                    passwordPrompt,
                    text: $password
                )
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
                Button(connecting ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var passwordPrompt: String {
        let base = authMode == .apiKey ? "API key" : "Password"
        // When editing, a blank field means "keep current secret".
        return existing != nil ? "\(base) (leave blank to keep)" : base
    }

    private func save() async {
        connecting = true
        errorText = nil
        defer { connecting = false }

        // Editing with a blank password reuses the stored secret; otherwise the
        // typed one. Verify against whichever we'll persist.
        let effectiveSecret: String
        if let existing, password.isEmpty {
            effectiveSecret = NavidromeKeychain.secret(
                account: NavidromeConfig.keychainAccount(for: existing.id)) ?? ""
        } else {
            effectiveSecret = password
        }

        do {
            _ = try await NavidromeConfig.verify(
                urlString: urlString, username: username, secret: effectiveSecret, authMode: authMode)

            let name = displayName.trimmingCharacters(in: .whitespaces).isEmpty
                ? NavidromeConfig.defaultName(urlString: urlString, username: username)
                : displayName.trimmingCharacters(in: .whitespaces)

            let targetID: UUID
            if let existing {
                NavidromeConfig.updateServer(
                    id: existing.id,
                    displayName: name,
                    urlString: urlString,
                    username: username,
                    authMode: authMode,
                    secret: password.isEmpty ? nil : password
                )
                targetID = existing.id
            } else {
                let entry = NavidromeConfig.addServer(
                    displayName: name,
                    urlString: urlString,
                    username: username,
                    secret: password,
                    authMode: authMode
                )
                targetID = entry.id
            }

            // Make the just-saved server active and re-point the library. selectServer only
            // wipes the queue when the active server actually changes, so editing the current
            // server's credentials doesn't interrupt playback. (W-63)
            await model.selectServer(id: targetID)
            onSaved()
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
