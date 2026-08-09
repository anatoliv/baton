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

    /// A line for the UI when the wanted destination isn't in `outputs()` — an AirPlay
    /// speaker that macOS hasn't connected yet has no CoreAudio device to point at.
    public static let systemDefaultHint =
        "AirPlay speakers appear here once macOS connects them — pick them in Control Centre first."

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
