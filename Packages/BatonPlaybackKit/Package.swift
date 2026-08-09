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
            dependencies: ["BatonPlaybackKit"],
            // A real MP3 (68 s, 48 kHz stereo, from the demo library) — the engine tests
            // stream it over local HTTP to prove the decode path on the load-bearing format.
            resources: [.copy("Fixtures")]
        )
    ]
)
