import SwiftUI

/// Setting up ListenBrainz and Last.fm on the phone.
///
/// Both engines already ran here — every play was being scrobbled to whatever the shared
/// stores held. But the only way to *fill* those stores was to bring a Mac's settings
/// across (now `MacTransferView`), which meant a phone-first user silently scrobbled
/// nowhere and had no way to find out why. This screen is that missing half.
///
/// Navidrome's own scrobble isn't listed: it needs no setup, it's implied by having a
/// server, and offering a switch for it would suggest it were optional here.
struct ScrobbleSettingsView: View {
    let model: MobileModel

    @State private var listenBrainzToken = ""
    @State private var lastfmKey = ""
    @State private var lastfmSecret = ""
    @State private var awaitingLastfmAuth = false
    /// Whether ListenBrainz accepts this token. It used to be a green tick for any non-empty
    /// string, which made a typo look exactly like a working account — and the only place
    /// that difference showed up was a profile page with no listens on it.
    @State private var listenBrainzStatus: ServiceStatus = .unknown
    /// And whether Last.fm still accepts the stored session. A session key only exists because
    /// someone completed the browser authorization, which is a better claim than a pasted
    /// token — but it is still a fact about the past, and one revoked from Last.fm's own
    /// settings page leaves this screen saying "connected" while every scrobble is refused.
    @State private var lastFMStatus: ServiceStatus = .unknown

    var body: some View {
        Form {
            Section {
                SecureField("User token", text: $listenBrainzToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveListenBrainz)
                Button("Save token", action: saveListenBrainz)
                    .disabled(listenBrainzToken == model.listenBrainz.token)
                ServiceStatusRow(status: listenBrainzStatus) { Task { await checkListenBrainz() } }
            } header: {
                Text("ListenBrainz")
            } footer: {
                Text("Your user token from listenbrainz.org → Settings. Stored in the Keychain.")
            }

            Section {
                TextField("API key", text: $lastfmKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Shared secret", text: $lastfmSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save credentials", action: saveLastfmCredentials)
                    .disabled(lastfmKey == model.lastfm.apiKey && lastfmSecret == model.lastfm.apiSecret)

                if model.lastfm.isConnected {
                    ServiceStatusRow(status: lastFMStatus) { Task { await checkLastFM() } }
                    Button("Disconnect", role: .destructive) { model.lastfm.disconnect() }
                } else {
                    // Two steps because Last.fm's flow is: get a token, have the user
                    // approve it in a browser, then exchange it. There is no callback
                    // back into the app, so the second step has to be a button.
                    Button("Authorize in browser…") {
                        Task {
                            await model.lastfm.beginAuth()
                            awaitingLastfmAuth = true
                        }
                    }
                    .disabled(!model.lastfm.hasCredentials)

                    if awaitingLastfmAuth {
                        Button("I've approved it — finish") {
                            Task {
                                await model.lastfm.completeAuth()
                                awaitingLastfmAuth = false
                            }
                        }
                    }
                }
            } header: {
                Text("Last.fm")
            } footer: {
                Text("Create an API account at last.fm/api, paste the key and secret, then authorize. The secret and session live in the Keychain.")
            }

            Section {
                LabeledContent("Waiting to send", value: "\(model.scrobbles.pendingCount)")
                Button("Send now") { model.scrobbles.flushAll() }
                    .disabled(model.scrobbles.pendingCount == 0)
            } header: {
                Text("Offline queue")
            } footer: {
                Text("Plays are queued when you're offline and sent when you're back — nothing is lost on the tube.")
            }
        }
        .navigationTitle("Scrobbling")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            listenBrainzToken = model.listenBrainz.token
            lastfmKey = model.lastfm.apiKey
            lastfmSecret = model.lastfm.apiSecret
        }
        .task { await checkListenBrainz() }
        .task { await checkLastFM() }
    }

    private func saveListenBrainz() {
        model.listenBrainz.token = listenBrainzToken.trimmingCharacters(in: .whitespaces)
        Task { await checkListenBrainz() }
    }

    /// One GET against `validate-token` — nothing is submitted, so this can run on appear
    /// and after every save.
    private func checkListenBrainz() async {
        listenBrainzStatus = .checking
        switch await model.listenBrainz.checkToken() {
        case .missing:
            listenBrainzStatus = .notConfigured("No token yet")
        case let .valid(user):
            listenBrainzStatus = .ok(detail: user.isEmpty ? "Scrobbling to ListenBrainz." : "Scrobbling as \(user).")
        case .rejected:
            listenBrainzStatus = .refused("ListenBrainz didn't accept this token. Copy it again from your profile.")
        case let .failed(why):
            listenBrainzStatus = .unreachable(why)
        }
    }

    /// Read-only: `user.getInfo` with the session key, never a listen.
    private func checkLastFM() async {
        lastFMStatus = .checking
        switch await model.lastfm.checkSession() {
        case .missing:
            lastFMStatus = .notConfigured("Not connected")
        case let .valid(user):
            lastFMStatus = .ok(detail: user.isEmpty ? "Connected to Last.fm." : "Scrobbling as \(user).")
        case .rejected:
            lastFMStatus = .refused("Last.fm no longer accepts this session. Authorize it again.")
        case let .failed(why):
            lastFMStatus = .unreachable(why)
        }
    }

    private func saveLastfmCredentials() {
        model.lastfm.apiKey = lastfmKey.trimmingCharacters(in: .whitespaces)
        model.lastfm.apiSecret = lastfmSecret.trimmingCharacters(in: .whitespaces)
    }
}
