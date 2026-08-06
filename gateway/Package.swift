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
        .executableTarget(
            name: "baton-gateway",
            dependencies: [
                "BatonAgentKit", "BatonSubsonicKit", "BatonSubsonicModels", "BatonMCPProtocol",
            ]
        )
    ]
)
