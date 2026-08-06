import XCTest
@testable import BatonPlaybackKit

/// The stalled-stream recovery decision core (StreamingPlaybackController+StallRecovery):
/// grace window, cool-down, bounded attempts, and the disarm rules that keep a user
/// pause from ever being "recovered".
final class AudioStallRecoveryTests: XCTestCase {
    func testHealthyPlaybackNeverArms() {
        var policy = StallRecoveryPolicy()
        XCTAssertEqual(policy.evaluate(now: 0, intendsToPlay: true, isParked: false, bufferRecovered: true), .none)
        XCTAssertNil(policy.armedAt)
    }

    func testUserPauseDisarms() {
        var policy = StallRecoveryPolicy()
        _ = policy.evaluate(now: 0, intendsToPlay: true, isParked: true, bufferRecovered: false) // arms
        XCTAssertNotNil(policy.armedAt)
        _ = policy.evaluate(now: 1, intendsToPlay: false, isParked: true, bufferRecovered: true)
        XCTAssertNil(policy.armedAt, "losing the intent to play must disarm — a user pause is not a stall")
    }

    func testGracePeriodBeforeFirstRetry() {
        var policy = StallRecoveryPolicy()
        _ = policy.evaluate(now: 0, intendsToPlay: true, isParked: true, bufferRecovered: true) // arms at 0
        XCTAssertEqual(policy.evaluate(now: 3, intendsToPlay: true, isParked: true, bufferRecovered: true), .none)
        XCTAssertEqual(policy.evaluate(now: 7.1, intendsToPlay: true, isParked: true, bufferRecovered: true), .retryPlay)
    }

    func testNoRetryWhileBufferStarved() {
        var policy = StallRecoveryPolicy()
        _ = policy.evaluate(now: 0, intendsToPlay: true, isParked: true, bufferRecovered: false)
        XCTAssertEqual(policy.evaluate(now: 30, intendsToPlay: true, isParked: true, bufferRecovered: false), .none,
                       "a starved buffer means the network is still down — re-issuing play would do nothing")
    }

    func testCooldownBetweenAttempts() {
        var policy = StallRecoveryPolicy()
        _ = policy.evaluate(now: 0, intendsToPlay: true, isParked: true, bufferRecovered: true)
        XCTAssertEqual(policy.evaluate(now: 8, intendsToPlay: true, isParked: true, bufferRecovered: true), .retryPlay)
        XCTAssertEqual(policy.evaluate(now: 12, intendsToPlay: true, isParked: true, bufferRecovered: true), .none,
                       "second retry inside the cool-down would hammer a dying network")
        XCTAssertEqual(policy.evaluate(now: 18.5, intendsToPlay: true, isParked: true, bufferRecovered: true), .retryPlay)
    }

    func testAttemptsAreBoundedThenGiveUp() {
        var policy = StallRecoveryPolicy()
        _ = policy.evaluate(now: 0, intendsToPlay: true, isParked: true, bufferRecovered: true)
        var now: TimeInterval = 8
        var retries = 0
        for _ in 0 ..< 10 {
            if policy.evaluate(now: now, intendsToPlay: true, isParked: true, bufferRecovered: true) == .retryPlay {
                retries += 1
            }
            now += 11
        }
        XCTAssertEqual(retries, 3)
        XCTAssertEqual(policy.evaluate(now: now, intendsToPlay: true, isParked: true, bufferRecovered: true), .giveUp)
    }

    func testPlayingClearsEverything() {
        var policy = StallRecoveryPolicy()
        _ = policy.evaluate(now: 0, intendsToPlay: true, isParked: true, bufferRecovered: true)
        _ = policy.evaluate(now: 8, intendsToPlay: true, isParked: true, bufferRecovered: true)
        policy.notePlaying()
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertNil(policy.armedAt)
        // A later stall starts a fresh cycle with the full attempt budget.
        _ = policy.evaluate(now: 100, intendsToPlay: true, isParked: true, bufferRecovered: true)
        XCTAssertEqual(policy.evaluate(now: 108, intendsToPlay: true, isParked: true, bufferRecovered: true), .retryPlay)
    }
}
