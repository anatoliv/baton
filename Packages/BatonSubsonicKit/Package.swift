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
        ),
        // What coverage this package had was borrowed from the macOS app target, so
        // `swift test` here was vacuous and the iPhone gate ran none of it while shipping
        // the same code. This target runs against the package itself.
        .testTarget(
            name: "BatonSubsonicKitTests",
            dependencies: ["BatonSubsonicKit"]
        )
    ]
)
