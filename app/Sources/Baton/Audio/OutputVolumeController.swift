import CoreAudio
import Foundation
import OSLog

/// Lowers the system output volume while a recording is in flight and
/// restores it afterward — so whatever is playing (music, a video, a
/// meeting) ducks the moment capture starts.
///
/// macOS has **no public API to duck individual apps**; the tools that do
/// (Rogue Amoeba SoundSource, Background Music) ship a virtual CoreAudio
/// HAL driver. So this adjusts the *default output device's* master volume
/// instead. That's a global duck, which fits Tonebox well: we record the
/// **mic**, so quieting the speakers also cuts speaker bleed into the take,
/// and mic capture never picks up the system output anyway. The one case we
/// deliberately skip is when System Audio is itself a recording source — see
/// `AppModel.maybeDuckOutputVolume` — since ducking would fight that capture.
///
/// Robustness notes:
///   - Snapshots the specific device + level at duck time; restores *that*
///     device even if the user switches outputs mid-recording.
///   - On restore, if the current level no longer matches what we set, the
///     user changed it during the take — we respect that and don't clobber.
///   - Devices with no software volume (many HDMI/aggregate outputs) are
///     detected via `HasProperty`/`IsSettable` and quietly skipped.
@MainActor
final class OutputVolumeController {
    /// One shared ducker across every capture path (library recording and
    /// Dictation). A single instance means one snapshot/restore authority —
    /// a second `duck()` while already ducked is a safe no-op rather than two
    /// controllers fighting over the same device.
    static let shared = OutputVolumeController()

    private let log = Logger(subsystem: "io.tonebox.baton", category: "output-volume")

    /// Read-back match tolerance. Wider than a built-in speaker's 1/16 (0.0625)
    /// volume-step quantization, so a legitimately snapped level isn't mistaken for a
    /// rejected write — but tight enough that a stuck-near-duck level is still caught.
    private static let restoreTolerance: Float = 0.06


    /// What we lowered, captured so we can put it back exactly.
    private struct Snapshot {
        let deviceID: AudioDeviceID
        let originalVolume: Float
        let duckedVolume: Float
    }

    private var active: Snapshot?
    private var fadeTask: Task<Void, Never>?
    /// Re-asserts the restored level a few times for Bluetooth / abs-volume outputs
    /// (e.g. JBL PartyBox) that silently drop a single volume command. Cancelled by a
    /// new duck so it never fights a fresh snapshot.
    private var restoreReassertTask: Task<Void, Never>?

    /// UserDefaults keys for a **pending restore** — the pre-duck volume persisted the
    /// instant we duck, so a session that dies while ducked (crash, force-quit, a dev
    /// relaunch) can be recovered on next launch instead of stranding the volume low.
    private static let pendingDeviceKey = "tonebox.outputVolume.pendingDeviceID"
    private static let pendingOriginalKey = "tonebox.outputVolume.pendingOriginal"
    /// The stable device UID saved alongside the ephemeral id, so recovery can confirm the id
    /// still names the same physical device before touching its volume. (W-45 / AUDIO-22)
    private static let pendingDeviceUIDKey = "tonebox.outputVolume.pendingDeviceUID"

    private init() {
        recoverStuckVolumeFromPreviousSession()
    }

    /// If the previous run persisted a pending restore and never cleared it, that run
    /// died while ducked — put the volume back now. Ephemeral device IDs mean the
    /// ducked device may be gone (disconnected); `setVolume` no-ops there, which is
    /// correct (a disconnected device's level is moot). Runs once at launch, before
    /// any new duck, so it can't fight a live snapshot.
    func recoverStuckVolumeFromPreviousSession() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.pendingDeviceKey) != nil else { return }
        let deviceID = AudioDeviceID(defaults.integer(forKey: Self.pendingDeviceKey))
        let original = defaults.float(forKey: Self.pendingOriginalKey)
        let savedUID = defaults.string(forKey: Self.pendingDeviceUIDKey)
        clearPendingRestore()
        // AudioDeviceIDs aren't stable across reboots / coreaudiod restarts — the id may now name
        // a DIFFERENT device. Only restore if the current UID for this id matches the saved one;
        // otherwise skip rather than change some other output's volume. (W-45 / AUDIO-22)
        if let savedUID, Self.deviceUID(deviceID) != savedUID {
            log.notice("recover: device id \(deviceID) now names a different device — skipping restore")
            return
        }
        let ok = Self.setVolume(original, of: deviceID)
        log.error(
            "recover: previous session left device \(deviceID) (\(Self.deviceName(deviceID), privacy: .public)) ducked; restore to \(original, format: .fixed(precision: 2)) \(ok ? "ok" : "skipped(device gone)", privacy: .public)"
        )
    }

    private func persistPendingRestore(_ snap: Snapshot) {
        let defaults = UserDefaults.standard
        defaults.set(Int(snap.deviceID), forKey: Self.pendingDeviceKey)
        defaults.set(snap.originalVolume, forKey: Self.pendingOriginalKey)
        defaults.set(Self.deviceUID(snap.deviceID), forKey: Self.pendingDeviceUIDKey)
    }

    private func clearPendingRestore() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingDeviceKey)
        defaults.removeObject(forKey: Self.pendingOriginalKey)
        defaults.removeObject(forKey: Self.pendingDeviceUIDKey)
    }
    /// Where the in-flight fade is heading (nil when idle). Lets `duck()` recover
    /// the user's true level when a restore-fade is still ramping back up.
    private var fadeTarget: Float?
    /// The last volume WE wrote — so `restore()` can tell "we set this" from "the
    /// user moved the slider" even when a duck-fade was interrupted.
    private var lastWritten: Float?
    /// Where an in-flight *restore* re-assert is heading (nil when idle). Mirrors
    /// `fadeTarget` for the restore direction: lets a `duck()` that interrupts a restore
    /// recover the user's TRUE original instead of snapshotting a mid-restore level (which
    /// would shed a little volume every rapid duck→restore→duck cycle).
    private var restoreTarget: Float?

    // MARK: - Pure decision logic (unit-tested; no CoreAudio)

    /// The user's true pre-duck level. If a restore-fade is still ramping up
    /// toward a saved original, that target IS the real volume — snapshotting the
    /// mid-fade `current` would shed a little volume each rapid duck/restore cycle.
    static func baseline(current: Float, fadeTarget: Float?) -> Float {
        max(current, fadeTarget ?? current)
    }

    /// Whether `restore()` should put the volume back. True when the current level
    /// is one WE set (matches our last write within tolerance); false means the
    /// user moved the slider mid-take, so we leave it alone.
    static func shouldRestore(
        current: Float,
        lastWritten: Float?,
        duckedVolume: Float,
        tolerance: Float = 0.05
    ) -> Bool {
        abs(current - (lastWritten ?? duckedVolume)) <= tolerance
    }

    /// Lower the default output device to `target` (0…1), fading over a
    /// short ramp. No-op if already ducked, if there's no controllable
    /// output, or if the device is already at/below the target.
    func duck(to target: Float) {
        guard active == nil else { return }
        guard let deviceID = Self.defaultOutputDeviceID() else {
            log.info("No default output device; skipping duck")
            return
        }
        guard let current = Self.volume(of: deviceID) else {
            log.info("Output device has no settable volume; skipping duck")
            return
        }
        let clampedTarget = Self.clamp(target)
        // Recover the user's TRUE level even if a restore re-assert is still in flight
        // (fadeTarget covers duck fades; restoreTarget covers the restore direction).
        let baseline = Self.baseline(current: current, fadeTarget: fadeTarget ?? restoreTarget)
        guard clampedTarget < baseline - 0.001 else { return }
        // A fresh duck supersedes any lingering restore re-assert from the last cycle.
        restoreReassertTask?.cancel()
        restoreReassertTask = nil
        restoreTarget = nil
        let snap = Snapshot(deviceID: deviceID, originalVolume: baseline, duckedVolume: clampedTarget)
        active = snap
        // Persist the pre-duck level BEFORE we lower anything, so a crash/quit mid-duck
        // is recoverable on next launch (see `recoverStuckVolumeFromPreviousSession`).
        persistPendingRestore(snap)
        // `.error` level so the captured baseline persists in the log store — pairs
        // with the restore log so a "stuck low" report is diagnosable.
        log
            .error(
                "duck: device \(deviceID) (\(Self.deviceName(deviceID), privacy: .public)) baseline \(baseline, format: .fixed(precision: 2)) → \(clampedTarget, format: .fixed(precision: 2))"
            )
        fade(deviceID: deviceID, from: current, to: clampedTarget)
    }

    /// Put the volume back to **exactly** where it was before we ducked. Writes the
    /// captured original directly and unconditionally — no reading the level back, no
    /// comparison, no fade — because those were the surfaces where a device that
    /// reports its level oddly (or a starved restore-fade during transcription) left
    /// the volume stuck low. This guarantees "before == after" every time; the only
    /// trade-off is that a mid-take slider change is overridden, which is the behavior
    /// the user asked for. Safe to call unconditionally; no-op when nothing was ducked.
    func restore() {
        guard let snap = active else { return }
        active = nil
        // The pending-restore record has served its purpose; clear it so next launch
        // doesn't think we died mid-duck.
        clearPendingRestore()
        // Stop any in-flight duck fade so it can't keep writing after us.
        fadeTask?.cancel()
        fadeTask = nil
        fadeTarget = nil

        let device = snap.deviceID
        let target = snap.originalVolume

        // Put the volume back to the TRUE original immediately and synchronously — this
        // one write IS the whole restore for well-behaved outputs (built-in speakers,
        // most USB/HDMI). It does not depend on any async ramp, so the transcription
        // pipeline that runs next on this same main actor can't starve it and strand the
        // volume near the ducked level. (The old code only wrote 1/16 synchronously and
        // left the rest to a main-actor ramp task, which is exactly what got starved.)
        //
        // READ-BACK SAFETY NET: some devices/driver states silently reject a write, so
        // verify the level actually took and retry a few times right here — correcting a
        // rejected write NOW instead of leaving it to the async re-assert. The tolerance
        // clears the built-in speaker's 1/16 (0.0625) volume quantization so a legitimately
        // snapped value isn't mistaken for a rejection and looped on forever.
        write(target, to: device)
        var after = Self.volume(of: device) ?? -1
        var retries = 0
        while after >= 0, abs(after - target) > Self.restoreTolerance, retries < 4 {
            Self.setVolume(target, of: device)
            after = Self.volume(of: device) ?? -1
            retries += 1
        }

        // WATCHDOG. The synchronous write above restores the level immediately — but on
        // some Macs macOS itself lowers system output a beat *after* the mic session ends
        // (confirmed by correlating our log with a volume poll: the level drops back toward
        // the duck value ~3 s post-restore with no duck of ours). So for a few seconds we
        // keep an eye on the output and, if something external steals it back *down* (never
        // if the user raises it), put our target back. This also covers Bluetooth/abs-volume
        // outputs that drop a single AVRCP command. `restoreTarget` lets a fresh duck recover
        // the true original; the task is cancelled by the next duck so it never fights a new
        // snapshot.
        restoreTarget = target
        restoreReassertTask?.cancel()
        restoreReassertTask = Task(priority: .high) { [weak self] in
            // ~6 s window: long enough to outlast the OS's post-mic-session volume dip.
            for tick in 0 ..< 24 {
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25 s
                if Task.isCancelled { return }
                let reads = Self.volume(of: device) ?? target
                // Only correct DROPS (external theft / AVRCP loss). A read above target
                // means the user raised it — leave that alone.
                if reads < target - Self.restoreTolerance {
                    Self.setVolume(target, of: device)
                    self?.log.error(
                        "watchdog: output dropped to \(reads, format: .fixed(precision: 2)) after restore; re-asserted \(target, format: .fixed(precision: 2)) (tick \(tick))"
                    )
                }
            }
            self?.restoreTarget = nil
        }
        if retries > 0 {
            log.error("restore: read-back retried \(retries)× (device rejected the first write)")
        }
        // `.error` level so it persists in the log store for diagnosis. Also flags a
        // default-output change during capture (which would explain a device that
        // "stays low" — we duck one device and the user now hears another).
        let currentDefault = Self.defaultOutputDeviceID()
        if let currentDefault, currentDefault != snap.deviceID {
            log.error(
                "restore: output device changed during capture (ducked \(snap.deviceID), now \(currentDefault)); restored the ducked device to \(snap.originalVolume, format: .fixed(precision: 2)), reads \(after, format: .fixed(precision: 2))"
            )
        } else {
            log.error(
                "restore: device \(snap.deviceID) → \(snap.originalVolume, format: .fixed(precision: 2)), reads \(after, format: .fixed(precision: 2))"
            )
        }
    }

    // MARK: - Fade

    /// Ramp the given device's volume from → to over ~150 ms so the change
    /// feels smooth rather than a jarring step. Cancels any in-flight fade
    /// first so a quick stop-after-start can't leave the two ramps fighting.
    private func fade(deviceID: AudioDeviceID, from: Float, to: Float) {
        fadeTask?.cancel()
        fadeTarget = to
        fadeTask = Task { [weak self] in
            let steps = 12
            let stepNanos: UInt64 = 12_000_000 // ~0.144 s total
            for i in 1 ... steps {
                if Task.isCancelled { return }
                let t = Float(i) / Float(steps)
                self?.write(from + (to - from) * t, to: deviceID)
                try? await Task.sleep(nanoseconds: stepNanos)
            }
            if Task.isCancelled { return }
            self?.write(to, to: deviceID)
            self?.fadeTarget = nil
        }
    }

    /// Set the device volume and remember what we wrote, so `restore()` can tell
    /// our own value apart from a user slider change (see `shouldRestore`).
    private func write(_ volume: Float, to deviceID: AudioDeviceID) {
        lastWritten = volume
        Self.setVolume(volume, of: deviceID)
    }

    // MARK: - CoreAudio

    /// Human-readable device name for logs (e.g. "MacBook Pro Speakers", "JBL PartyBox").
    /// Returns "?" if the device is gone or unnamed.
    /// The device's stable UID (survives reboots), for verifying a persisted ephemeral id. (AUDIO-22)
    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return "?" }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = name?.takeRetainedValue() else { return "?" }
        return cf as String
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != 0 else { return nil }
        return id
    }

    /// Current output volume (0…1). Reads from an element we can also **set**, so a
    /// duck (write) and the later restore-check (read) refer to the *same* control.
    /// Some devices expose a readable-but-fixed **main** element alongside settable
    /// per-channel gain; reading `main` there would never reflect our channel writes,
    /// making `restore()` wrongly think "the user changed it" and skip putting the
    /// volume back (music stays quiet after a recording). Prefer settable elements in
    /// the same order `setVolume` writes them; only fall back to a read-only element
    /// when nothing is settable (a device with no software volume, which we skip anyway).
    static func volume(of deviceID: AudioDeviceID) -> Float? {
        let elements = [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
        // First pass: a settable element (what we actually control).
        for element in elements {
            var addr = volumeAddress(element: element)
            guard isSettable(deviceID, &addr) else { continue }
            if let value = readVolume(deviceID, &addr) { return value }
        }
        // Fallback: any readable element (device has no software volume → not ducked).
        for element in elements {
            var addr = volumeAddress(element: element)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            if let value = readVolume(deviceID, &addr) { return value }
        }
        return nil
    }

    private static func readVolume(_ deviceID: AudioDeviceID, _ addr: inout AudioObjectPropertyAddress) -> Float? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return clamp(value)
    }

    /// Set the output volume (0…1). Prefers the main element; falls back to
    /// writing each channel when the device only exposes per-channel gain.
    @discardableResult
    static func setVolume(_ value: Float, of deviceID: AudioDeviceID) -> Bool {
        var v = Float32(clamp(value))
        var mainAddr = volumeAddress(element: kAudioObjectPropertyElementMain)
        if isSettable(deviceID, &mainAddr),
           AudioObjectSetPropertyData(deviceID, &mainAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        {
            return true
        }
        var didSet = false
        for ch in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var chAddr = volumeAddress(element: ch)
            guard isSettable(deviceID, &chAddr) else { continue }
            var channelValue = v
            if AudioObjectSetPropertyData(
                deviceID,
                &chAddr,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &channelValue
            ) ==
                noErr
            {
                didSet = true
            }
        }
        return didSet
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    private static func isSettable(_ id: AudioDeviceID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func clamp(_ v: Float) -> Float {
        min(max(v, 0), 1)
    }
}
