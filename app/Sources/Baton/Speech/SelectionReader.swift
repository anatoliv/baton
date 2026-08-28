import AppKit
import ApplicationServices

/// Tier 1: reading the frontmost application's selection, for the global hotkey.
///
/// Two routes, in order. **Accessibility first** — ask the focused element for its selected
/// text. **The clipboard second** — synthesize ⌘C, read the pasteboard, put it back.
///
/// Phase 0 measured which route each app actually supports, and the answer decided the shape of
/// this file (see `specs/read-aloud.md`):
///
/// - **Ghostty** vends a complete `AXTextArea`: a real ⌘A selection came back as 79,396
///   characters through `AXSelectedText`. The accessibility route works there outright.
/// - **Chrome** does not. Its focused element is an `AXWebArea` that implements no
///   `AXSelectedText` at all — Blink exposes selection through text-marker APIs instead — and it
///   rejects both documented flags for building a fuller tree.
///
/// So **the clipboard fallback is load-bearing on the single most common source application**,
/// not an edge case tacked on for safety. That is why it saves and restores the pasteboard
/// carefully rather than shrugging, and why Settings offers a switch for people who would rather
/// it never touched their clipboard.
@MainActor
enum SelectionReader {

    enum Failure: Error, Equatable {
        /// The Accessibility grant is missing. The only failure the user can fix, so it is the
        /// only one with a call to action.
        case notTrusted
        /// Everything worked and there was simply nothing selected.
        case noSelection
    }

    /// Read the current selection from whichever application is frontmost.
    static func readSelection() -> Result<String, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }

        if let text = accessibilitySelection(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(text)
        }
        if ReadAloudSettings.allowClipboardFallback,
           let text = clipboardSelection(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(text)
        }
        return .failure(.noSelection)
    }

    /// Tier 2: read the *whole* focused element rather than the selection — "read the page,
    /// not what I highlighted".
    ///
    /// Phase 0 measured exactly how far this reaches, and it is not far:
    /// - **Ghostty** returns its entire scrollback (75,823 characters when measured), which is
    ///   genuinely useful and needs no selection at all.
    /// - **Chrome** returns nothing. Its focused `AXWebArea` carries no value, its subtree is
    ///   not populated, and it rejects both `AXManualAccessibility` (−25205) and
    ///   `AXEnhancedUserInterface` (−25208). There is no plain-AX path to a page's text.
    ///
    /// So this is honestly a terminal and native-text-view feature. It reports `noSelection`
    /// where there is nothing to read, and the caller says so rather than pretending.
    static func readFocusedText() -> Result<String, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        guard let text = focusedValue(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .failure(.noSelection) }
        return .success(text)
    }

    private static func focusedValue() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
        else { return nil }
        return valueRef as? String
    }

    /// Prompt for the Accessibility grant, opening System Settings to the right pane.
    ///
    /// Deliberately explicit rather than a silent `AXIsProcessTrustedWithOptions` prompt at
    /// launch: the grant is only needed for the hotkey, and the Services entry works without it,
    /// so asking before there is a reason is asking for a refusal.
    static func requestTrust() {
        // The literal rather than `kAXTrustedCheckOptionPrompt`: that constant is imported as a
        // global `var`, which Swift 6 rejects as shared mutable state. The key's value is
        // stable API.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Accessibility

    private static func accessibilitySelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueRef) == .success
        else { return nil }
        return valueRef as? String
    }

    // MARK: - Clipboard fallback

    /// How long to wait for the copy to land. A synthetic ⌘C is asynchronous — the target app
    /// handles the key on its own run loop — so the pasteboard is polled rather than read once.
    private static let copyTimeout: TimeInterval = 0.35

    /// Synthesize ⌘C, take what lands, and put the previous contents back.
    ///
    /// The restore is **best-effort and racy by nature**: a clipboard manager watching the
    /// pasteboard can observe the intermediate value, and nothing in AppKit can prevent that.
    /// Said plainly here, and in Help, rather than pretended away.
    private static func clipboardSelection() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        pressCommandC()

        var copied: String?
        let deadline = Date().addingTimeInterval(copyTimeout)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        restore(saved, to: pasteboard)
        return copied
    }

    /// Every item on the pasteboard, with every type it carries — not just the string. Saving
    /// only the string would silently destroy a copied image or file reference, which is a much
    /// worse outcome than failing to read a selection.
    static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func pressCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let c: CGKeyCode = 0x08   // kVK_ANSI_C
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
