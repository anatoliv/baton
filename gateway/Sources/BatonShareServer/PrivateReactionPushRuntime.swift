import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Errors contain neither paths, key/token bytes nor underlying provider errors.
enum PrivateReactionPushFailure: Error, CustomStringConvertible {
    case configuration, protectedInput, custody, alreadyRunning
    var description: String { "Private reaction sender unavailable." }
}

/// Non-secret, independently pinned inputs for one reviewed sender generation.
/// This record is evidence to validate, not authority to provision or deploy.
struct PrivateReactionPushConfiguration: Sendable {
    var enabled = false
    let directory: URL
    let keyID: String
    let teamID: String
    let environment: PushEnvironment
    let signingKeySHA256: String
    let storageKeySHA256: String
    let custodySHA256: String
    let generation: String
}

/// Private restore/custody manifest. No implicit inheritance from contact storage.
/// Until an actual reviewed manifest is supplied, startup refuses even valid keys.
private struct ReactionPushCustody: Decodable {
    let version: Int
    let generation: String
    let storageKeySHA256: String
    let signingKeySHA256: String
    let topic: String
    let environment: String
    let registrationTTLMilliseconds: Int64
    let jobTTLMilliseconds: Int64
    let backupDecisionReference: String
    let retentionDecisionReference: String
    let registrationIntegrityReference: String
    let failureCoverageReference: String
    let restoreReconciled: Bool
}

struct PrivateReactionPushMaterial: CustomStringConvertible, CustomDebugStringConvertible {
    let signingKey: P256.Signing.PrivateKey
    let storageKey: Data
    let configuration: PrivateReactionPushConfiguration
    var description: String { "PrivateReactionPushMaterial(redacted)" }
    var debugDescription: String { description }
}

/// Reads only fixed filenames through a checked owner-only directory descriptor.
/// No argv/environment/keychain lookup, key generation, writes or migration.
struct PrivateReactionPushLoader {
    func load(_ configuration: PrivateReactionPushConfiguration) throws -> PrivateReactionPushMaterial? {
        // Inactive startup cannot even stat a protected path.
        guard configuration.enabled else { return nil }
        guard configuration.directory.isFileURL,
              configuration.keyID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              configuration.teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              UUID(uuidString: configuration.generation)?.uuidString == configuration.generation,
              [configuration.signingKeySHA256, configuration.storageKeySHA256, configuration.custodySHA256]
                .allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil })
        else { throw PrivateReactionPushFailure.configuration }
        do {
            let directory = try openDirectory(configuration.directory)
            defer { close(directory) }
            let custodyBytes = try read(directory, name: "custody.json", maximum: 8192)
            guard digest(custodyBytes) == configuration.custodySHA256,
                  let fields = (try? JSONSerialization.jsonObject(with: custodyBytes)) as? [String: Any],
                  Set(fields.keys) == ["version", "generation", "storageKeySHA256", "signingKeySHA256",
                    "topic", "environment", "registrationTTLMilliseconds", "jobTTLMilliseconds",
                    "backupDecisionReference", "retentionDecisionReference", "registrationIntegrityReference",
                    "failureCoverageReference", "restoreReconciled"],
                  let custody = try? JSONDecoder().decode(ReactionPushCustody.self, from: custodyBytes),
                  custody.version == 1, custody.restoreReconciled,
                  custody.generation == configuration.generation,
                  custody.storageKeySHA256 == configuration.storageKeySHA256,
                  custody.signingKeySHA256 == configuration.signingKeySHA256,
                  custody.topic == "io.tonebox.baton",
                  custody.environment == configuration.environment.rawValue,
                  custody.registrationTTLMilliseconds == 30 * 86400 * 1000,
                  custody.jobTTLMilliseconds == 3600 * 1000,
                  [custody.backupDecisionReference, custody.retentionDecisionReference,
                   custody.registrationIntegrityReference, custody.failureCoverageReference]
                    .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 })
            else { throw PrivateReactionPushFailure.custody }
            let storage = try read(directory, name: "storage-key.bin", maximum: 32)
            guard storage.count == 32, digest(storage) == configuration.storageKeySHA256 else {
                throw PrivateReactionPushFailure.protectedInput
            }
            let signing = try read(directory, name: "apns-key.p8", maximum: 8192)
            guard digest(signing) == configuration.signingKeySHA256,
                  let pem = String(data: signing, encoding: .utf8),
                  let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
                throw PrivateReactionPushFailure.protectedInput
            }
            return PrivateReactionPushMaterial(signingKey: key, storageKey: storage, configuration: configuration)
        } catch let failure as PrivateReactionPushFailure { throw failure }
        catch { throw PrivateReactionPushFailure.protectedInput }
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        // Walk every component with O_NOFOLLOW: resolving a symlink first would hide it.
        guard url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw PrivateReactionPushFailure.protectedInput
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw PrivateReactionPushFailure.protectedInput }
        do {
            for component in url.pathComponents.dropFirst() {
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PrivateReactionPushFailure.protectedInput }
                close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & mode_t(0o7777) == mode_t(0o700) else {
                throw PrivateReactionPushFailure.protectedInput
            }
            return current
        } catch { close(current); throw error }
    }

    private func read(_ directory: Int32, name: String, maximum: Int) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw PrivateReactionPushFailure.protectedInput }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_mode & mode_t(0o7777) == mode_t(0o600),
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= off_t(maximum) else {
            throw PrivateReactionPushFailure.protectedInput
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: maximum + 1)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                systemRead(descriptor, buffer.baseAddress!, buffer.count)
            }
            if count < 0 { if errno == EINTR { continue }; throw PrivateReactionPushFailure.protectedInput }
            if count == 0 { break }
            guard count <= maximum - data.count else { throw PrivateReactionPushFailure.protectedInput }
            data.append(contentsOf: bytes.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_uid == after.st_uid, before.st_mode == after.st_mode,
              after.st_nlink == 1, after.st_size == off_t(data.count) else {
            throw PrivateReactionPushFailure.protectedInput
        }
        return data
    }
}

private func systemRead(_ descriptor: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(descriptor, bytes, count)
    #else
    Glibc.read(descriptor, bytes, count)
    #endif
}

/// A real implementation must own private persistence and retain current-state,
/// revision, opt-out, suspension, share-expiry and restore fences. No permissive
/// implementation or public-service adapter is supplied by this candidate.
protocol PrivateReactionPushRecipients: Sendable {
    func prepare() async throws -> ReactionPushLease?
    func admit(_ lease: ReactionPushLease) async throws -> Bool
    func finish(_ lease: ReactionPushLease, result: ReactionPushResult) async throws
}

/// A private host owner explicitly retains and runs this object. It cannot register
/// devices or borrow ShareService's public lock/database. Its lease/admission/finish
/// boundary must be backed by a separately accepted private recipient store.
/// No background task is created by initialization; default-off startup has no I/O.
actor PrivateReactionPushRuntime {
    private let dispatcher: ReactionPushDispatcher?
    private var running = false

    init(configuration: PrivateReactionPushConfiguration,
         transport: any APNsTransport = URLSessionAPNsTransport(),
         makeRecipients: @Sendable (ReactionPushPolicy, String) throws -> any PrivateReactionPushRecipients,
         clock: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let material = try PrivateReactionPushLoader().load(configuration) else {
            dispatcher = nil; return
        }
        // Read the storage key first, so the signing key is handed to the provider actor as
        // the material's last use. Swift Crypto's P256 key is not Sendable on Linux (CryptoKit's
        // is on Apple platforms), and sending it while `material` is still read afterwards is a
        // data-race error there: the share service did not compile on Linux under Swift 6.0
        // or 6.1, so its image could not be built.
        let storageKey = material.storageKey
        let signingKey = material.signingKey
        let provider = try APNsReactionPushProvider(key: signingKey,
            keyID: configuration.keyID, teamID: configuration.teamID,
            topics: ["io.tonebox.baton": configuration.environment], transport: transport, clock: clock)
        let policy = try ReactionPushPolicy(enabled: true, key: storageKey,
            topics: ["io.tonebox.baton": configuration.environment])
        // Only the private boundary factory receives the token key. It must refuse
        // unmatched database/restore generation rather than rebind or reset state.
        let recipients: any PrivateReactionPushRecipients
        do { recipients = try makeRecipients(policy, configuration.generation) }
        catch { throw PrivateReactionPushFailure.custody }
        dispatcher = ReactionPushDispatcher(provider: provider,
            prepare: { try await recipients.prepare() },
            admit: { try await recipients.admit($0) },
            finish: { try await recipients.finish($0, result: $1) })
    }

    /// Bounded local/private execution seam. Shares the same single-run admission
    /// as the scheduler, so another owner cannot overlap an explicit loop.
    @discardableResult
    func runOnce() async throws -> Bool {
        guard !running else { throw PrivateReactionPushFailure.alreadyRunning }
        guard let dispatcher else { return false }
        running = true; defer { running = false }
        do { return try await dispatcher.runOnce() }
        catch is CancellationError { throw CancellationError() }
        catch { throw PrivateReactionPushFailure.configuration }
    }

    /// A disabled candidate exits without preparing recipients or sending. Errors
    /// stop the loop, retain recipient state and require explicit operator restart.
    func runUntilCancelled(idleMilliseconds: UInt64 = 1000) async throws {
        guard !running else { throw PrivateReactionPushFailure.alreadyRunning }
        guard let dispatcher else { return }
        running = true; defer { running = false }
        do { try await dispatcher.runUntilCancelled(idleMilliseconds: idleMilliseconds) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PrivateReactionPushFailure.configuration }
    }
}
