import SwiftUI

/// Where the music friend is configured — the phone's answer to the Mac's
/// "Natural language" section in Settings → Remote control.
///
/// Same shape as the Mac: pick the dialect, paste a key, name a model and an API
/// base, then spend one real request proving it works. The phone adds the home-server
/// route, and one rule the Mac doesn't have: **the Friend tab stays hidden until that
/// test passes.** So this screen is not optional polish — it is the only door to the
/// feature, which is why it sits directly under Server in Settings rather than below
/// the playback preferences where nobody found it.
struct MusicFriendSettingsView: View {
    @Bindable var config: AgentConfig
    let model: MobileModel

    @State private var isTesting = false
    @State private var testResult: RemoteNaturalLanguage.TestOutcome?
    /// The friend's answer in the vocabulary every other service uses, so this screen reads
    /// like the others rather than like a special case.
    @State private var liveStatus: ServiceStatus = .unknown
    /// Secrets stay masked until a biometric challenge passes. An API key against a paid
    /// model provider is money; leaving it readable to anyone holding an unlocked phone is
    /// the one thing on this screen worth a prompt.
    @State private var secretsUnlocked = false

    var body: some View {
        Form {
            Section {
                Picker("Answers come from", selection: Binding(
                    get: { config.route },
                    set: { config.route = $0; testResult = nil }
                )) {
                    ForEach(AgentConfig.Route.allCases) { route in
                        Text(route.label).tag(route)
                    }
                }
            } footer: {
                Text(config.route == .gateway
                     ? "Your Baton gateway runs the conversation against your own library, so your key never leaves home. Baton falls back to the model provider below if the server can't be reached."
                     : "This phone talks to the model provider directly and drives its own player.")
            }

            if config.route == .gateway { gatewaySection }
            providerSection
            testSection
            privacySection
        }
        .navigationTitle("Music Friend")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private var gatewaySection: some View {
        Section {
            TextField("https://baton.home.example", text: $config.gatewayURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if secretsUnlocked {
                SecureField("Gateway token", text: $config.gatewayToken)
            } else {
                LockedSecretRow(label: "Gateway token", isSet: !config.gatewayToken.isEmpty) {
                    await unlockSecrets()
                }
            }
        } header: {
            Text("Home server")
        } footer: {
            Text("The address and token from your gateway's configuration \u{2014} just the host and port, such as http://192.0.2.10:8788. Unlike the model provider below, this one does not want a /v1 on the end, and Baton will drop one if you paste it.")
        }
    }

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: Binding(
                get: { config.provider },
                set: { config.switchProvider(to: $0); testResult = nil }
            )) {
                ForEach(RemoteControlSettings.LLMProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            if secretsUnlocked {
                SecureField(config.provider.keyPlaceholder, text: $config.apiKey)
            } else {
                LockedSecretRow(label: "API key", isSet: !config.apiKey.isEmpty) {
                    await unlockSecrets()
                }
            }
            // `LabeledContent`, matching the Transcription section next door. These were
            // plain fields using their label as a placeholder, and the provider defaults
            // fill both — so in practice they were two rows of raw values with nothing
            // saying what either one was (I-F15).
            LabeledContent("Model") {
                TextField("claude-haiku-4-5", text: $config.model)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("API base URL") {
                TextField("https://host/v1", text: $config.baseURL)
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text(config.route == .gateway ? "Model provider (fallback)" : "Model provider")
        } footer: {
            Text(config.provider.hint)
        }
    }

    private var testSection: some View {
        Section {
            // Every other configurable service on this phone says whether it works without
            // being asked — the server and Whisper on the Settings list, both scrobblers on
            // theirs. The friend was the only one that made you find a button, which is
            // exactly as informative as no badge at all if you do not know the button is
            // there.
            //
            // **Not keyed on the fingerprint, and that was a real bug**. This was
            // `.task(id: config.fingerprint)`, reasoning that the fingerprint is "the
            // configuration that would need re-testing" — true, but every input to it
            // (`apiKey`, `model`, `baseURL`, `gatewayURL`) is two-way bound to a field on
            // *this screen*. So the fingerprint changed on every keystroke, the task
            // restarted, and typing or pasting a 40-character key fired up to 40 real
            // requests at a paid provider. Cost was the entire argument for keying, and the
            // keying spent more than checking on appear ever would have.
            //
            // On appear, and only when there is something to learn: configured, and not
            // already proven. That is one request per visit *while unverified* — which is
            // precisely the state where the answer is worth paying for, and is bounded by
            // the user opening a screen rather than by their typing speed. A verified
            // configuration shows its badge and spends nothing; editing spends nothing until
            // you ask.
            ServiceStatusRow(status: liveStatus) { Task { await refreshStatus() } }
                .task {
                    guard config.isConfigured, !config.isReady else { return }
                    await refreshStatus()
                }

            Button {
                runTest()
            } label: {
                HStack {
                    if isTesting {
                        ProgressView().controlSize(.small)
                        Text("Testing…")
                    } else {
                        Text("Test connection")
                    }
                    Spacer()
                    readinessBadge
                }
            }
            .disabled(isTesting || !config.isConfigured)

            if let testResult { resultRow(testResult) }
        } footer: {
            Text(config.route == .gateway
                 ? "Asks your server what's playing: a read-only question that exercises the whole path. The Friend tab appears once it answers, and hides again if you change anything here."
                 : "Sends one short request (\u{201C}pause the music\u{201D}) the same way a message would, so a pass means the next message will work, not just that something answered. Nothing is played or paused. The Friend tab appears once it passes, and hides again if you change anything here.")
        }
    }

    private var privacySection: some View {
        Section {
            Label("""
            The music friend is the one part of Baton that talks to a model provider. \
            What it finds while looking around — song titles, artists, genres — goes to \
            whichever endpoint is set above, along with your message. Point the base URL \
            at a model on your own machine, or use your home server, and that stops being \
            true. Keys are stored in the Keychain.
            """, systemImage: "hand.raised")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var readinessBadge: some View {
        if config.isReady {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.footnote)
                .foregroundStyle(.green)
        } else if config.isConfigured {
            Text("Not tested yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultRow(_ outcome: RemoteNaturalLanguage.TestOutcome) -> some View {
        switch outcome {
        case let .ok(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }

    private func unlockSecrets() async {
        secretsUnlocked = await BiometricGate.authenticate(
            reason: "Unlock your music friend's API key"
        )
    }

    /// One request, and the same one the button spends — so a green row here means exactly
    /// what a green row means anywhere else in Settings: it was asked, just now, and it
    /// answered. Never derived from a key being present.
    private func refreshStatus() async {
        guard config.isConfigured else {
            liveStatus = .notConfigured("Not set up yet")
            return
        }
        // A configuration that has already passed shows what it earned, without spending
        // another request to re-learn it. This is not the derived-green `ServiceStatus`
        // warns about: the fingerprint means a real request succeeded against exactly these
        // values, and any edit clears it.
        if config.isReady, case .unknown = liveStatus {
            liveStatus = .ok(detail: "Tested and working.")
            return
        }
        liveStatus = .checking
        liveStatus = await model.agent.connectionStatus()
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        liveStatus = .checking
        Task {
            // A test result belongs to the configuration that produced it, and the
            // client records that pairing itself — this view never marks anything ready.
            let outcome = await model.agent.runConnectionTest()
            testResult = outcome
            // Keep the badge and the prose from disagreeing. Two surfaces describing one
            // request, both fed from it, so there is no state where the row says "Connected"
            // over a result that says otherwise.
            liveStatus = {
                switch outcome {
                case let .ok(detail): .ok(detail: detail)
                case let .failed(why):
                    AgentClient.looksLikeACredentialProblem(why) ? .refused(why) : .unreachable(why)
                }
            }()
            isTesting = false
        }
    }
}


/// A masked stand-in for a secret field, with an unlock affordance.
///
/// Shows *whether* a secret is set without showing it: "not set" is information the user
/// needs to debug their setup, and it isn't sensitive.
private struct LockedSecretRow: View {
    let label: String
    let isSet: Bool
    let unlock: () async -> Void

    @State private var isAuthenticating = false

    var body: some View {
        Button {
            Task {
                isAuthenticating = true
                await unlock()
                isAuthenticating = false
            }
        } label: {
            HStack {
                Label(label, systemImage: "lock.fill")
                Spacer()
                if isAuthenticating {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isSet ? "••••••••" : "Not set")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospaced())
                }
            }
        }
        .accessibilityLabel("\(label), \(isSet ? "set" : "not set"). Unlock to view or change.")
    }
}
