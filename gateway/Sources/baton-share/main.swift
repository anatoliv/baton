import BatonGatewayCore
import BatonShareServer
import Foundation

// `baton-share`: song links for friends outside the LAN (specs/song-sharing.md).
// Configuration is the environment; see gateway/deploy/share.env.example.

/// Through `RequestLog.standardOutput`, not `print`: under Docker stdout is a pipe, and `print`
/// buffers there until `docker logs` shows nothing (see RequestLog).
func log(_ line: String) { RequestLog.standardOutput("baton-share: " + line) }

let config: ShareConfiguration
do {
    config = try ShareConfiguration.fromEnvironment()
} catch {
    FileHandle.standardError.write(Data("baton-share: \(error)\n".utf8))
    exit(78) // EX_CONFIG
}

let service: ShareService
do {
    service = try ShareService(config: config)
} catch {
    FileHandle.standardError.write(Data("baton-share: cannot open \(config.dataDirectory.path): \(error)\n".utf8))
    exit(73) // EX_CANTCREAT
}

let litter = StreamingUpload.sweepStaging(directory: service.stagingDirectory)
log("data \(config.dataDirectory.path), base \(config.publicBase.absoluteString), "
    + "delivery \(config.blobDelivery.rawValue), sharing \(config.enabled ? "on" : "PAUSED"), "
    + "admin \(config.adminToken == nil ? "off" : "on"), staged litter removed \(litter)")

// The sweeper: expiry, abandoned uploads, retention (spec §7). On start-up too, so a share that
// expired while the container was down stops answering before the first request.
let sweeper = Thread {
    while true {
        do {
            let result = try service.sweep()
            if result.expired + result.abandoned + result.purged + result.eventsPurged > 0 {
                log("sweep expired=\(result.expired) abandoned=\(result.abandoned) "
                    + "purged=\(result.purged) events_purged=\(result.eventsPurged)")
            }
        } catch {
            log("sweep failed: \(error)")
        }
        Thread.sleep(forTimeInterval: 600)
    }
}
sweeper.name = "baton-share-sweeper"
sweeper.start()

// A share's audio is at most 25 MiB; the staging ceiling allows a handful in flight at once.
let transport = POSIXTransport(
    stagingDirectory: service.stagingDirectory,
    maximumBodyBytes: config.limits.maxAudioBytes,
    readTimeout: 20,
    maximumConcurrentConnections: 256,
    loopbackOnly: config.loopbackOnly,
    responseCapacity: .init(maximumBytes: ShareDeliveryCapacity.maximumBytes),
    reserveResponseBytes: {
        ShareDeliveryCapacity.reservation(for: $0, maximumAudioBytes: config.limits.maxAudioBytes,
                                          blobDelivery: config.blobDelivery)
    },
    streamsBody: ShareService.streamsBody,
    // Before staging is reserved, an upload is checked for who is asking, the share's state and
    // the declared length, and counted against in-flight caps (per target, sharer and network).
    // Each upload request (one blob per PUT) must finish within 15 minutes: about 0.25 Mbit/s for
    // a 25 MiB blob.
    admitsUpload: { service.admitUpload($0) },
    uploadDeadline: 900)

do {
    try transport.serve(
        port: config.port,
        handle: { request in await service.handleAsync(request).data },
        upload: { request, file in service.handleUpload(request, file: file).data },
        peerHandle: { request, peer in await service.handleAsync(request, peer: peer).data })
} catch {
    FileHandle.standardError.write(Data("baton-share: cannot listen on \(config.port): \(error)\n".utf8))
    exit(69) // EX_UNAVAILABLE
}
