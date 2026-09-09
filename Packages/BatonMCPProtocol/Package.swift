// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonMCPProtocol",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "BatonMCPProtocol", targets: ["BatonMCPProtocol"])],
    targets: [
        .target(name: "BatonMCPProtocol"),
        // The package's first test target (S-F24). What coverage this module had was borrowed
        // from the macOS app target, so `swift test` here was vacuous and the iPhone gate ran
        // none of it while shipping the same parsing and framing code.
        .testTarget(name: "BatonMCPProtocolTests", dependencies: ["BatonMCPProtocol"]),
    ]
)
