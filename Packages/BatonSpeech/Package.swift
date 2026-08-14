// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonSpeech",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "BatonSpeech", targets: ["BatonSpeech"])],
    // The `Transcript` model lives in the leaf model package so `BatonPlaybackKit` can
    // store one without depending on this package, which has no watchOS build.
    dependencies: [.package(path: "../BatonSubsonicModels")],
    targets: [.target(name: "BatonSpeech", dependencies: ["BatonSubsonicModels"])]
)
