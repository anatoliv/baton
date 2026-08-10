import AppKit
import SwiftUI

/// Settings → Remote. Connect a Telegram and/or Discord bot, authorize the chats
/// that may drive playback, and optionally switch on natural language.
struct BatonRemotePane: View {
    @Environment(RemoteControlService.self) private var service: RemoteControlService?

    var body: some View {
        if let service {
            RemoteSettingsForm(service: service)
        } else {
            Form {
                Section("Remote control") {
                    Text("Remote control starts with the main player window. Open Baton's window and come back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct RemoteSettingsForm: View {
    let service: RemoteControlService

    // Tokens are edited as drafts and saved explicitly: binding them straight
    // through would rewrite the Keychain on every keystroke, and a live socket
    // keeps using the token it authenticated with until it's restarted anyway.
    @State private var telegramToken = ""
    @State private var discordToken = ""
    @State private var apiKey = ""
    @State private var discordChannels = ""
    @State private var isTesting = false
    @State private var testResult: RemoteNaturalLanguage.TestOutcome?

    var body: some View {
        @Bindable var settings = service.settings

        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 30)).foregroundStyle(.tint).frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote control").font(.title3.bold())
                        Text("Drive Baton from Telegram or Discord — play, skip, queue, set the volume — from anywhere you can send a message.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)

                Toggle("Enable remote control", isOn: $settings.isEnabled)
                    .onChange(of: settings.isEnabled) { _, _ in service.apply() }
            }

            platformSection(.telegram, token: $telegramToken)
            platformSection(.discord, token: $discordToken)

            linkingSection
            deviceLinkSection
            SharedSettingsPane()
            naturalLanguageSection

            Section("Privacy") {
                Text("""
                Baton connects out to Telegram and Discord; it never opens a port and nothing \
                on your network is exposed. Bot tokens and any API key live in your login \
                Keychain. Natural language is the only feature that contacts a third party.

                It sends the sentence you typed and the list of Baton's own commands — never \
                your credentials, and never your listening history. Whether it sends anything \
                *from* your library is decided by one setting: with "let it look around" off, \
                it never does; with it on, what it looks up travels with the question, because \
                that is how it can answer at all.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            telegramToken = service.settings.telegram.token
            discordToken = service.settings.discord.token
            apiKey = service.settings.naturalLanguage.apiKey
            discordChannels = service.settings.discord.allowedChannels.sorted().joined(separator: ", ")
        }
    }

    // MARK: Platform

    @ViewBuilder
    private func platformSection(_ platform: RemotePlatform, token: Binding<String>) -> some View {
        @Bindable var settings = service.settings
        let config = settings.config(for: platform)

        Section(platform.label) {
            Toggle("Enable \(platform.label)", isOn: Binding(
                get: { settings.config(for: platform).isEnabled },
                set: { newValue in
                    var updated = settings.config(for: platform)
                    updated.isEnabled = newValue
                    settings.setConfig(updated, for: platform)
                    service.apply()
                }
            ))

            LabeledContent("Bot token") {
                HStack {
                    SecureField("", text: token, prompt: Text("paste token"))
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { save(token: token.wrappedValue, for: platform) }
                        .disabled(token.wrappedValue == config.token)
                }
            }
            Text(platform.tokenHint)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Status") { statusLabel(settings.state[platform] ?? .off) }

            if config.isConfigured {
                Button("Reconnect") { service.restart(platform) }
            }

            if platform == .discord {
                LabeledContent("Limit to channels") {
                    HStack {
                        TextField("", text: $discordChannels, prompt: Text("any channel"))
                            .textFieldStyle(.roundedBorder)
                        Button("Save") { saveDiscordChannels() }
                    }
                }
                Text("Comma-separated channel ids. Leave empty to accept any channel the bot can see — authorized people only, either way.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            authorizationRows(platform)
        }
    }

    /// The code is one shared value across platforms, so it gets one section
    /// rather than a copy inside each: two "New code" buttons that both
    /// regenerate the same code read as two independent codes.
    @ViewBuilder
    private var linkingSection: some View {
        let settings = service.settings

        Section("Linking") {
            LabeledContent("Link code") {
                HStack {
                    Text(settings.linkCode)
                        .font(.title3.monospaced().bold())
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(settings.linkCode, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                    Button("New code") { settings.regenerateLinkCode() }
                        .buttonStyle(.borderless)
                }
            }
            Text("""
            Message your bot `/link \(settings.linkCode)` from the chat you want to control \
            Baton with — on either service. Until you do it ignores everyone, because a bot \
            token on its own grants nothing. Each code works once.
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func authorizationRows(_ platform: RemotePlatform) -> some View {
        let settings = service.settings
        let senders = settings.config(for: platform).allowedSenders.sorted()

        if senders.isEmpty {
            // The code lives in its own section below (one shared value, one
            // regenerate button), but "no chats authorized" is read *here*, right
            // after a token connects — and an empty state that doesn't say what to
            // do next just reads as something being broken. So the next step goes
            // where the problem is noticed, without duplicating the control.
            Label("No chats authorized yet", systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(Color.warningTint)
            Text("Send your bot `/link \(settings.linkCode)` from the chat you want to use.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            ForEach(senders, id: \.self) { sender in
                LabeledContent("Authorized") {
                    HStack {
                        Text(sender).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Button("Revoke") { settings.revoke(sender: sender, on: platform) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: Natural language

    /// QR pairing for a phone. Sits beside the other linking concerns rather than in the
    /// server pane, because what it links is a *device*, not another account.
    private var deviceLinkSection: some View {
        Section("Devices") {
            DeviceLinkPane()
        }
    }

    @ViewBuilder
    private var naturalLanguageSection: some View {
        @Bindable var settings = service.settings

        Section("Natural language") {
            Toggle("Understand plain English", isOn: $settings.naturalLanguage.isEnabled)
            Text("""
            Anything Baton doesn't recognize as a command gets read as intent — "put on \
            something mellow", "make me a 40-minute driving mix". Off by default; it needs \
            an API key and is the one part of Baton that talks to a model provider.
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: Binding(
                get: { settings.naturalLanguage.provider },
                set: { switchProvider(to: $0) }
            )) {
                ForEach(RemoteControlSettings.LLMProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            Text(settings.naturalLanguage.provider.hint)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("API key") {
                HStack {
                    SecureField("", text: $apiKey, prompt: Text(settings.naturalLanguage.provider.keyPlaceholder))
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { settings.naturalLanguage.apiKey = apiKey }
                        .disabled(apiKey == settings.naturalLanguage.apiKey)
                }
            }
            TextField("Model", text: $settings.naturalLanguage.model)
            TextField("API base URL", text: $settings.naturalLanguage.baseURL)

            LabeledContent("Connection") {
                HStack(spacing: 10) {
                    Button(isTesting ? "Testing…" : "Test") { runTest() }
                        .disabled(isTesting || !settings.naturalLanguage.isConfigured)
                    testResultLabel
                }
            }
            Text("Sends one short request (\u{201C}pause the music\u{201D}) the same way a chat message would, so a pass means the next message will work \u{2014} not just that something answered.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Let it look around first", isOn: $settings.naturalLanguage.isAgentEnabled)
                .disabled(!settings.naturalLanguage.isEnabled)
            Text("""
            Without this, one message becomes one command, decided blind — ask for "lazy \
            music" and you get "nothing matched", even when the same music is sitting there \
            tagged "chill". With it on, Baton can search, read your genres and liked songs, \
            try again with better words, and offer you a choice when two answers are both \
            reasonable.
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Remember what you tell it", isOn: $settings.naturalLanguage.remembersOwner)
                .disabled(!settings.naturalLanguage.isAgentEnabled)
            Text("""
            Standing preferences you state in the chat — "no vocals while I'm working", \
            "the gothic playlists are my partner's" — kept in a plain file you can open, \
            and used to answer better next time. It stores your own words, never a guess \
            about you, and it tells you in the chat every time it writes one. Send \
            `memories` to see everything it keeps and `forget 2` to remove one.
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Stored memories") {
                Button("Delete all…") { service.forgetEverythingRemembered() }
                    .disabled(!settings.naturalLanguage.isAgentEnabled)
            }

            Label("""
            This is the setting that changes what leaves your Mac. Looking around means \
            what it finds \u{2014} song titles, artists, genres \u{2014} goes to the model \
            provider along with your message. Point the base URL at a model running on your \
            own machine and nothing leaves it at all.
            """, systemImage: "hand.raised")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var testResultLabel: some View {
        switch testResult {
        case .none:
            EmptyView()
        case let .ok(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Switching dialect carries the URL and model with it — but only when they
    /// were still the *other* dialect's defaults. Someone who typed their own
    /// endpoint or model chose it deliberately, and having a picker silently
    /// overwrite that would be worse than leaving a value that needs editing.
    private func switchProvider(to provider: RemoteControlSettings.LLMProvider) {
        var config = service.settings.naturalLanguage
        let previous = config.provider
        guard previous != provider else { return }

        if config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            || config.baseURL == previous.defaultBaseURL {
            config.baseURL = provider.defaultBaseURL
        }
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty
            || config.model == previous.defaultModel {
            config.model = provider.defaultModel
        }
        config.provider = provider
        service.settings.naturalLanguage = config
        testResult = nil // a result from the old dialect says nothing about this one
    }

    private func runTest() {
        let config = service.settings.naturalLanguage
        isTesting = true
        testResult = nil
        Task {
            let tools = RemoteNaturalLanguage.toolSchemas(from: BatonMCPToolCatalog.definitions())
            let outcome = await RemoteNaturalLanguage.test(config: config, tools: tools)
            testResult = outcome
            isTesting = false
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func statusLabel(_ state: RemoteConnectionState) -> some View {
        switch state {
        case .off:
            Label("Not connected", systemImage: "circle").foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(Color.warningTint)
        case let .connected(account):
            Label(account, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func save(token: String, for platform: RemotePlatform) {
        var config = service.settings.config(for: platform)
        config.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        service.settings.setConfig(config, for: platform)
        service.restart(platform) // a live socket keeps using its old token
    }

    private func saveDiscordChannels() {
        var config = service.settings.discord
        config.allowedChannels = Set(
            discordChannels
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        service.settings.discord = config
    }
}
