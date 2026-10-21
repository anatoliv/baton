import BatonGatewayCore
import BatonShareServer
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Local test-only product. No deployment script selects it. The capability file
// contains newly generated synthetic fixture capabilities, never account keys.
// baton-mixtape-ui-fixture <new private root> <port> <private capability JSON>
let args = CommandLine.arguments
let fm = FileManager.default
struct Capabilities: Decodable { let admin: String; let `operator`: String }
func refuse() -> Never {
    FileHandle.standardError.write(Data("mixtape UI fixture: invalid disposable inputs\n".utf8))
    exit(64)
}
func privateFile(_ path: String) throws -> Data {
    let fileManager = FileManager.default
    let url = URL(fileURLWithPath: path)
    let attrs = try fileManager.attributesOfItem(atPath: path)
    let parent = try fileManager.attributesOfItem(atPath: url.deletingLastPathComponent().path)
    guard path.hasPrefix("/private/tmp/"), !path.split(separator: "/").contains(".."),
          url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
          attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
          (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          ((attrs[.size] as? NSNumber)?.intValue ?? 4097) <= 4096,
          parent[.type] as? FileAttributeType == .typeDirectory,
          (parent[.posixPermissions] as? NSNumber)?.intValue == 0o700,
          (parent[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { refuse() }
    return try Data(contentsOf: url)
}
guard args.count == 4, let port = UInt16(args[2]), port >= 1024,
      args[1].hasPrefix("/private/tmp/"), !args[1].split(separator: "/").contains(".."),
      !fm.fileExists(atPath: args[1]) else { refuse() }
let root = URL(fileURLWithPath: args[1], isDirectory: true)
let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
guard root.deletingLastPathComponent().resolvingSymlinksInPath() == temporary else { refuse() }
do {
    let data = try privateFile(args[3])
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == ["admin", "operator"] else { refuse() }
    let capabilities = try JSONDecoder().decode(Capabilities.self, from: data)
    guard capabilities.admin != capabilities.operator,
          capabilities.admin.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else { refuse() }
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var config = ShareConfiguration(dataDirectory: root.appendingPathComponent("data"),
        publicBase: URL(string: "http://127.0.0.1:\(port)")!, port: port,
        blobDelivery: .direct, loopbackOnly: true)
    config.mixtapesEnabled = true
    config.booksEnabled = true
    config.adminToken = capabilities.admin
    config.enforcement = try EnforcementConfiguration(token: capabilities.operator,
        retentionSeconds: 90 * 86400, auditRetentionSeconds: 90 * 86400,
        reasonCodes: ["fixture-review"], maximumAffectedShares: 1)
    let service = try ShareService(config: config)
    let transport = POSIXTransport(stagingDirectory: service.stagingDirectory,
        maximumBodyBytes: config.limits.maxAudioBytes, readTimeout: 20,
        maximumConcurrentConnections: 32, loopbackOnly: true, streamsBody: ShareService.streamsBody)
    try transport.serve(port: port, handle: { service.handle($0).data },
        upload: { request, file in service.handleUpload(request, file: file).data },
        peerHandle: { request, peer in service.handle(request, peer: peer).data })
} catch {
    FileHandle.standardError.write(Data("mixtape UI fixture: setup/listener failed\n".utf8)); exit(69)
}
