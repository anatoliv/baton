// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonAgentKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "BatonAgentKit", targets: ["BatonAgentKit"])],
    dependencies: [
        .package(path: "../BatonSubsonicModels"),
        .package(path: "../BatonSubsonicKit"),
        .package(path: "../BatonPlaybackKit"),
    ],
    targets: [
        .target(
            name: "BatonAgentKit",
            dependencies: [
                "BatonSubsonicModels",
                "BatonSubsonicKit",
                // The playback engine is AVFoundation/MediaPlayer/MediaToolbox and
                // never ports; the agent LOOP needs none of it. Apple-only, so the
                // headless gateway can run this package on Linux.
                .product(name: "BatonPlaybackKit", package: "BatonPlaybackKit",
                         condition: .when(platforms: [.macOS, .iOS, .watchOS, .tvOS])),
            ]
        ),
        .testTarget(
            name: "BatonAgentKitTests",
            dependencies: ["BatonAgentKit"]
        )
    ]
)
