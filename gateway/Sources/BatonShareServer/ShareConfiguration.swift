import BatonShareKit
import Foundation

/// Everything `baton-share` reads from its environment. Documented, with defaults, in
/// `gateway/deploy/share.env.example`.
public struct ShareConfiguration: Sendable {
    public enum BlobDelivery: String, Sendable {
        /// `X-Accel-Redirect` to nginx, which serves the file from the shared volume (production).
        case accel
        /// The service sends the bytes itself (tests, local runs). Whole-file, in memory.
        case direct
    }

    public var dataDirectory: URL
    public var publicBase: URL
    public var port: UInt16
    /// Local probes bind only loopback; containers retain the default all-interface listener.
    public var loopbackOnly: Bool
    public var enabled: Bool
    /// Default-off until the complete workflow and release readiness are qualified.
    public var mixtapesEnabled: Bool = false
    /// Whole-book links (`/b/`, specs/book-sharing.md Phase 2). Default-off until the owner
    /// approves the share-service deploy.
    public var booksEnabled: Bool = false
    /// Album and playlist links on `/b/` (specs/collection-sharing.md). Default-off; effective only
    /// with `booksEnabled`, whose routes, limits and page a collection shares.
    public var collectionsEnabled: Bool = false
    public var adminToken: String?
    /// A separately provisioned local-operator capability. Nil disables every operator route.
    public var enforcement: EnforcementConfiguration? = nil
    public var contactBridge: ShareContactConfiguration? = nil
    public var blobDelivery: BlobDelivery
    /// The internal nginx location the blobs are served from under `accel`.
    public var accelPrefix: String
    public var appStoreURL: String
    public var macDownloadURL: String
    public var aboutURL: String
    public var limits: ShareLimits
    public var appAttest: AppAttestConfiguration?

    public init(dataDirectory: URL, publicBase: URL = ShareLink.defaultBase, port: UInt16 = 8790,
                enabled: Bool = true, adminToken: String? = nil, blobDelivery: BlobDelivery = .accel,
                accelPrefix: String = "/_share_blobs",
                // `ct` is the App Store campaign token. Attributing installs to it in App Analytics also
                // needs the provider token (`pt`), which is set per deployment: see share.env.example.
                appStoreURL: String = "https://apps.apple.com/app/id6798304294?ct=share-link&mt=8",
                macDownloadURL: String = "https://batonmusic.app/?ref=share#get",
                aboutURL: String = "https://batonmusic.app/?ref=share",
                limits: ShareLimits = .standard, loopbackOnly: Bool = false) {
        self.dataDirectory = dataDirectory
        self.publicBase = publicBase
        self.port = port
        self.loopbackOnly = loopbackOnly
        self.enabled = enabled
        self.adminToken = adminToken
        self.blobDelivery = blobDelivery
        self.accelPrefix = accelPrefix
        self.appStoreURL = appStoreURL
        self.macDownloadURL = macDownloadURL
        self.aboutURL = aboutURL
        self.limits = limits
    }

    /// Reads `BATON_SHARE_*`. Refuses a configuration that would run in a surprising way rather
    /// than quietly defaulting: an admin token shorter than 32 characters, an unknown delivery.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws
        -> ShareConfiguration
    {
        var config = ShareConfiguration(
            dataDirectory: URL(fileURLWithPath: env["BATON_SHARE_DATA"] ?? "/var/lib/baton-share"))
        if let base = env["BATON_SHARE_PUBLIC_BASE"] {
            guard let url = URL(string: base), url.scheme != nil else {
                throw ConfigurationError("BATON_SHARE_PUBLIC_BASE is not a URL")
            }
            config.publicBase = url
        }
        if let port = env["BATON_SHARE_PORT"] {
            guard let value = UInt16(port) else { throw ConfigurationError("BATON_SHARE_PORT is not a port") }
            config.port = value
        }
        if let bind = env["BATON_SHARE_BIND"] {
            guard ["127.0.0.1", "0.0.0.0"].contains(bind) else {
                throw ConfigurationError("BATON_SHARE_BIND must be 127.0.0.1 or 0.0.0.0")
            }
            config.loopbackOnly = bind == "127.0.0.1"
        }
        config.enabled = env["BATON_SHARE_ENABLED"].map { $0 != "0" && $0.lowercased() != "false" } ?? true
        // Mixtapes are off unless asked for. The server's release overlay sets this
        // (gateway/deploy/share-image-release.py), never share.env.
        if let value = env["BATON_SHARE_MIXTAPES"] {
            switch value.lowercased() {
            case "1", "true": config.mixtapesEnabled = true
            case "0", "false", "": config.mixtapesEnabled = false
            default: throw ConfigurationError("BATON_SHARE_MIXTAPES must be 1 or 0")
            }
        }
        if let value = env["BATON_SHARE_BOOKS"] {
            switch value.lowercased() {
            case "1", "true": config.booksEnabled = true
            case "0", "false", "": config.booksEnabled = false
            default: throw ConfigurationError("BATON_SHARE_BOOKS must be 1 or 0")
            }
        }
        if let value = env["BATON_SHARE_COLLECTIONS"] {
            switch value.lowercased() {
            case "1", "true": config.collectionsEnabled = true
            case "0", "false", "": config.collectionsEnabled = false
            default: throw ConfigurationError("BATON_SHARE_COLLECTIONS must be 1 or 0")
            }
        }
        if let token = env["BATON_SHARE_ADMIN_TOKEN"], !token.isEmpty {
            guard token.count >= 32 else {
                throw ConfigurationError("BATON_SHARE_ADMIN_TOKEN must be at least 32 characters")
            }
            config.adminToken = token
        }
        if let delivery = env["BATON_SHARE_BLOB_DELIVERY"] {
            guard let value = BlobDelivery(rawValue: delivery) else {
                throw ConfigurationError("BATON_SHARE_BLOB_DELIVERY must be accel or direct")
            }
            config.blobDelivery = value
        }
        if let quota = env["BATON_SHARE_QUOTA_BYTES"] {
            guard let value = Int64(quota), value > 0 else {
                throw ConfigurationError("BATON_SHARE_QUOTA_BYTES is not a positive integer")
            }
            config.limits.quotaBytes = value
        }
        if let value = env["BATON_SHARE_APP_STORE_URL"] { config.appStoreURL = value }
        if let value = env["BATON_SHARE_MAC_DOWNLOAD_URL"] { config.macDownloadURL = value }
        let attestKeys = ["BATON_SHARE_APP_ATTEST_APP_ID", "BATON_SHARE_APP_ATTEST_ENVIRONMENT",
                          "BATON_SHARE_APP_ATTEST_BUNDLE_VERSIONS", "BATON_SHARE_APP_ATTEST_CATEGORIES"]
        if attestKeys.contains(where: { env[$0] != nil }) {
            guard let appID = env[attestKeys[0]], appID.range(of: "^[A-Z0-9]{10}\\.[A-Za-z0-9][A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil,
                  let environment = env[attestKeys[1]], ["development", "production"].contains(environment),
                  let versions = env[attestKeys[2]], !versions.isEmpty,
                  let categories = env[attestKeys[3]], !categories.isEmpty else {
                throw ConfigurationError("App Attest requires explicit verified App ID, environment, build versions and categories")
            }
            let versionSet = Set(versions.split(separator: ",").map(String.init))
            let categoryParts = categories.split(separator: ",")
            let categorySet = Set(categoryParts.compactMap { UInt32($0) })
            guard !versionSet.isEmpty, versionSet.count <= 32, versionSet.allSatisfy({ $0.count <= 32 }),
                  categorySet.count == categoryParts.count, !categorySet.isEmpty else { throw ConfigurationError("Invalid App Attest versions/categories") }
            guard let audience = ShareAttestationPolicy.origin(config.publicBase),
                  config.publicBase.scheme?.lowercased() == "https" || (config.loopbackOnly && ["127.0.0.1", "localhost", "::1"].contains(config.publicBase.host ?? "")) else {
                throw ConfigurationError("App Attest requires an HTTPS public service origin (HTTP only for loopback probes)")
            }
            config.appAttest = .init(appID: appID, environment: environment, audience: audience, bundleVersions: versionSet, validationCategories: categorySet)
        }
        if let digest = env["BATON_SHARE_CONTACT_READER_DIGEST"] {
            let relayPort = try env["BATON_SHARE_CONTACT_RELAY_PORT"].map { value -> UInt16 in
                guard let port = UInt16(value), port != 0, port != config.port else {
                    throw ConfigurationError("invalid contact relay port")
                }
                return port
            }
            config.contactBridge = try ShareContactConfiguration(readerDigest: digest, relayPort: relayPort)
        }
        config.enforcement = try EnforcementConfiguration.fromEnvironment(env)
        return config
    }
}

public struct ConfigurationError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
