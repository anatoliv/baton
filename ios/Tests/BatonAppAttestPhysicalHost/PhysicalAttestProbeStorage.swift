import Foundation

/// The minimal host never resolves the owner's Baton storage or Keychain.
@MainActor
enum PhysicalAttestProbeStorage {
    enum Failure: Error { case isolationNotEstablished }

    static func suite(environment: [String: String] = ProcessInfo.processInfo.environment,
                      bundleID: String? = Bundle.main.bundleIdentifier) throws -> String {
        guard environment["BATON_APP_ATTEST_PHYSICAL_ACCEPTANCE"] == "1",
              bundleID == "io.tonebox.baton",
              let suite = environment["baton.defaultsSuite"],
              suite.hasPrefix("probe-attest-"), (14...53).contains(suite.count),
              suite.unicodeScalars.allSatisfy({
                  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".unicodeScalars.contains($0)
              }) else { throw Failure.isolationNotEstablished }
        return suite
    }

    static func directory(suite: String) throws -> URL {
        // Revalidate rather than accepting a caller-supplied path or owner domain.
        guard suite == (try self.suite()) else { throw Failure.isolationNotEstablished }
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Baton Probes", isDirectory: true)
            .appendingPathComponent(suite, isDirectory: true)
            .appendingPathComponent("AppAttestPhysicalEvidence", isDirectory: true)
    }

    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([
            .posixPermissions: 0o600,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ], ofItemAtPath: url.path)
    }
}
