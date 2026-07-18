import Foundation

/// Small runtime-environment flags for Baton (replaces Tonebox's `AppModelRuntimeOptions`).
enum BatonRuntime {
    /// True when running under XCTest — used to keep the player from touching the real
    /// system Now Playing / persisted defaults during tests.
    static var isTest: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
