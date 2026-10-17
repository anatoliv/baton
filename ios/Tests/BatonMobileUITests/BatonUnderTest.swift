import XCTest

extension XCUIApplication {
    /// Baton as every phone UI test launches it: with preference sync switched off
    /// (`BATON_DEBUG_PREFERENCE_SYNC=off`, read by `MobileModel.isPreferenceSyncSwitchedOff`).
    /// A test instance must never take part in the owner's shared settings. On 2026-10-14 a
    /// reset test state travelled as the newest word, emptied the shared agent settings and
    /// replaced the gateway address with a loopback relay. Set here once, rather than by each
    /// suite, because 30 suites had been written without it. `scripts/test.sh`
    /// fails the lints on a bare `XCUIApplication()` anywhere else in this target.
    static func batonUnderTest() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BATON_DEBUG_PREFERENCE_SYNC"] = "off"
        return app
    }
}
