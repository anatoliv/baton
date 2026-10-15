// swift-tools-version:6.0
import PackageDescription

// The song-sharing contract in one place (specs/song-sharing.md): the BSH1 format, the link, the
// wire types and the limits. Imported by the apps, which seal and upload, and by `baton-share`,
// which validates and stores — so the two cannot disagree about a field name or a cap.
//
// It builds on Linux because the service does. CryptoKit is used where it exists; swift-crypto,
// Apple's own source-compatible implementation, stands in for it on Linux only, so the apps link
// nothing new.
let package = Package(
    name: "BatonShareKit",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [.library(name: "BatonShareKit", targets: ["BatonShareKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "4.0.0"),
    ],
    targets: [
        .target(
            name: "BatonShareKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(name: "BatonShareKitTests", dependencies: ["BatonShareKit"]),
    ]
)
