import SwiftUI
import BatonPlaybackKit

/// Bringing a Mac's Baton setup onto the phone — the two ways it can travel, and what
/// each of them needs.
///
/// Settings used to offer one button, "Import settings from Mac…", which opened the iOS
/// Files picker. That was misleading in both directions. It promised a Mac and delivered a
/// file browser, usually into an empty folder, because it silently assumed you had already
/// exported a file on the Mac and moved it across by AirDrop or iCloud. And it was the
/// *worse* of the two transports: scanning the Mac's pairing code sends the identical
/// payload — `DevicePairing.makePayload` is `SettingsTransfer.makeExport(includeSecrets:)`
/// — with no file to shuttle and no passphrase to type, since the passphrase is derived
/// from the scanned key.
///
/// The scanner existed the whole time; it was reachable only from first-run onboarding,
/// which Settings presents solely when the phone is in demo mode. So a phone that was
/// already connected — exactly the phone whose owner wants their Mac's settings — could
/// not reach it, and the file picker was its only option.
///
/// Both live here now, each stating its requirement up front, because the choice between
/// them is a real one: pairing needs the two devices on the same network, and a file is
/// the only thing that works when they aren't.
struct MacTransferView: View {
    let model: MobileModel
    /// Called once something has actually landed, so the presenter can dismiss.
    var onImported: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var showsScanner = false
    @State private var showsImporter = false
    @State private var importData: Data?
    @State private var needsPassphrase = false
    @State private var passphrase = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Button {
                    showsScanner = true
                } label: {
                    Label("Scan a code from your Mac", systemImage: "qrcode.viewfinder")
                }
            } header: {
                Text("Recommended")
            } footer: {
                Text("""
                On your Mac: Baton → \(MacSetupPath.pairing). Your server address, \
                sign-in and settings come across encrypted, with nothing to type. Both \
                devices need to be on the same network.
                """)
            }

            Section {
                Button {
                    showsImporter = true
                } label: {
                    Label("Choose an exported file", systemImage: "doc")
                }
            } header: {
                Text("If they're on different networks")
            } footer: {
                Text("""
                On your Mac: Baton → \(MacSetupPath.export), then send the file to this \
                phone however you like. If you exported it with your accounts, it's \
                encrypted and you'll need the passphrase you chose.
                """)
            }
        }
        .navigationTitle("Set Up from a Mac")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsScanner) {
            PairingScannerView(model: model) {
                showsScanner = false
                onImported()
                dismiss()
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            // The picker hands back a security-scoped URL; reading it without claiming
            // access fails, and claiming it without releasing leaks the scope.
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                status = "Couldn't read that file."
                return
            }
            importData = data
            // Only ask for a passphrase when the file actually has one — an export
            // without accounts is plain JSON, and prompting for it would be a dead end.
            if let inspection = try? SettingsTransfer.inspect(data), inspection.encrypted {
                needsPassphrase = true
            } else {
                apply(passphrase: nil)
            }
        }
        .alert("Passphrase", isPresented: $needsPassphrase) {
            SecureField("Export passphrase", text: $passphrase)
            Button("Import") { apply(passphrase: passphrase) }
            Button("Cancel", role: .cancel) { importData = nil; passphrase = "" }
        } message: {
            Text("This export is encrypted — enter the passphrase you set on the Mac.")
        }
        .alert("Settings import", isPresented: Binding(
            get: { status != nil },
            set: { if !$0 { status = nil } }
        )) {
            Button("OK") { status = nil }
        } message: {
            if let status { Text(status) }
        }
    }

    /// Applies a Mac export: preferences and secrets land in the same UserDefaults and
    /// Keychain slots the shared core reads, then the library reconnects.
    private func apply(passphrase: String?) {
        guard let data = importData else { return }
        do {
            let result = try SettingsTransfer.applyImport(data, passphrase: passphrase)
            status = "Imported \(Counted.phrase(result.preferenceCount, "setting")) "
                + "and \(Counted.phrase(result.secretCount, "secret"))."
            importData = nil
            self.passphrase = ""
            model.musicLibrary.refreshConnection()
            Task { await model.warmLibrary() }
            onImported()
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }
}
