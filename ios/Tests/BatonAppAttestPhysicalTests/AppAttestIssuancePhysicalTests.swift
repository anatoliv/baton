import CryptoKit
import DeviceCheck
import Foundation
import XCTest
@testable import BatonAppAttestPhysicalHost

/// Separate opt-in target: it is absent from the ordinary test and release schemes.
/// This captures real Apple evidence for offline verification before any server policy
/// allowlist is chosen. It does not claim enrollment, sharing or background acceptance.
@MainActor
final class AppAttestIssuancePhysicalTests: XCTestCase {
    func testCaptureAppleIssuanceAndAssertionForDevelopmentClassification() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BATON_APP_ATTEST_PHYSICAL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit physical acceptance opt-in is absent")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Apple App Attest issuance requires a supported physical phone")
        #else
        guard Bundle.main.object(forInfoDictionaryKey: "BatonPhysicalAttestProbe") as? Bool == true else {
            throw ProbeFailure.isolationNotEstablished
        }
        let suite = try PhysicalAttestProbeStorage.suite()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let source = Bundle.main.object(forInfoDictionaryKey: "BatonSourceCommit") as? String ?? ""
        guard !build.isEmpty, source.count == 40,
              source.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) }) else {
            throw ProbeFailure.unpinnedBuild
        }
        guard DCAppAttestService.shared.isSupported else {
            throw XCTSkip("This phone does not support App Attest")
        }
        // Real system HTTPS validation; no fixture, certificate override or owner token.
        let endpoint = URL(string: "https://dev.batonmusic.app/v1/share/config")!
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(from: endpoint)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.url, endpoint)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "private, no-store")
        guard http.statusCode == 200, http.url == endpoint,
              http.value(forHTTPHeaderField: "Cache-Control") == "private, no-store" else {
            throw ProbeFailure.unexpectedService
        }

        let directory = try PhysicalAttestProbeStorage.directory(suite: suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var excluded = directory, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let url = directory.appendingPathComponent("issuance.json")
        var evidence: Evidence
        if FileManager.default.fileExists(atPath: url.path) {
            evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: url))
            // attestKey is one-time. A lost Apple reply needs an explicit new probe run,
            // never an automatic second attestation of this key.
            guard evidence.probeSuite == suite, evidence.appBundleVersion == build,
                  evidence.sourceCommit == source,
                  Data(base64Encoded: evidence.keyID)?.count == 32,
                  UUID(uuidString: evidence.challenge) != nil,
                  evidence.assertionEnvelope.hasPrefix("baton-development-classification:"),
                  UUID(uuidString: String(evidence.assertionEnvelope.dropFirst("baton-development-classification:".count))) != nil,
                  let object = evidence.attestation, (1...32768).contains(object.count),
                  evidence.assertion.map({ (1...8192).contains($0.count) }) ?? true else {
                throw ProbeFailure.incompleteOrMismatchedSavedIssuance
            }
        } else {
            let key = try await DCAppAttestService.shared.generateKey()
            evidence = Evidence(keyID: key, challenge: UUID().uuidString,
                                assertionEnvelope: "baton-development-classification:" + UUID().uuidString,
                                appBundleVersion: build, sourceCommit: source, probeSuite: suite)
            try save(evidence, to: url)
            evidence.attestation = try await DCAppAttestService.shared.attestKey(key,
                clientDataHash: Data(SHA256.hash(data: Data(evidence.challenge.utf8))))
            try save(evidence, to: url)
        }
        if evidence.assertion == nil {
            evidence.assertion = try await DCAppAttestService.shared.generateAssertion(evidence.keyID,
                clientDataHash: Data(SHA256.hash(data: Data(evidence.assertionEnvelope.utf8))))
            try save(evidence, to: url)
        }
        XCTAssertFalse(try XCTUnwrap(evidence.attestation).isEmpty)
        XCTAssertFalse(try XCTUnwrap(evidence.assertion).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // No proof, key identifier or owner information enters xcresult attachments/logs.
        #endif
    }

    private func save(_ evidence: Evidence, to url: URL) throws {
        try PhysicalAttestProbeStorage.writeProtected(JSONEncoder().encode(evidence), to: url)
    }
    private struct Evidence: Codable {
        var keyID: String
        var challenge: String
        var assertionEnvelope: String
        var appBundleVersion: String
        var sourceCommit: String
        var probeSuite: String
        var capturedAt = Date()
        var attestation: Data?
        var assertion: Data?
    }
    private enum ProbeFailure: Error {
        case isolationNotEstablished, unpinnedBuild, unexpectedService, incompleteOrMismatchedSavedIssuance
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
