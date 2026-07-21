import Foundation

/// Small runtime-environment flags for Baton (replaces Tonebox's `AppModelRuntimeOptions`).
enum BatonRuntime {
    /// True when running under XCTest — used to keep the player from touching the real
    /// system Now Playing / persisted defaults during tests. Prefer `BatonEnvironment` over calling
    /// this directly: it is the single sniff point that `BatonEnvironment.current` reads.
    static var isTest: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// The composition-root switch between the real app and a test run. This replaces the scattered
/// `BatonRuntime.isTest` checks that were baked into individual stores' production defaults: stores
/// now take an explicit `environment` (defaulting to the auto-detected `.current`) instead of each
/// deciding for itself, and `MusicModel(environment:)` threads one value through the whole player.
/// `.current` is the *only* place that sniffs the runtime. (W-49 / ARCH-32)
enum BatonEnvironment: Sendable {
    /// The shipping app: real UserDefaults, system Now Playing, network monitoring, Keychain.
    case production
    /// A unit-test run: isolated defaults, no system Now Playing / network side effects.
    case testing

    /// Auto-detected default — `.testing` under XCTest, else `.production`. The single runtime sniff.
    static var current: BatonEnvironment { BatonRuntime.isTest ? .testing : .production }

    var isTesting: Bool { self == .testing }
}
