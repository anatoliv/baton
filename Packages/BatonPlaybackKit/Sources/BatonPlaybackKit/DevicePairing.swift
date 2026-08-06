import CryptoKit
import Foundation

/// The wire protocol for linking a phone to a Mac by scanning a QR code.
///
/// The design in one line: **the QR *is* the shared secret.** It carries 256 bits of
/// randomness that exists nowhere else, and both sides derive their keys from it. That
/// makes the security property easy to state honestly — anyone who can read the code can
/// complete the pairing — which is why the code is short-lived, single-use, and why the Mac
/// asks its owner to approve the named device before it sends anything.
///
/// Pure and platform-neutral so both apps share one implementation and the format cannot
/// drift: a Mac that encodes a field the phone doesn't read is a failure nobody sees until
/// someone is standing there holding a phone at a screen.
public enum DevicePairing {
    /// Bumped when the wire format changes. The scanner refuses anything it doesn't know
    /// rather than guessing at a payload from a newer Mac.
    public static let version = 1
    public static let scheme = "baton-pair"

    /// How long a code is worth showing. Long enough to find your phone and unlock it,
    /// short enough that a code left on a screen stops being an invitation.
    public static let timeToLive: TimeInterval = 90

    // MARK: - The code itself

    /// Everything the phone needs to find the Mac and prove it saw the screen.
    public struct Invitation: Equatable, Sendable {
        public let host: String
        public let port: UInt16
        public let pairingID: String
        /// 256 bits of randomness. The only secret in the exchange.
        public let key: Data

        public init(host: String, port: UInt16, pairingID: String, key: Data) {
            self.host = host
            self.port = port
            self.pairingID = pairingID
            self.key = key
        }

        /// A fresh invitation for a listener already bound to `host:port`.
        public static func make(host: String, port: UInt16) -> Invitation {
            Invitation(
                host: host,
                port: port,
                pairingID: UUID().uuidString,
                key: Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
            )
        }

        /// The string encoded into the QR image.
        public var url: String {
            "\(scheme):v\(version)?h=\(host)&p=\(port)&i=\(pairingID)&k=\(key.base64URLEncoded)"
        }
    }

    /// Parses a scanned string. Returns nil for anything that isn't a pairing code this
    /// build understands — a scanner that guesses is a scanner that connects somewhere
    /// unexpected.
    public static func parse(_ raw: String) -> Invitation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\(scheme):v\(version)?") else { return nil }
        let query = String(trimmed.dropFirst("\(scheme):v\(version)?".count))

        var fields: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }

        guard let host = fields["h"], !host.isEmpty,
              let portText = fields["p"], let port = UInt16(portText),
              let pairingID = fields["i"], !pairingID.isEmpty,
              let keyText = fields["k"], let key = Data(base64URLEncoded: keyText),
              key.count == 32
        else { return nil }

        return Invitation(host: host, port: port, pairingID: pairingID, key: key)
    }

    // MARK: - Remembering what was linked

    /// A device this Mac has handed its setup to.
    ///
    /// Recorded so the owner can see what they've done. Deliberately **not** called a
    /// revocation list: Navidrome has no per-device credentials (verified against 0.61.2
    /// and 0.63.2 — no `apikeyauth` extension), so removing a row cannot invalidate
    /// anything the phone already holds. Calling it "revoke" would be a lie told by a
    /// button label.
    public struct LinkedDevice: Codable, Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let linkedAt: Date

        public init(id: String = UUID().uuidString, name: String, linkedAt: Date = Date()) {
            self.id = id
            self.name = name
            self.linkedAt = linkedAt
        }
    }

    /// The linked-device log. Local to the Mac that did the linking.
    @MainActor
    public enum LinkedDevices {
        public static let storageKey = "baton.pairing.linkedDevices"

        public static func all(defaults: UserDefaults = .standard) -> [LinkedDevice] {
            guard let data = defaults.data(forKey: storageKey),
                  let devices = try? JSONDecoder().decode([LinkedDevice].self, from: data)
            else { return [] }
            return devices.sorted { $0.linkedAt > $1.linkedAt }
        }

        public static func record(name: String, defaults: UserDefaults = .standard) {
            var devices = all(defaults: defaults)
            // Re-linking the same phone replaces its row rather than adding a second: two
            // entries for one device would misrepresent what happened.
            devices.removeAll { $0.name == name }
            devices.append(LinkedDevice(name: name))
            save(devices, defaults: defaults)
        }

        public static func forget(_ id: String, defaults: UserDefaults = .standard) {
            save(all(defaults: defaults).filter { $0.id != id }, defaults: defaults)
        }

        private static func save(_ devices: [LinkedDevice], defaults: UserDefaults) {
            defaults.set(try? JSONEncoder().encode(devices), forKey: storageKey)
        }
    }

    // MARK: - Proving the phone saw the screen

    /// The phone's opening message: the pairing id, plus a MAC over it proving possession
    /// of the key.
    ///
    /// Without this a device that merely reached the listener could ask for the payload —
    /// the port is open on the LAN, and "nobody else is on my wifi" is not a security model.
    public struct Hello: Codable, Equatable, Sendable {
        public let pairingID: String
        public let deviceName: String
        public let proof: Data

        public init(pairingID: String, deviceName: String, proof: Data) {
            self.pairingID = pairingID
            self.deviceName = deviceName
            self.proof = proof
        }
    }

    /// Builds the phone's hello for an invitation.
    public static func hello(for invitation: Invitation, deviceName: String) -> Hello {
        Hello(
            pairingID: invitation.pairingID,
            deviceName: deviceName,
            proof: proof(pairingID: invitation.pairingID, key: invitation.key)
        )
    }

    /// Whether a hello genuinely came from something that saw this invitation.
    ///
    /// Compares in constant time: a MAC check that leaks timing is a MAC check an attacker
    /// can walk byte by byte.
    public static func isValid(_ hello: Hello, for invitation: Invitation) -> Bool {
        guard hello.pairingID == invitation.pairingID else { return false }
        let expected = proof(pairingID: invitation.pairingID, key: invitation.key)
        return constantTimeEquals(hello.proof, expected)
    }

    /// HMAC-SHA256 over the pairing id, under a key derived from the invitation's secret.
    /// Derived rather than used directly so the proof key and the payload key are distinct —
    /// the proof travels in the clear, and a MAC should never be computed with the key that
    /// also encrypts.
    static func proof(pairingID: String, key: Data) -> Data {
        let macKey = derive(key: key, label: "baton-pair-proof")
        return Data(HMAC<SHA256>.authenticationCode(for: Data(pairingID.utf8), using: macKey))
    }

    /// The passphrase the payload is encrypted under.
    ///
    /// `SettingsTransfer` already encrypts under a user passphrase; pairing reuses that
    /// format exactly and only changes where the passphrase comes from — a scanned key
    /// instead of a typed word. One encryption implementation, not two.
    public static func payloadPassphrase(for invitation: Invitation) -> String {
        Data(derive(key: invitation.key, label: "baton-pair-payload")
            .withUnsafeBytes(Array.init)).base64URLEncoded
    }

    /// Builds the payload a pairing link carries.
    ///
    /// Exists so the call site cannot get this wrong. `SettingsTransfer.makeExport` writes
    /// **plain JSON** when `includeSecrets` is false — the passphrase is ignored entirely —
    /// which is the correct behaviour for "email yourself your preferences" and a disaster
    /// for a socket on the LAN. Pairing always sends accounts, so pairing always encrypts,
    /// and that decision lives here rather than in a boolean at each caller.
    public static func makePayload(
        for invitation: Invitation,
        defaults: UserDefaults = .standard
    ) throws -> Data {
        let export = try SettingsTransfer.makeExport(
            includeSecrets: true,
            passphrase: payloadPassphrase(for: invitation),
            defaults: defaults
        )
        guard export.encrypted else {
            // Belt and braces: if the export format ever changes such that this comes back
            // unencrypted, fail loudly rather than transmit it.
            throw PayloadError.notEncrypted
        }
        return export.data
    }

    public enum PayloadError: LocalizedError {
        case notEncrypted
        public var errorDescription: String? {
            "Refusing to send an unencrypted pairing payload."
        }
    }

    private static func derive(key: Data, label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            info: Data(label.utf8),
            outputByteCount: 32
        )
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

// MARK: - base64url

extension Data {
    /// URL-safe base64 without padding — a QR payload rides in a URL query.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else { return nil }
        self = data
    }
}
