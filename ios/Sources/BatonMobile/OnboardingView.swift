import SwiftUI

/// First-run server connection. Verifies the connection (which authenticates) before
/// saving anything, and auto-upgrades to API-key auth when the server advertises it —
/// the same probe-then-save flow the Mac app's settings use, via `NavidromeConfig.verify`.
struct OnboardingView: View {
    var onConnected: () -> Void
    /// Nil hides the demo entry — Settings reuses this screen to *change* servers,
    /// where offering the demo instead would make no sense.
    var onTryDemo: (() -> Void)?

    @State private var urlString = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var authMode: NavidromeAuthMode = .tokenSalt
    @State private var isConnecting = false
    @State private var errorText: String?
    @State private var headerName = ""
    @State private var headerValue = ""
    @State private var showsScanner = false

    var body: some View {
        NavigationStack {
            Form {
                // The first screen anyone sees — it should carry Baton's identity,
                // not open cold on a URL field.
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 88)
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

                // The fastest path for anyone who already runs Baton on a Mac: scan,
                // and every field on this screen fills itself in.
                Section {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("Scan a code from your Mac", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("On your Mac: Baton → Settings → Remote → Devices → Show pairing code. Both devices need to be on the same network.")
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
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showsScanner) {
            if let model = AppServicesHolder.model {
                PairingScannerView(model: model, onLinked: onConnected)
            }
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
