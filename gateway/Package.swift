// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "baton-gateway",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/BatonAgentKit"),
        .package(path: "../Packages/BatonSubsonicKit"),
        .package(path: "../Packages/BatonSubsonicModels"),
        .package(path: "../Packages/BatonMCPProtocol"),
        // Document clippings: the gateway renders the `PreparedBook` a device made, with the
        // same chunking and cache keys, so the format has one definition.
        .package(path: "../Packages/BatonDocuments"),
        .package(path: "../Packages/BatonShareKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "4.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.10.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
    ],
    targets: [
        // The gateway's testable logic. Split out of the executable because a target with
        // top-level code in `main.swift` cannot be imported by a test target cleanly, so
        // everything worth asserting on lived somewhere no test could reach it.
        //
        // The transports moved in here for exactly that reason: the POSIX one is what
        // runs in production and it sat in the executable behind `#else`, so on a Mac it was not
        // merely untested but uncompiled — which is how it came to kill the process on any client
        // that closed early, and to let a silent connection hold a thread indefinitely.
        // `BatonMCPProtocol` comes with them: it owns the HTTP request parsing they use.
        .target(name: "BatonGatewayCore", dependencies: ["BatonMCPProtocol", "BatonDocuments"]),
        .executableTarget(
            name: "baton-gateway",
            dependencies: [
                "BatonGatewayCore",
                "BatonAgentKit", "BatonSubsonicKit", "BatonSubsonicModels", "BatonMCPProtocol",
                "BatonDocuments",
            ]
        ),
        // `BatonSubsonicKit` is a *test-only* dependency of the core target's suite: the health
        // probe is generic over "some async call", but the call it is actually in front of is
        // `NavidromeClient.ping()`, retry and all. Asserting on a stand-in would have
        // missed the retry doubling that turned a 60s timeout into a 120s wait.
        .testTarget(name: "BatonGatewayCoreTests",
                    dependencies: ["BatonGatewayCore", "BatonSubsonicKit", "BatonDocuments"]),

        // `baton-share`: song links for friends outside the LAN (specs/song-sharing.md).
        //
        // A separate executable and a separate container from `baton-gateway`, on purpose. The
        // gateway holds a Navidrome password and an LLM key and is pinned to the LAN; this faces
        // the internet and holds no secret at all, so a compromise of it yields ciphertext and
        // play counts. What the two share is the transport, which is the part worth sharing:
        // its streaming upload, read deadlines and connection cap were each paid for in a card.
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3",
                       providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "BatonShareServer",
            dependencies: [
                "BatonGatewayCore", "BatonMCPProtocol", "BatonShareKit", "CSQLite",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.copy("Web"), .copy("AttestationRoots")]
        ),
        .executableTarget(name: "baton-share", dependencies: ["BatonShareServer"]),
        .testTarget(name: "BatonShareServerTests",
                    dependencies: ["BatonShareServer", "BatonShareKit", "BatonGatewayCore",
                                   .product(name: "Crypto", package: "swift-crypto"),
                                   .product(name: "X509", package: "swift-certificates"),
                                   .product(name: "SwiftASN1", package: "swift-asn1")]),
    ]
)
