// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonPlaybackKit",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [.library(name: "BatonPlaybackKit", targets: ["BatonPlaybackKit"])],
    dependencies: [
        .package(path: "../BatonSubsonicModels"),
        .package(path: "../BatonSubsonicKit"),
        .package(path: "../BatonDSP"),
        .package(path: "../BatonMCPProtocol"),
    ],
    targets: [
        .target(
            name: "BatonPlaybackKit",
            dependencies: ["BatonSubsonicModels", "BatonSubsonicKit", "BatonDSP", "BatonMCPProtocol"]
        ),
        .testTarget(
            name: "BatonPlaybackKitTests",
            dependencies: ["BatonPlaybackKit"]
        )
    ]
)
