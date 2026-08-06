import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import BatonPlaybackKit
import BatonSubsonicKit

/// "Link a device" — shows a QR code a phone scans to get this Mac's Baton setup.
///
/// The alternative it replaces is typing a server URL, a username and a password into a
/// phone keyboard, which is exactly the kind of thing people do once and then avoid. What
/// travels is the existing encrypted `SettingsTransfer` export; the only new idea is where
/// the passphrase comes from — a scanned key instead of a typed word.
///
/// The security story stated plainly, because it should be: **anyone who can read the code
/// can complete the pairing.** That is why it lives for 90 seconds, works once, and why
/// this Mac asks you to approve the device by name before it sends anything. A code on a
/// screen in a shared room is otherwise a standing invitation.
struct DeviceLinkPane: View {
    @State private var host = PairingHost()
    @State private var localAddress = ""
    @State private var pendingApproval: (name: String, respond: (Bool) -> Void)?
    /// Bumped on Forget so the list redraws — the log is plain UserDefaults, not observable.
    @State private var forgetTick = 0

    var body: some View {
        Form {
            Section("Link a device") {
                switch host.state {
                case .idle:
                    idle
                case let .advertising(invitation):
                    code(invitation)
                case let .awaitingApproval(deviceName):
                    approval(deviceName)
                case let .linked(deviceName):
                    linked(deviceName)
                case let .failed(message):
                    failure(message)
                }
            }

            Section("Linked devices") {
                linkedDevices
                    .id(forgetTick)
            }

            Section {
                Label("""
                Scanning transfers this Mac's server address, sign-in and scrobble accounts \
                to the phone. Unlinking later removes the phone's copy — it does not change \
                your Navidrome password, because Navidrome has no per-device credentials to \
                revoke. Both devices must be on the same network to pair; the phone works \
                anywhere afterwards.
                """, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onChange(of: host.state) { _, _ in recordIfLinked() }
        .onDisappear { host.stop() }
    }

    // MARK: States

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show a code your iPhone can scan in Baton → Settings → Server.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Show pairing code") { start() }
                .disabled(!NavidromeConfig.isConfigured)
            if !NavidromeConfig.isConfigured {
                Label("Connect this Mac to a server first — there's nothing to hand over yet.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func code(_ invitation: DevicePairing.Invitation) -> some View {
        VStack(spacing: 12) {
            if let image = Self.qrImage(invitation.url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Expires in \(Int(DevicePairing.timeToLive)) seconds")
                .font(.caption).foregroundStyle(.secondary)
            Text(invitation.host)
                .font(.caption.monospaced()).foregroundStyle(.tertiary)
            Button("Cancel") { host.stop() }
        }
        .frame(maxWidth: .infinity)
    }

    private func approval(_ deviceName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(deviceName) wants to link", systemImage: "iphone")
                .font(.headline)
            Text("Only allow this if it's your device and you're holding it now.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Allow") { pendingApproval?.respond(true); pendingApproval = nil }
                    .keyboardShortcut(.defaultAction)
                Button("Refuse", role: .destructive) { pendingApproval?.respond(false); pendingApproval = nil }
            }
        }
    }

    @ViewBuilder
    private var linkedDevices: some View {
        let devices = DevicePairing.LinkedDevices.all()
        if !devices.isEmpty {
            ForEach(devices) { device in
                HStack {
                    Label(device.name, systemImage: "iphone")
                    Spacer()
                    Text(device.linkedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Forget") {
                        DevicePairing.LinkedDevices.forget(device.id)
                        forgetTick += 1
                    }
                }
            }
            Text("""
            Forgetting a device only removes it from this list. It cannot take back what             that device already holds — Navidrome has no per-device sign-in to revoke, so             the only way to cut off a phone you no longer trust is to change your Navidrome             password.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func linked(_ deviceName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(deviceName) is set up", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("Link another device") { start() }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { start() }
        }
    }

    // MARK: Actions

    /// Records the link once the payload has gone, so the list reflects what actually
    /// happened rather than what was attempted.
    private func recordIfLinked() {
        if case let .linked(deviceName) = host.state {
            DevicePairing.LinkedDevices.record(name: deviceName)
        }
    }

    private func start() {
        pendingApproval = nil
        localAddress = Self.primaryLANAddress() ?? ""
        guard !localAddress.isEmpty else {
            host.fail("This Mac isn't on a network Baton can share an address for.")
            return
        }

        // Approval is a real prompt, not a formality — see the type's doc comment.
        host.approve = { deviceName in
            await withCheckedContinuation { continuation in
                pendingApproval = (deviceName, { continuation.resume(returning: $0) })
            }
        }
        // Deliberately not calling makeExport directly: pairing must always encrypt, and
        // that guarantee lives in DevicePairing rather than in a boolean here.
        host.makePayload = { invitation in try DevicePairing.makePayload(for: invitation) }
        do { try host.start(host: localAddress) }
        catch { host.fail(error.localizedDescription) }
    }

    // MARK: Helpers

    private static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium correction: the payload is short, and a denser code scans worse on a
        // phone held at arm's length than a slightly less redundant one.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// This Mac's LAN address. Picks the first non-loopback IPv4 — the address a phone on
    /// the same wifi can actually open a socket to.
    private static func primaryLANAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  pointer.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointer.pointee.ifa_addr, socklen_t(pointer.pointee.ifa_addr.pointee.sa_len),
                              &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let address = String(cString: buffer)
            let name = String(cString: pointer.pointee.ifa_name)
            // Prefer wifi/ethernet over virtual interfaces (Docker, VPNs, VMs), which are
            // up and routable but not where the phone is.
            if name.hasPrefix("en") { candidates.insert(address, at: 0) } else { candidates.append(address) }
        }
        return candidates.first
    }
}
