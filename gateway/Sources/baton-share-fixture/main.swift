import BatonGatewayCore
import BatonShareServer
import Foundation

// Test-only product: never selected by production build/deploy commands or environment.
// Invocation: baton-share-fixture <new absolute /private/tmp directory> <unprivileged port>
let args = CommandLine.arguments
let fm = FileManager.default
func refuse() -> Never {
    FileHandle.standardError.write(Data("fixture: requires a new disposable /private/tmp directory and port 1024...65535\n".utf8))
    exit(64)
}
guard args.count == 3, let port = UInt16(args[2]), port >= 1024,
      args[1].hasPrefix("/private/tmp/"), !args[1].contains(".."),
      URL(fileURLWithPath: args[1]).standardizedFileURL.path == args[1], !fm.fileExists(atPath: args[1]) else { refuse() }
let root = URL(fileURLWithPath: args[1], isDirectory: true)
do {
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var config = ShareConfiguration(dataDirectory: root.appendingPathComponent("data"),
                                    publicBase: URL(string: "http://127.0.0.1:\(port)")!, port: port,
                                    blobDelivery: .direct, loopbackOnly: true)
    config.mixtapesEnabled = true
    config.booksEnabled = true
    let service = try ShareService(config: config)
    let maximumAudioBytes = config.limits.maxAudioBytes
    let transport = POSIXTransport(stagingDirectory: service.stagingDirectory, maximumBodyBytes: config.limits.maxAudioBytes,
                                   readTimeout: 20, maximumConcurrentConnections: 256, loopbackOnly: true,
                                   responseCapacity: .init(maximumBytes: ShareDeliveryCapacity.maximumBytes),
                                   reserveResponseBytes: { ShareDeliveryCapacity.reservation(for: $0, maximumAudioBytes: maximumAudioBytes) },
                                   streamsBody: ShareService.streamsBody)
    RequestLog.standardOutput("fixture: loopback-only port=\(port) root=\(root.path) pid=\(ProcessInfo.processInfo.processIdentifier)")
    try transport.serve(port: port, handle: { service.handle($0).data },
                        upload: { request, file in service.handleUpload(request, file: file).data },
                        peerHandle: { request, peer in service.handle(request, peer: peer).data })
} catch {
    FileHandle.standardError.write(Data("fixture: setup/listener failed\n".utf8)); exit(69)
}
