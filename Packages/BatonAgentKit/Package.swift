// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonAgentKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "BatonAgentKit", targets: ["BatonAgentKit"])],
    dependencies: [
        .package(path: "../BatonSubsonicModels"),
        .package(path: "../BatonSubsonicKit"),
        // `HTTPModelClient`, the app's one model client: the transcript summarizer speaks to its
        // model through it rather than through a second copy of the same requests (M4.2b).
        // BatonDocuments depends on Foundation alone, so this adds no cycle and builds on Linux.
        .package(path: "../BatonDocuments"),
    ],
    targets: [
        .target(
            name: "BatonAgentKit",
            dependencies: [
                "BatonSubsonicModels",
                "BatonSubsonicKit",
                "BatonDocuments",
                // No BatonPlaybackKit. This used to be a *conditional* dependency, excluded on
                // non-Apple platforms with the note "so the headless gateway can run this
                // package on Linux" — the right intent, defeated by the sources importing it
                // unconditionally anyway. Nothing caught that, because the only thing that
                // builds the gateway is `scripts/test.sh`, on macOS.
                //
                // The coupling was three read-only properties, now expressed as
                // `RemotePlayerContext` in BatonSubsonicModels. With the protocol there is
                // nothing to exclude and no condition to get wrong.
            ]
        ),
        .testTarget(
            name: "BatonAgentKitTests",
            dependencies: ["BatonAgentKit"]
        )
    ]
)
