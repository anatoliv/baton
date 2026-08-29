#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

/// The output devices Baton can send its own audio to.
///
/// Baton's AirPlay button is an `AVRoutePickerView`, which routes **AVPlayer**. With the
/// engine deck active AVPlayer plays nothing, so the picker reported a route as connected —
/// checkmark, volume slider — while the audio carried on out of the previous device. Worse
/// than a dead control, because a dead control looks dead.
///
/// The replacement routes *per-app*: `AVAudioEngine` can be pointed at a specific CoreAudio
/// device, so choosing a speaker here moves Baton and leaves every other app where it was.
/// Switching the system default (what Control Centre does, and what the engine follows by
/// default) would also work and is what proved AirPlay reachable at all — but a music player
/// reaching out and re-pointing every app's audio from a small button in its transport bar
/// is not a thing to do to someone.
///
/// **AirPlay caveat, stated because it decides how this reads:** an AirPlay destination only
/// exists as a CoreAudio device once macOS has connected it. Until then it is discoverable
/// by AirPlay but invisible here. So this list is honest about what it can offer rather than
/// pretending to be a full AirPlay picker — see `systemDefaultHint`.
public enum AudioOutputDevices {
    public struct Device: Identifiable, Hashable, Sendable {
        public let id: AudioDeviceID
        public let name: String
        /// True for the device the *system* is currently using — shown as a hint, since
        /// leaving Baton on "system default" is the sane resting state.
        public let isSystemDefault: Bool
    }

    /// Every device a person could reasonably choose, in CoreAudio's order.
    public static func outputs() -> [Device] {
        let systemDefault = defaultOutputDeviceID()
        return allDeviceIDs().compactMap { id in
            guard hasOutputStreams(id), !isPrivateAggregate(id), let name = name(of: id)
            else { return nil }
            return Device(id: id, name: name, isSystemDefault: id == systemDefault)
        }
    }

    /// macOS builds hidden aggregate devices for its own routing — `CADefaultDeviceAggregate-…`
    /// and friends — and they are indistinguishable from real hardware in the device list.
    /// One appeared in the picker looking like something you could send music to.
    ///
    /// Filtered by the *private* flag in the aggregate's composition rather than by name,
    /// because people build their own aggregate devices deliberately (multi-output setups)
    /// and those must stay selectable. A name-prefix match would have thrown them out too.
    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        // Not an aggregate at all → the property doesn't exist → ordinary device, keep it.
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return false }
        var composition: CFDictionary? = nil
        var dictSize = UInt32(MemoryLayout<CFDictionary?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dictSize, &composition) == noErr,
              let dictionary = composition as? [String: Any]
        else { return false }
        return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? Int) == 1
    }

    /// The system's current output device id, or 0 when it can't be read.
    public static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    // MARK: - Transport

    /// How audio physically reaches this device — built-in, USB, HDMI, Bluetooth, AirPlay…
    ///
    /// A `UInt32` four-char code (`kAudioDeviceTransportType*`) rather than an enum of our
    /// own, because the list is CoreAudio's to extend and a closed enum would silently
    /// mis-file anything Apple adds later.
    public static func transportType(of id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }

    /// True when audio to this device travels over Bluetooth.
    ///
    /// Worth knowing because a Bluetooth link goes to standby when nothing is playing and
    /// takes a noticeable moment to wake — long enough to swallow the first word of a spoken
    /// summary. Callers use this to pay that cost deliberately (see `SpeechAudioPlayer`)
    /// rather than losing the start of the sentence to it.
    ///
    /// AirPlay has a comparable wake-up and is deliberately *not* included: it also carries a
    /// large steady-state buffer of its own, so it wants a different remedy than this one.
    /// Unreadable transport counts as false — a guess in the other direction would add a
    /// delay to wired output, which is the case that has no problem to fix.
    public static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        guard let transport = transportType(of: id) else { return false }
        return transport == UInt32(kAudioDeviceTransportTypeBluetooth)
            || transport == UInt32(kAudioDeviceTransportTypeBluetoothLE)
    }

    /// A line for the UI when the wanted destination isn't in `outputs()` — an AirPlay
    /// speaker that macOS hasn't connected yet has no CoreAudio device to point at.
    public static let systemDefaultHint =
        "AirPlay speakers appear here once macOS connects them — pick them in Control Centre first."

    // MARK: - Render quantum

    /// How many frames the device hands its clients per render callback.
    ///
    /// This is the wake-up rate of the whole audio pipeline: at 512 frames and 44.1 kHz the
    /// I/O proc runs about 86 times a second for as long as the engine is running, and
    /// wake-up frequency weighs heavily in the energy-impact figure the engine is judged on.
    public static func bufferFrameSize(of id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames) == noErr, frames > 0
        else { return nil }
        return frames
    }

    /// The sizes this device will accept. Not a formality: the built-in output on this
    /// hardware tops out at **1024** frames, so the obvious "just ask for 4096" both fails
    /// and silently forfeits the whole optimisation. Callers clamp to what is on offer.
    public static func bufferFrameSizeRange(of id: AudioDeviceID) -> ClosedRange<UInt32>? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range) == noErr else { return nil }
        let low = UInt32(max(1, range.mMinimum))
        let high = UInt32(max(range.mMinimum, range.mMaximum))
        return low <= high ? low...high : nil
    }

    /// Ask `id` to run at `frames` per callback. Reports whether the device took it.
    ///
    /// **This property belongs to the device, not to our connection to it** — every app on
    /// that output renders at whatever size wins. That is why the caller only ever raises a
    /// device that is running smaller than it wants, never lowers one that another app has
    /// already raised, and puts the original back when it is done. See
    /// `EngineAudioPipeline.adoptRenderQuantum()`.
    @discardableResult
    public static func setBufferFrameSize(_ frames: UInt32, on id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue
        else { return false }
        var value = frames
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, &value) == noErr
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    /// A device is an *output* if it publishes at least one output channel. Microphones and
    /// aggregate inputs otherwise appear in a list of speakers.
    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return false }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name = name as String?, !name.isEmpty
        else { return nil }
        return name
    }
}
#endif
