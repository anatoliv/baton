// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonSubsonicModels",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [.library(name: "BatonSubsonicModels", targets: ["BatonSubsonicModels"])],
    targets: [
        .target(name: "BatonSubsonicModels"),
        .testTarget(name: "BatonSubsonicModelsTests", dependencies: ["BatonSubsonicModels"]),
    ]
)
