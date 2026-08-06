// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonSubsonicKit",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [.library(name: "BatonSubsonicKit", targets: ["BatonSubsonicKit"])],
    dependencies: [.package(path: "../BatonSubsonicModels")],
    targets: [
        .target(
            name: "BatonSubsonicKit",
            dependencies: ["BatonSubsonicModels"]
        )
    ]
)
