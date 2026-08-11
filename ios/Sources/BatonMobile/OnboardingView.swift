import SwiftUI

/// First-run server connection. Verifies the connection (which authenticates) before
/// saving anything, and auto-upgrades to API-key auth when the server advertises it —
/// the same probe-then-save flow the Mac app's settings use, via `NavidromeConfig.verify`.
struct OnboardingView: View {
    var onConnected: () -> Void
    /// Nil hides the demo entry — Settings reuses this screen to *change* servers,
    /// where offering the demo instead would make no sense.
    var onTryDemo: (() -> Void)?
    /// Nil on first run, where there is deliberately no way out: the app cannot do
    /// anything without a server, so the screen refuses to be dismissed and offers the
    /// demo instead. Non-nil when Settings presents it to *change* servers — that user
    /// already has a working app, and opening this screen used to trap them in it with
    /// no Cancel, no back button and interactive dismissal switched off.
    var onCancel: (() -> Void)?

    @State private var urlString = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var authMode: NavidromeAuthMode = .tokenSalt
    @State private var isConnecting = false
    @State private var errorText: String?
    @State private var headerName = ""
    @State private var headerValue = ""
    /// Trying the public demo is a "just show me" action, so it checks and connects rather
    /// than filling the form and leaving the work to you. These two drive that.
    @State private var isCheckingDemoServer = false
    @State private var demoServerUnavailable: String?

    var body: some View {
        NavigationStack {
            Form {
                // The first screen anyone sees — it should carry Baton's identity,
                // not open cold on a URL field.
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            // Smaller than it was: the mark is decoration, and at 88pt it
                            // pushed everything actionable off the first screenful.
                            .frame(width: 64, height: 64)
                            .background(
                                LinearGradient(
                                    colors: [Color.batonOrange, Color.brandPressed],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 22)
                            )
                            .shadow(color: Color.brandMuted, radius: 16, y: 6)
                        Text("Your music, your server.")
                            .font(.headline)
                        Text("Baton plays your Navidrome library — gapless, offline, and with a music friend to talk to.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                // Above the form, not below it.
                //
                // Both of these *fill in* the fields underneath — one from a Mac, one from
                // Navidrome's public server — so they belong before the thing they fill.
                // They were at the bottom, after a form that already fills the screen, which
                // put the two routes for someone with nothing to type where only someone who
                // had scrolled past a form they couldn't complete would ever find them.
                // The fastest path for anyone who already runs Baton on a Mac: every
                // field on this screen fills itself in. This used to offer only the
                // scanner, which needs both devices on one network — leaving anyone
                // whose Mac is elsewhere to type a URL, a username and a long password
                // into a phone keyboard, with the file route sitting unmentioned.
                if let holder = AppServicesHolder.model {
                    Section {
                        NavigationLink {
                            MacTransferView(model: holder, onImported: onConnected)
                        } label: {
                            Label("Set up from a Mac", systemImage: "laptopcomputer.and.iphone")
                        }
                    } footer: {
                        Text("Scan the code your Mac shows, or import a settings file it exported. Either way your server address and sign-in come across for you.")
                    }
                }

                // The built-in demo proves the app runs; it cannot show what the app is
                // for, which is a real library over a real connection. This fills the
                // fields rather than connecting outright, so you can see exactly what a
                // Navidrome sign-in looks like — and it is the same Connect button doing
                // the same work, not a second path that could rot separately.
                Section {
                    Button {
                        Task { await usePublicDemoServer() }
                    } label: {
                        HStack {
                            Text(isCheckingDemoServer
                                 ? "Checking the demo server…"
                                 : "Use Navidrome's public demo server")
                            if isCheckingDemoServer {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isCheckingDemoServer || isConnecting)

                    // Offered only once the public server has actually failed, and only on
                    // first run — Settings reuses this screen to *change* servers, where
                    // falling back to a bundled demo would be a strange thing to suggest.
                    if demoServerUnavailable != nil, let onTryDemo {
                        Button("Use the built-in demo instead") { onTryDemo() }
                    }
                } footer: {
                    if let reason = demoServerUnavailable {
                        Text("Navidrome's demo server isn't answering right now — \(reason) "
                             + "It's their server, not ours, so this happens. The built-in demo "
                             + "works with no connection at all.")
                        .foregroundStyle(Color.warningTint)
                    } else {
                        Text(NavidromePublicDemo.caveat)
                    }
                }

                Section {
                    TextField("https://music.example.com", text: $urlString)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    if NavidromeConfig.isInsecure(urlString) {
                        Text("This is a plain-HTTP address — fine on your home network, not on the open internet.")
                    }
                }

                Section("Account") {
                    Picker("Sign in with", selection: $authMode) {
                        Text("Username & password").tag(NavidromeAuthMode.tokenSalt)
                        Text("API key").tag(NavidromeAuthMode.apiKey)
                    }
                    if authMode == .tokenSalt {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $secret)
                            .textContentType(.password)
                    } else {
                        SecureField("API key", text: $secret)
                    }
                }

                DisclosureGroup("Advanced") {
                    TextField("Header name (e.g. CF-Access-Client-Id)", text: $headerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Header value", text: $headerValue)
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        if isConnecting {
                            HStack { ProgressView(); Text("Connecting…") }
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(isConnecting || urlString.isEmpty || secret.isEmpty)
                }

                // Arriving here because a password stopped working is a different event
                // from arriving here on a fresh install, and saying so saves someone
                // wondering what happened to their library.
                if AppServicesHolder.model?.credentialsRejected == true {
                    Section {
                        Label("Your server didn't accept the saved sign-in. Your downloads and settings are still here — just sign in again.",
                              systemImage: "exclamationmark.lock")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // Baton is useless without a server, which makes the first run a wall
                // for anyone who hasn't set Navidrome up yet — and for App Review,
                // who never will. The demo is a real library, playing through the
                // real engine, with nothing to connect to.
                if let onTryDemo, DemoLibrary.isAvailable {
                    Section {
                        Button("Try the demo") { onTryDemo() }
                    } footer: {
                        Text("Explore Baton with a few sample tracks built into the app. "
                             + "You can connect your own server any time from Settings.")
                    }
                }

            }
            .navigationTitle("Connect to Navidrome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { onCancel() }
                    }
                }
            }
        }
        .readableWidth()
        // Only the first run is a dead end on purpose.
        .interactiveDismissDisabled(onCancel == nil)
    }

    /// Fills in Navidrome's public demo and signs in, or says why it couldn't.
    ///
    /// This used to only populate the fields and leave you to press Connect. For someone
    /// with no server that is a step that teaches nothing — and when the demo server was
    /// down it failed as a bare error under the sign-in form, with no hint that the
    /// built-in demo would have worked. Now the outcome is one of two clear ones: you are
    /// in, or you are told it's their server that's down and offered the offline demo.
    /// The public demo's address, overridable in DEBUG so the *failure* path can be
    /// tested. Otherwise the only way to exercise "their server is down" is to wait for
    /// their server to go down.
    private var publicDemoURL: String {
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uitestPublicDemoURL"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            return ProcessInfo.processInfo.arguments[index + 1]
        }
        #endif
        return NavidromePublicDemo.url
    }

    private func usePublicDemoServer() async {
        isCheckingDemoServer = true
        demoServerUnavailable = nil
        errorText = nil

        urlString = publicDemoURL
        username = NavidromePublicDemo.username
        secret = NavidromePublicDemo.password
        authMode = .tokenSalt

        do {
            // Short timeout on purpose: this is a "does it answer" probe, and someone
            // deciding whether to bother with the app should not watch a spinner for a
            // minute to find out the answer was no.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            _ = try await NavidromeConfig.verify(
                urlString: publicDemoURL,
                username: NavidromePublicDemo.username,
                secret: NavidromePublicDemo.password,
                authMode: .tokenSalt,
                session: URLSession(configuration: configuration)
            )
            isCheckingDemoServer = false
            connect()
        } catch {
            isCheckingDemoServer = false
            demoServerUnavailable = ServerStatus.describe(error)
        }
    }

    private func connect() {
        isConnecting = true
        errorText = nil
        let url = urlString
        let user = username
        let pass = secret
        let mode = authMode
        Task {
            do {
                let name = headerName.trimmingCharacters(in: .whitespaces)
                let headers: [String: String] = name.isEmpty ? [:] : [name: headerValue]
                _ = try await NavidromeConfig.verify(
                    urlString: url, username: user, secret: pass, authMode: mode, customHeaders: headers
                )
                NavidromeConfig.save(urlString: url, username: user, secret: pass, authMode: mode)
                if !headers.isEmpty { NavidromeConfig.setCustomHeaders(headers) }
                isConnecting = false
                onConnected()
            } catch {
                isConnecting = false
                errorText = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
