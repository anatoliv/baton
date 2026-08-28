import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A one-shot keyboard-shortcut recorder for the read-aloud hotkey.
///
/// Click it, press a combination, done. It listens with a **local** event monitor, which only
/// sees keys while Baton is frontmost and needs no permission — recording a shortcut must not
/// itself require the Accessibility grant that the shortcut will later ask for.
///
/// Starts unbound, and can be cleared back to unbound, because that is the shipped state
/// (decision 2 in `specs/read-aloud.md`).
struct ReadAloudHotKeyRecorder: View {

    /// Rebuilt from defaults whenever the binding changes, so the label always reflects what is
    /// actually registered rather than what was last typed.
    @State private var binding = ReadAloudSettings.hotKey
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(label)
                    .font(.body.monospaced())
                    .frame(minWidth: 120)
            }
            .help(isRecording ? "Press the keys you want, or Escape to cancel" : "Click, then press a key combination")

            if binding != nil, !isRecording {
                Button("Clear") { set(nil) }
                    .help("Unbind the shortcut. Services → Speak with Baton keeps working.")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        guard let binding else { return "Not set" }
        return Self.describe(keyCode: binding.keyCode, modifiers: binding.modifiers)
    }

    // MARK: - Recording

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels rather than binding itself — a shortcut of plain Escape would be
            // both useless and hard to undo.
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let carbon = Self.carbonModifiers(event.modifierFlags)
            // A bare key would fire while typing anywhere on the system. Require at least one
            // modifier, and ignore the press rather than binding something unusable.
            guard carbon != 0 else { return nil }
            set((keyCode: UInt32(event.keyCode), modifiers: carbon))
            stopRecording()
            return nil   // swallow it: this keystroke was the binding, not input
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func set(_ newValue: (keyCode: UInt32, modifiers: UInt32)?) {
        ReadAloudSettings.hotKey = newValue
        binding = newValue
        // Re-register immediately, so the shortcut works without relaunching and the old one
        // stops working at the same moment.
        ReadAloudHotKey.shared.apply()
    }

    // MARK: - Translation

    /// AppKit modifier flags → Carbon's, which is what `RegisterEventHotKey` speaks.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// A readable form of a binding: "⌃⌥R". Falls back to the raw key code for keys with no
    /// obvious glyph, which is still more use than showing nothing.
    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out + (keyName(keyCode) ?? "key \(keyCode)")
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        49: "Space", 36: "Return", 48: "Tab",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
    ]

    static func keyName(_ code: UInt32) -> String? { keyNames[code] }
}
