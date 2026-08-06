import AVFoundation
import SwiftUI
import UIKit

/// Scans the QR code a Mac shows, and applies whatever it sends back.
///
/// This exists to delete a chore: typing a server URL, a username and a long password into
/// a phone keyboard. What arrives is the same encrypted `SettingsTransfer` payload the
/// "import from Mac" flow already understood — the only difference is that the passphrase
/// was scanned rather than typed, which means there is no passphrase for anyone to forget.
struct PairingScannerView: View {
    let model: MobileModel
    var onLinked: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var status: Status = .scanning
    @State private var cameraDenied = false

    enum Status: Equatable {
        case scanning
        case connecting
        case failed(String)
        case linked(preferences: Int, secrets: Int)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if cameraDenied {
                    permissionHelp
                } else {
                    QRScannerRepresentable { code in
                        Task { await redeem(code) }
                    } onDenied: {
                        cameraDenied = true
                    }
                    .ignoresSafeArea()
                    overlay
                }
            }
            .navigationTitle("Scan to Set Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var overlay: some View {
        VStack {
            Spacer()
            Group {
                switch status {
                case .scanning:
                    label("On your Mac, open Baton → Settings → Remote → Devices and choose \u{201C}Show pairing code\u{201D}.",
                          systemImage: "qrcode.viewfinder")
                case .connecting:
                    label("Talking to your Mac\u{2026}", systemImage: "arrow.triangle.2.circlepath")
                case let .failed(message):
                    label(message, systemImage: "exclamationmark.triangle.fill")
                case let .linked(preferences, secrets):
                    label("Set up \u{2014} \(preferences) settings and \(secrets) accounts came across.",
                          systemImage: "checkmark.circle.fill")
                }
            }
            .padding()
        }
    }

    private func label(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .padding()
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }

    private var permissionHelp: some View {
        ContentUnavailableView {
            Label("Camera access is off", systemImage: "camera.fill")
        } description: {
            Text("Baton needs the camera to read the code your Mac is showing. Nothing is recorded or sent anywhere.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private func redeem(_ code: String) async {
        guard case .scanning = status else { return }   // one scan, not one per frame
        guard let invitation = DevicePairing.parse(code) else {
            // Deliberately specific: people point this at all sorts of codes, and "that
            // isn't a Baton code" saves them staring at a working scanner.
            status = .failed("That isn't a Baton pairing code.")
            return
        }
        status = .connecting
        do {
            let payload = try await PairingClient.redeem(invitation, deviceName: UIDevice.current.name)
            let result = try SettingsTransfer.applyImport(
                payload,
                passphrase: DevicePairing.payloadPassphrase(for: invitation)
            )
            model.musicLibrary.refreshConnection()
            status = .linked(preferences: result.preferenceCount, secrets: result.secretCount)
            try? await Task.sleep(for: .milliseconds(900))   // let the confirmation be read
            onLinked()
            dismiss()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

/// The camera preview + metadata capture, wrapped for SwiftUI.
///
/// Kept deliberately small: it reports strings and permission denial, and knows nothing
/// about what a pairing code is.
private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        controller.onDenied = onDenied
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onDenied: (() -> Void)?

    /// `AVCaptureSession` isn't `Sendable`, but `startRunning()`/`stopRunning()` are
    /// documented as safe to call off the main thread and must not run on it — they block.
    /// The session is only ever touched from `sessionQueue` or the main actor, never both
    /// at once, which is what the annotation asserts.
    nonisolated(unsafe) private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "io.tonebox.baton.pairing-scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.configure() } else { self.onDenied?() }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the camera running behind a dismissed sheet is a battery bug and a
        // privacy smell — the indicator would stay lit.
        guard session.isRunning else { return }
        sessionQueue.async { [session] in session.stopRunning() }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { onDenied?(); return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { onDenied?(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview

        sessionQueue.async { [session] in session.startRunning() }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReported,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else { return }
        // The camera fires many frames a second; one code is one attempt.
        hasReported = true
        onCode?(value)
    }
}
