import Synchronization

/// The hand-off from the audio render thread to the UI.
///
/// The render thread may not block — no locks, no allocation, no waiting — and the UI reads
/// whenever it draws. Four levels pack into one `UInt32` (one byte each), so publishing is a
/// single atomic store and reading is a single atomic load: lock-free by construction, and
/// impossible to tear into a mix of old and new bars.
///
/// One byte per band is 1/255 of a 15-point bar — far finer than anything visible. Trading
/// that resolution for a single-word atomic is what removes the synchronization problem
/// entirely rather than managing it.
public final class LevelSnapshot: Sendable {
    private let packed = Atomic<UInt32>(0)

    public init() {}

    public func store(_ levels: BandLevels) {
        packed.store(Self.pack(levels), ordering: .relaxed)
    }

    public func load() -> BandLevels {
        Self.unpack(packed.load(ordering: .relaxed))
    }

    /// Zero the meter — on stop, track change, or when the tap goes away, so the bars don't
    /// hold the last frame of the previous track.
    public func clear() {
        packed.store(0, ordering: .relaxed)
    }

    static func pack(_ l: BandLevels) -> UInt32 {
        func byte(_ v: Float) -> UInt32 {
            guard v.isFinite else { return 0 }
            return UInt32(min(max(v, 0), 1) * 255)
        }
        return byte(l.low) | (byte(l.lowMid) << 8) | (byte(l.highMid) << 16) | (byte(l.high) << 24)
    }

    static func unpack(_ p: UInt32) -> BandLevels {
        func value(_ shift: UInt32) -> Float { Float((p >> shift) & 0xFF) / 255 }
        return BandLevels(low: value(0), lowMid: value(8), highMid: value(16), high: value(24))
    }
}
