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
        .target(name: "BatonGatewayCore"),
        .executableTarget(
            name: "baton-gateway",
            dependencies: [
                "BatonGatewayCore",
                "BatonAgentKit", "BatonSubsonicKit", "BatonSubsonicModels", "BatonMCPProtocol",
            ]
        ),
        .testTarget(name: "BatonGatewayCoreTests", dependencies: ["BatonGatewayCore"]),
    ]
)
