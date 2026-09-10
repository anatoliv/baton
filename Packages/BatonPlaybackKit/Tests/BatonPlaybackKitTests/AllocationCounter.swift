import Darwin
import Foundation

/// Counts heap allocations made on the calling thread while a block runs.
///
/// libmalloc calls through the global `malloc_logger` function pointer on every allocation
/// and every free when one is installed, which is how `MallocStackLogging` works. Installing
/// our own for the length of one measurement is the only way to answer "did this call
/// allocate?" honestly: the zone statistics report *live* blocks, so a short-lived array that
/// is allocated and freed inside the measured block leaves them exactly where they started.
///
/// The hook fires on **every thread in the process**, not just the one being measured, and two
/// rules follow from that.
///
/// **It must not allocate**, or the allocation calls it again and the recursion runs off the
/// end of that thread's stack. This is not hypothetical. Until TBX-5373 the hook read
/// `AllocationCounter.targetThread`, a Swift `static var`, to decide whether the allocating
/// thread was the one being measured. In a debug build a `var` read compiles to
/// `swift_beginAccess`, and on a thread that has never taken a dynamic exclusivity access
/// `swift_beginAccess` heap-allocates that thread's access set. Measured over twenty full
/// `swift test -c debug` runs of `BatonPlaybackKitTests` on origin/main, the suite died with
/// `Bus error: 10` on 11 of the 20, always inside whichever allocation test ran first (it is
/// the first thing in the run that installs the hook), with a stack of
/// `hook -> swift_beginAccess -> SwiftTLSContext::get -> swift_slowAlloc -> malloc -> hook`
/// repeated to the stack guard page. Note that the thread filter could not prevent it: reading
/// the value the filter tests is what allocated.
///
/// So the hook touches no Swift `var` at all. The counters live in C storage reached through an
/// immutable `static let` pointer, because memory reached through an `UnsafeMutablePointer`
/// carries no exclusivity enforcement, and the thread filter runs before anything else so that
/// foreign threads leave as early as possible.
///
/// **It must be cheap**, because while a measurement is open every allocation on every thread
/// in the process pays for it. What is left is a bit test, one pointer load and a mach port
/// comparison.
///
/// Duplicated from `BatonDSPTests/AllocationCounter.swift` (PR #113 / S-F23) rather than
/// shared: the code this file measures, `EQTapContext.process(_:)`, lives in BatonPlaybackKit,
/// a different SPM package, and this helper is deliberately test-only. It has no business in
/// either package's shipping target. Keep the two copies identical apart from this
/// paragraph; `AllocationCounterSafetyTests` in each package is what proves they both work.
enum AllocationCounter {
    private typealias LoggerFn = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Everything the hook reads or writes, in one C allocation.
    private struct State {
        /// Mach port of the thread being measured, or 0 when no measurement is open.
        var target: mach_port_t = 0
        /// Non-zero while the hook body is running on the target thread, so an allocation made
        /// by the hook itself is ignored rather than recursed into. Nothing in the hook
        /// allocates today; this is what keeps that true after the next edit.
        var busy: Int32 = 0
        var count: Int = 0
    }

    nonisolated(unsafe) private static let state: UnsafeMutablePointer<State> = {
        let p = UnsafeMutablePointer<State>.allocate(capacity: 1)
        p.initialize(to: State())
        return p
    }()

    /// The hook. The `2` is `stack_logging_type_alloc` from libmalloc's private header, written
    /// as a literal rather than read from a named constant: this line runs on every thread, and
    /// a stored property is one more thing that could grow an accessor. Frees carry
    /// `stack_logging_type_dealloc` (4) instead, and a realloc carries both.
    nonisolated(unsafe) private static let hook: LoggerFn = { type, _, _, _, result, _ in
        guard type & 2 != 0, result != 0 else { return }
        let state = AllocationCounter.state
        guard pthread_mach_thread_np(pthread_self()) == state.pointee.target else { return }
        guard state.pointee.busy == 0 else { return }
        state.pointee.busy = 1
        state.pointee.count &+= 1
        state.pointee.busy = 0
    }

    /// The `malloc_logger` slot in libsystem_malloc, or nil if this platform does not export it.
    nonisolated(unsafe) private static let slot: UnsafeMutablePointer<LoggerFn?>? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: LoggerFn?.self)
    }()

    static var isAvailable: Bool { slot != nil }

    /// Run `body` and return how many allocations it made on this thread, or -1 if the hook
    /// could not be installed.
    static func measure(_ body: () -> Void) -> Int {
        guard let slot else { return -1 }
        // Resolve the lazily initialized globals before the hook can be called, so that the
        // only work left inside the hook is loads and stores.
        let state = AllocationCounter.state
        let hook = AllocationCounter.hook
        state.pointee.count = 0
        state.pointee.busy = 0
        state.pointee.target = pthread_mach_thread_np(pthread_self())

        let previous = slot.pointee
        slot.pointee = hook
        body()
        slot.pointee = previous

        // Clear the target only after the slot is restored: a thread that loaded the hook
        // pointer just before the restore still calls it, and 0 is a port no thread has, so it
        // leaves at the filter.
        let measured = state.pointee.count
        state.pointee.target = 0
        state.pointee.count = 0
        return measured
    }
}
