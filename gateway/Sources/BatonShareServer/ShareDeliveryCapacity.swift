import BatonGatewayCore
import BatonMCPProtocol
import Foundation

/// Bound direct ciphertext responses independently of the connection cap. Admission belongs
/// to POSIXTransport so it survives the handler and HTTP serialization through the final send.
public enum ShareDeliveryCapacity {
    public static let maximumBytes = 128 * 1024 * 1024

    public static func reservation(for request: HTTPRequestMessage, maximumAudioBytes: Int) -> Int {
        guard request.method == "GET" else { return 0 }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[0] == "v1", parts[1] == "share" else { return 0 }
        let singleBlob = parts.count == 5 && parts[2] == "p" && ["audio", "art", "card"].contains(parts[4])
        guard singleBlob else { return 0 }
        // Range and malformed/unknown IDs reserve the same conservative ceiling BEFORE the
        // handler. HEAD, metadata and health remain independent and small.
        guard maximumAudioBytes > 0, maximumAudioBytes <= (Int.max - 65_536) / 2 else { return Int.max }
        return maximumAudioBytes * 2 + 65_536
    }
}
