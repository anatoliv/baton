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

    var body: some View {
        Form {
            Section {
                SecureField("User token", text: $listenBrainzToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveListenBrainz)
                Button("Save token", action: saveListenBrainz)
                    .disabled(listenBrainzToken == model.listenBrainz.token)
                if model.listenBrainz.isEnabled {
                    Label("Scrobbling to ListenBrainz", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
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
                    Label("Connected to Last.fm", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
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
    }

    private func saveListenBrainz() {
        model.listenBrainz.token = listenBrainzToken.trimmingCharacters(in: .whitespaces)
    }

    private func saveLastfmCredentials() {
        model.lastfm.apiKey = lastfmKey.trimmingCharacters(in: .whitespaces)
        model.lastfm.apiSecret = lastfmSecret.trimmingCharacters(in: .whitespaces)
    }
}
