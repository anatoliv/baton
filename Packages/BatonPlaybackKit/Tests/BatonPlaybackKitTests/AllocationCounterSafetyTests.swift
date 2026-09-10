import Darwin
import XCTest

private typealias ThreadBody = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
private typealias PthreadCreateFn =
    @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer?, ThreadBody, UnsafeMutableRawPointer?) -> Int32
private typealias PthreadJoinFn = @convention(c) (OpaquePointer, UnsafeMutableRawPointer?) -> Int32

/// How long each spinner allocates for. Comfortably longer than the measurement phase below,
/// which is `windows * windowMilliseconds` plus the time it takes the threads to get going.
private let spinnerNanoseconds: UInt64 = 3_000_000_000

/// A thread that does nothing but allocate and free for a fixed stretch of time, marking two
/// words of C storage as it goes: `w[0]` on entry, `w[1]` on the way out.
///
/// Deliberately a `@convention(c)` function rather than a Swift closure, touching nothing but
/// raw pointers, `malloc` and the clock. That is the whole point of the fixture: the thread
/// has to reach the malloc hook without ever having taken a dynamic exclusivity access,
/// because a thread that already owns a `SwiftTLSContext` cannot reproduce the crash.
///
/// It stops on a clock rather than on a flag the test sets. A first version spun on
/// `while w[0] != 0`, which is fine in a debug build and hangs forever in a release one: the
/// load is an ordinary non-atomic read of memory no other thread visibly writes, so the
/// optimizer hoists it out of the loop and the thread never sees the stop. `swift test -c
/// release` sat in `pthread_join` for thirteen minutes before that was noticed. The two marker
/// words are plain stores read only after `pthread_join`, which is a barrier, so they are
/// sound without atomics.
private let allocationSpinner: ThreadBody = { arg in
    guard let arg else { return nil }
    let w = arg.assumingMemoryBound(to: Int32.self)
    w[0] = 1
    let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + spinnerNanoseconds
    while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {
        let p = malloc(64)
        free(p)
    }
    w[1] = 1
    return nil
}

/// `pthread_create` and `pthread_join` are reached through `dlsym` rather than called directly.
/// Calling the imported `pthread_create` from Swift 6 language mode crashes swift-frontend
/// 6.3.3 in its `SendNonSendable` pass (`swift::Partition::merge` aborts), on a three-line file
/// with no XCTest in it at all. That is a compiler bug and not something this test can fix, so
/// it goes around it: the symbols are looked up at runtime and called through function pointers
/// this file declares, which the region analysis is happy with.
private enum CThreads {
    static let create: PthreadCreateFn? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_create") else { return nil }
        return unsafeBitCast(s, to: PthreadCreateFn.self)
    }()

    static let join: PthreadJoinFn? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_join") else { return nil }
        return unsafeBitCast(s, to: PthreadJoinFn.self)
    }()
}

/// The malloc hook `AllocationCounter` installs is process-global: while a measurement is open
/// it runs on every thread that allocates, not only the one being measured. TBX-5373 is what
/// happens when the hook is not written for that. It read a Swift `static var`, a `var` read in
/// a debug build calls `swift_beginAccess`, and on a thread with no exclusivity thread-local
/// yet that heap-allocates, which calls the hook again until the stack runs out.
/// `BatonPlaybackKitTests` died with `Bus error: 10` on a random subset of debug runs.
///
/// This test builds the condition on purpose rather than waiting for a large suite to wander
/// into it: four brand new threads allocating hard across a few hundred measurements. On the
/// old hook it does not fail an assertion, it kills the process, which is precisely the defect
/// the card is about. On the fixed hook it is quiet.
///
/// It only reproduces in a debug build, and that is right rather than a gap: `swift_beginAccess`
/// is not emitted at all when exclusivity is enforced statically, so a release build never had
/// the bug. The two assertions below still say something in release, so the test runs there too
/// instead of skipping.
final class AllocationCounterSafetyTests: XCTestCase {
    private let spinnerCount = 4
    private let measurements = 300
    /// Twenty windows of 25 ms: half a second with the hook installed and four threads
    /// allocating into it, which is enough for the old hook to die every time.
    private let windows = 20
    private let windowMilliseconds = 25

    func testForeignThreadsAllocatingDuringAMeasurementAreSurvivedAndNotCounted() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger is not available here")
        guard let create = CThreads.create, let join = CThreads.join else {
            return XCTFail("could not resolve pthread_create or pthread_join")
        }

        let n = spinnerCount
        // words[2i] is set by spinner i on entry, words[2i + 1] on the way out. Both are read
        // only after `pthread_join`, never spun on: see the note on `allocationSpinner`.
        let words = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * n)
        words.initialize(repeating: 0, count: 2 * n)
        let handles = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: n)
        handles.initialize(repeating: nil, count: n)

        var started = 0
        while started < n {
            let slot = handles + started
            let rc = create(
                UnsafeMutableRawPointer(slot), nil, allocationSpinner,
                UnsafeMutableRawPointer(words + 2 * started)
            )
            if rc != 0 || slot.pointee == nil { break }
            started += 1
        }
        XCTAssertEqual(started, n, "could not start \(n) spinner threads")

        if started == n {
            // Give the spinners a moment to be inside their loops, so the measurements below
            // really do overlap other threads allocating rather than racing thread creation.
            // A fixed sleep rather than a readiness handshake, for the same reason the spinner
            // stops on a clock: a loop spinning on a plain read of another thread's write is
            // not sound once the optimizer sees it.
            usleep(100_000)

            // Hold each measurement open for a while. A window of a few microseconds almost
            // never overlaps another thread actually being inside `malloc`, which is why the
            // real failure needed a 621-test suite and a run of bad luck. An earlier version
            // measured 600 trivial blocks back to back, finished in 2 ms, and passed on the
            // broken hook. The body spins on the clock and allocates nothing, so `empty` below
            // stays a real assertion.
            var empty = 0
            var window = 0
            while window < windows {
                let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    + UInt64(windowMilliseconds) * 1_000_000
                empty += AllocationCounter.measure {
                    while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {}
                }
                window += 1
            }

            var allocating = 0
            var round = 0
            while round < measurements {
                allocating += AllocationCounter.measure {
                    let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)
                    p.deallocate()
                }
                round += 1
            }

            XCTAssertEqual(empty, 0, "\(empty) allocations made on other threads were charged to this one")
            XCTAssertGreaterThanOrEqual(
                allocating, measurements,
                "the hook counted \(allocating) over \(measurements) measured allocations of its own, so it has stopped measuring"
            )
        }

        var i = 0
        while i < started {
            if let t = handles[i] { _ = join(t, nil) }
            i += 1
        }
        i = 0
        while i < started {
            XCTAssertEqual(words[2 * i], 1, "spinner \(i) never entered its loop")
            XCTAssertEqual(words[2 * i + 1], 1, "spinner \(i) never finished its loop")
            i += 1
        }
        handles.deinitialize(count: n)
        handles.deallocate()
        words.deallocate()
    }
}
