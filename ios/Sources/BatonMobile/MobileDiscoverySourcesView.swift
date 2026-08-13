import BatonPlaybackKit
import SwiftUI

/// Which outside services "Find More Like This" may ask, and what each one needs.
///
/// The phone had the master switch and nothing else, so the two keyed sources could never be
/// switched on from here: the results sheet said "add a Last.fm API key" about a field that
/// existed only on the Mac. This is that field, plus the two things the Mac did not have
/// either — a per-source switch, and a test that actually asks the service.
struct MobileDiscoverySourcesView: View {
    @AppStorage(ExternalDiscovery.enabledKey) private var masterEnabled = false
    /// Keychain-backed, so these cannot be `@AppStorage`: the field holds what was typed
    /// and the store is written on change. Loaded once when the screen appears.
    @State private var keys: [String: String] = [:]

    /// Redrawn on every toggle, because `ExternalDiscovery` reads `UserDefaults` directly
    /// and `@AppStorage` cannot observe a key computed per source.
    @State private var enabled: [String: Bool] = [:]
    @State private var results: [ExternalDiscovery.Source: ExternalDiscovery.TestResult] = [:]
    @State private var testing: Set<ExternalDiscovery.Source> = []

    var body: some View {
        Form {
            Section {
                Toggle("Look Outside My Library", isOn: $masterEnabled)
            } footer: {
                Text("The one part of Baton that talks to someone other than your own server. "
                     + "With this off, nothing below makes a single request.")
            }

            ForEach(ExternalDiscovery.Source.allCases, id: \.self) { source in
                Section(source.label) {
                    Toggle("Use \(source.label)", isOn: binding(for: source))
                    keyField(for: source)
                    testRow(for: source)
                }
            }
        }
        .navigationTitle("External Sources")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(false)
        .onAppear {
            reloadEnabled()
            for source in ExternalDiscovery.Source.allCases where ExternalDiscovery.keyDefaultsKey(for: source) != nil {
                keys[source.rawValue] = ExternalDiscovery.key(for: source)
            }
        }
    }

    private func binding(for source: ExternalDiscovery.Source) -> Binding<Bool> {
        Binding(
            get: { enabled[source.rawValue] ?? ExternalDiscovery.isEnabled(source) },
            set: {
                ExternalDiscovery.setEnabled($0, for: source)
                enabled[source.rawValue] = $0
            }
        )
    }

    private func keyBinding(for source: ExternalDiscovery.Source) -> Binding<String> {
        Binding(
            get: { keys[source.rawValue] ?? "" },
            set: {
                keys[source.rawValue] = $0
                ExternalDiscovery.setKey($0, for: source)
            }
        )
    }

    private func reloadEnabled() {
        for source in ExternalDiscovery.Source.allCases {
            enabled[source.rawValue] = ExternalDiscovery.isEnabled(source)
        }
    }

    @ViewBuilder
    private func keyField(for source: ExternalDiscovery.Source) -> some View {
        switch source {
        case .lastFM, .youTube:
            SecureField("API key", text: keyBinding(for: source))
                .textContentType(.password)
                .autocorrectionDisabled()
        case .musicBrainz, .listenBrainz:
            Text("No account needed.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func testRow(for source: ExternalDiscovery.Source) -> some View {
        Button {
            Task { await runTest(source) }
        } label: {
            HStack {
                Text("Test Connection")
                Spacer()
                if testing.contains(source) { ProgressView() }
            }
        }
        .disabled(testing.contains(source))

        if let result = results[source] {
            Label {
                Text(result.message).font(.footnote)
            } icon: {
                Image(systemName: icon(for: result)).foregroundStyle(tint(for: result))
            }
        }
    }

    private func runTest(_ source: ExternalDiscovery.Source) async {
        testing.insert(source)
        defer { testing.remove(source) }
        results[source] = await ExternalDiscovery.test(source)
    }

    private func icon(for result: ExternalDiscovery.TestResult) -> String {
        switch result {
        case .ready: "checkmark.circle"
        case .keyRejected: "xmark.circle"
        case .rateLimited: "clock.badge.exclamationmark"
        case .unreachable: "wifi.exclamationmark"
        case .notConfigured: "key"
        }
    }

    private func tint(for result: ExternalDiscovery.TestResult) -> Color {
        switch result {
        case .ready: .green
        case .keyRejected: .red
        case .rateLimited, .unreachable, .notConfigured: .secondary
        }
    }
}
