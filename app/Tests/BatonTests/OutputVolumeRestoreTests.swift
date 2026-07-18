import Testing
@testable import Baton

/// The pure duck/restore decision logic — the part that was losing volume across
/// rapid dictation cycles. No CoreAudio here (that's exercised live).
@MainActor
@Suite("Output volume restore")
struct OutputVolumeRestoreTests {
    // MARK: - baseline

    @Test("Baseline is the current level when nothing is fading")
    func baselineIdle() {
        #expect(OutputVolumeController.baseline(current: 0.65, fadeTarget: nil) == 0.65)
    }

    @Test("Baseline recovers the true original mid restore-fade")
    func baselineMidRestore() {
        // A restore-fade is ramping 0.15 → 0.65 and we're at 0.40 when the next
        // duck fires. The real level is 0.65, not the mid-fade 0.40.
        #expect(OutputVolumeController.baseline(current: 0.40, fadeTarget: 0.65) == 0.65)
    }

    @Test("Baseline ignores a lower fade target (never lowers the original)")
    func baselineLowerTarget() {
        #expect(OutputVolumeController.baseline(current: 0.50, fadeTarget: 0.15) == 0.50)
    }

    // MARK: - shouldRestore

    @Test("Restores when the level matches what we last wrote")
    func restoreOurValue() {
        #expect(OutputVolumeController.shouldRestore(current: 0.15, lastWritten: 0.15, duckedVolume: 0.15))
    }

    @Test("Restores after an interrupted duck-fade (current never reached ducked)")
    func restoreInterruptedDuck() {
        // Short take: duck-fade only got to 0.42 before stop; lastWritten tracks it.
        #expect(OutputVolumeController.shouldRestore(current: 0.42, lastWritten: 0.42, duckedVolume: 0.15))
    }

    @Test("Leaves the volume alone when the user moved the slider")
    func skipUserChange() {
        #expect(!OutputVolumeController.shouldRestore(current: 0.90, lastWritten: 0.15, duckedVolume: 0.15))
    }

    // MARK: - No progressive loss across cycles

    @Test("Original volume survives rapid duck/restore cycles")
    func noProgressiveLoss() {
        let trueOriginal: Float = 0.65
        // Cycle 1: idle → duck. Baseline == the real level.
        var baseline = OutputVolumeController.baseline(current: trueOriginal, fadeTarget: nil)
        #expect(baseline == trueOriginal)
        // Restore-fade heads back to `baseline`; the NEXT duck fires mid-fade at 0.33.
        baseline = OutputVolumeController.baseline(current: 0.33, fadeTarget: baseline)
        #expect(baseline == trueOriginal) // not 0.33 — no creep
        // And once more, still mid-fade.
        baseline = OutputVolumeController.baseline(current: 0.48, fadeTarget: baseline)
        #expect(baseline == trueOriginal)
    }
}
