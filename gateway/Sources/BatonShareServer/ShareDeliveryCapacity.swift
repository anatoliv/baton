import BatonGatewayCore
import BatonMCPProtocol
import Foundation

/// Bound direct ciphertext responses independently of the connection cap. Admission belongs
/// to POSIXTransport so it survives the handler and HTTP serialization through the final send.
public enum ShareDeliveryCapacity {
    public static let maximumBytes = 128 * 1024 * 1024

    public static func reservation(for request: HTTPRequestMessage, maximumAudioBytes: Int,
                                   blobDelivery: ShareConfiguration.BlobDelivery = .direct) -> Int {
        guard request.method == "GET" else { return 0 }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[0] == "v1", parts[1] == "share" else { return 0 }
        let singleBlob = parts.count == 5 && parts[2] == "p" && ["audio", "art", "card"].contains(parts[4])
        let mixtapeTrack = parts.count == 6 && parts[2] == "m" && parts[4] == "tracks"
        // A book blob is at most one chapter (maxBookChapterBytes, equal to maxAudioBytes).
        let bookBlob = parts.count == 6 && parts[2] == "b" && parts[4] == "blobs"
        guard singleBlob || mixtapeTrack || bookBlob else { return 0 }
        // Under accel nginx sends a song's blob itself; the service answers with headers only.
        if singleBlob, blobDelivery == .accel { return 65_536 }
        // Range and malformed/unknown IDs reserve the same conservative ceiling BEFORE the
        // handler. HEAD, metadata, session admission and health remain independent and small.
        guard maximumAudioBytes > 0, maximumAudioBytes <= (Int.max - 65_536) / 2 else { return Int.max }
        return maximumAudioBytes * 2 + 65_536
    }
}
