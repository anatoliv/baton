// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonSpeech",
    platforms: [.macOS(.v15)],
    products: [.library(name: "BatonSpeech", targets: ["BatonSpeech"])],
    targets: [.target(name: "BatonSpeech")]
)
