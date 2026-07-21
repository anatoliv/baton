// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonDSP",
    platforms: [.macOS(.v15)],
    products: [.library(name: "BatonDSP", targets: ["BatonDSP"])],
    targets: [.target(name: "BatonDSP")]
)
