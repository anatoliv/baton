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
        .target(name: "BatonGatewayCore", dependencies: ["BatonMCPProtocol"]),
        .executableTarget(
            name: "baton-gateway",
            dependencies: [
                "BatonGatewayCore",
                "BatonAgentKit", "BatonSubsonicKit", "BatonSubsonicModels", "BatonMCPProtocol",
            ]
        ),
        // `BatonSubsonicKit` is a *test-only* dependency of the core target's suite: the health
        // probe is generic over "some async call", but the call it is actually in front of is
        // `NavidromeClient.ping()`, retry and all. Asserting on a stand-in would have
        // missed the retry doubling that turned a 60s timeout into a 120s wait.
        .testTarget(name: "BatonGatewayCoreTests",
                    dependencies: ["BatonGatewayCore", "BatonSubsonicKit"]),
    ]
)
