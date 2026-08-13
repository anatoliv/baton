import Foundation

/// CPU time this process has burned, and what that costs per second of audio.
///
/// **Why this exists.** The Mac has `powermetrics`, and Stage 6 used it: the engine costs
/// +1.6 energy impact across the app and the audio daemon, against a whole-machine power
/// difference too small to resolve. iOS has no per-app energy API at all, so the same
/// question cannot be asked the same way — and a simulator battery figure is a fact about
/// the Mac, which `docs/audio-engine-ios.md` says outright.
///
/// What *is* available on a phone is the process's own CPU time, which is the mechanism
/// behind the cost: the engine decodes in-process where AVPlayer hands the work to the
/// system. Sampled across a fixed stretch of playback and divided by the audio actually
/// heard, it gives a number that can be compared between the two paths on one device.
///
/// **What it is not.** Not energy. CPU time ignores the radio, the display, hardware decode
/// blocks and clock scaling, so it cannot say "this costs X% of a battery". It can say "this
/// path does N times the work of that one", which is the comparison the adoption decision
/// needs and the only one a device can give without Instruments.
public enum PlaybackCPUProbe {
    /// Total CPU seconds (user + system) charged to this process since launch.
    ///
    /// `TASK_ABSOLUTETIME_INFO` rather than summing threads: threads come and go — the
    /// render thread, the feeder, URLSession's pool — and a sum over live threads silently
    /// loses the ones that exited, which on a long soak is most of them.
    public static func processCPUSeconds() -> TimeInterval? {
        var info = task_absolutetime_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_absolutetime_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Mach absolute time units, which are not nanoseconds on every machine.
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return nil }
        let nanos = Double(info.total_user &+ info.total_system)
            * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }

    /// One measurement window: CPU burned against audio heard.
    public struct Sample: Equatable, Sendable {
        public let cpuSeconds: TimeInterval
        public let audioSeconds: TimeInterval

        public init(cpuSeconds: TimeInterval, audioSeconds: TimeInterval) {
            self.cpuSeconds = cpuSeconds
            self.audioSeconds = audioSeconds
        }

        /// Milliseconds of CPU per second of audio — the comparable number.
        ///
        /// Per *audio* second, not per wall-clock second, because a window that included a
        /// pause, a stall or a track change would otherwise read as cheaper simply for
        /// having played less.
        public var cpuMillisecondsPerAudioSecond: Double? {
            guard audioSeconds > 0 else { return nil }
            return cpuSeconds * 1000 / audioSeconds
        }

        public var summary: String {
            guard let cost = cpuMillisecondsPerAudioSecond else {
                return "no audio played — nothing to divide by"
            }
            return String(format: "%.1f ms CPU per audio second (%.0f s CPU over %.0f s of audio)",
                          cost, cpuSeconds, audioSeconds)
        }
    }

    /// Accumulates a window, so a run can be started and read from the UI.
    ///
    /// Deliberately anchored on *both* clocks at once: starting the CPU counter and the
    /// audio counter at the same instant is the only way the ratio means anything.
    public struct Window: Sendable {
        let startCPU: TimeInterval
        let startAudio: TimeInterval

        public init?(audioSecondsSoFar: TimeInterval) {
            guard let cpu = processCPUSeconds() else { return nil }
            startCPU = cpu
            startAudio = audioSecondsSoFar
        }

        public func sample(audioSecondsSoFar: TimeInterval) -> Sample? {
            guard let cpu = processCPUSeconds() else { return nil }
            return Sample(cpuSeconds: max(0, cpu - startCPU),
                          audioSeconds: max(0, audioSecondsSoFar - startAudio))
        }
    }
}
