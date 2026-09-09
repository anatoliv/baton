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
/// The hook fires on every thread, so it filters on the mach port of the thread that started
/// the measurement. It must not allocate itself, or it would recurse.
enum AllocationCounter {
    private typealias LoggerFn = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `stack_logging_type_alloc` from libmalloc's private header. Frees carry
    /// `stack_logging_type_dealloc` (4) instead, and a realloc carries both.
    private static let allocateType: UInt32 = 2

    nonisolated(unsafe) private static var targetThread: mach_port_t = 0
    nonisolated(unsafe) private static var count: Int = 0

    nonisolated(unsafe) private static let hook: LoggerFn = { type, _, _, _, result, _ in
        guard type & AllocationCounter.allocateType != 0, result != 0 else { return }
        guard pthread_mach_thread_np(pthread_self()) == AllocationCounter.targetThread else { return }
        AllocationCounter.count &+= 1
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
        let previous = slot.pointee
        targetThread = pthread_mach_thread_np(pthread_self())
        count = 0
        slot.pointee = hook
        body()
        slot.pointee = previous
        let measured = count
        targetThread = 0
        count = 0
        return measured
    }
}
