// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BatonSpeech",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "BatonSpeech", targets: ["BatonSpeech"])],
    // The `Transcript` model lives in the leaf model package so `BatonPlaybackKit` can
    // store one without depending on this package, which has no watchOS build.
    // `BatonSubsonicKit` for `BatonStorage`, which is the single answer to "which
    // preferences domain is this process using". `SpeechConfig.defaults` is a mutable static
    // and the composition root could assign it instead — but a wiring step that can be
    // forgotten is exactly how one store ends up in a different domain from the rest, which
    // is the failure `BatonStorage` exists to make impossible.
    dependencies: [
        .package(path: "../BatonSubsonicModels"),
        .package(path: "../BatonSubsonicKit"),
    ],
    targets: [
        .target(name: "BatonSpeech", dependencies: ["BatonSubsonicModels", "BatonSubsonicKit"]),
        // The package's first test target (S-F23 and S-F24). Its assertions all lived in the
        // macOS app target, so `swift test` here was vacuous and the iPhone gate ran none of
        // them while shipping the same code. `BatonSubsonicModels` is a direct test dependency
        // because `Transcript` is what the response parser returns.
        .testTarget(name: "BatonSpeechTests",
                    dependencies: ["BatonSpeech", "BatonSubsonicModels"]),
    ]
)
