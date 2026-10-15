// swift-tools-version:6.0
import PackageDescription

// Kokoro on this Mac (TBX-10854, board M7.5): the built-in "This Mac" voice engine for
// document clippings. Mac only: nothing in ios/ or Shared/ may depend on this package, so the
// iPhone app links no MLX (see VENDORED.md).
//
// The pins are exact on purpose. TBX-10849 measured kokoro-ios 1.0.10 on mlx-swift 0.29.1 at
// WER 0.4%, the same as the LAN server; the next pair (1.0.11 on 0.30.2) drops about a quarter
// of the words. Any MLX upgrade re-runs that check (spikes/kokoro-mlx/wer.py) before it lands.
let package = Package(
    name: "BatonKokoroMLX",
    platforms: [.macOS(.v15)],
    products: [
        // Static (the default), unlike upstream's `.dynamic`, which made SwiftPM refuse the graph
        // because two dynamic libraries each embedded MLX (kokoro-ios issue #26).
        .library(name: "BatonKokoroMLX", targets: ["BatonKokoroMLX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.29.1"),
        .package(url: "https://github.com/mlalma/MisakiSwift", exact: "1.0.5"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
    ],
    targets: [
        // mlalma/kokoro-ios 1.0.10 (9a1e2614), MIT, vendored: see VENDORED.md for what changed.
        .target(
            name: "KokoroSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MisakiSwift", package: "MisakiSwift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
            ],
            exclude: ["LICENSE"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BatonKokoroMLX",
            dependencies: [
                "KokoroSwift",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
            ]
        ),
        .testTarget(name: "BatonKokoroMLXTests", dependencies: ["BatonKokoroMLX"]),
    ]
)
