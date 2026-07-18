import SwiftUI

/// Manages the list of Navidrome/Subsonic servers Baton can connect to, and which
/// one is active. Switching the active server refreshes the library so the player
/// re-points in place — the same connect/reload dance the connect sheet does.
///
/// Add/Edit reuse the connection fields lifted from `BatonConnectSheet` (see
/// `BatonServerEditSheet` below), verifying before saving.
struct BatonServerListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicModel.self) private var model

    @State private var servers: [NavidromeServerEntry] = NavidromeConfig.servers()
    @State private var activeID: UUID? = NavidromeConfig.activeServerID()
    @State private var editing: EditTarget?
    @State private var pendingDelete: NavidromeServerEntry?

    /// Which server the edit sheet is editing — `.new` to add, `.existing` to edit.
    private enum EditTarget: Identifiable {
        case new
        case existing(NavidromeServerEntry)
        var id: String {
            switch self {
            case .new: return "new"
            case let .existing(entry): return entry.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Servers").font(.title3.bold())
                Text("Switch between your music servers, or add another.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if servers.isEmpty {
                VStack(spacing: 8) {
                    Text("No servers yet.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(servers) { server in
                        row(for: server)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 180)
            }

            HStack {
                Button {
                    editing = .new
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                BatonServerEditSheet(existing: nil) { reload() }
            case let .existing(entry):
                BatonServerEditSheet(existing: entry) { reload() }
            }
        }
        .confirmationDialog(
            "Remove this server?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { server in
            Button("Remove \(server.displayName)", role: .destructive) {
                remove(server)
            }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Baton will forget \(server.displayName) and its saved password.")
        }
    }

    @ViewBuilder
    private func row(for server: NavidromeServerEntry) -> some View {
        let isActive = server.id == activeID
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .accessibilityLabel(isActive ? "Active" : "Inactive")
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName).font(.body.weight(isActive ? .semibold : .regular))
                Text(subtitle(for: server)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if !isActive {
                    Button("Make Active") { switchTo(server) }
                }
                Button("Edit…") { editing = .existing(server) }
                Divider()
                Button("Remove…", role: .destructive) { pendingDelete = server }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive { switchTo(server) }
        }
    }

    private func subtitle(for server: NavidromeServerEntry) -> String {
        let host = URL(string: server.urlString)?.host ?? server.urlString
        if server.authMode == .apiKey { return host }
        return server.username.isEmpty ? host : "\(server.username) · \(host)"
    }

    // MARK: - Actions

    private func reload() {
        servers = NavidromeConfig.servers()
        activeID = NavidromeConfig.activeServerID()
    }

    private func switchTo(_ server: NavidromeServerEntry) {
        NavidromeConfig.setActiveServer(id: server.id)
        activeID = NavidromeConfig.activeServerID()
        model.musicLibrary.refreshConnection()
        Task { await model.musicLibrary.loadAlbums() }
    }

    private func remove(_ server: NavidromeServerEntry) {
        let wasActive = server.id == activeID
        NavidromeConfig.removeServer(id: server.id)
        reload()
        pendingDelete = nil
        // If the active server changed (or is now gone), re-point the library.
        if wasActive {
            model.musicLibrary.refreshConnection()
            Task { await model.musicLibrary.loadAlbums() }
        }
    }
}

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

            // Make the just-saved server active and re-point the library.
            NavidromeConfig.setActiveServer(id: targetID)
            model.musicLibrary.refreshConnection()
            await model.musicLibrary.loadAlbums()
            onSaved()
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
