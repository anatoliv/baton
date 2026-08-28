import AppKit
import Carbon.HIToolbox

/// The global hotkey for read-aloud, and the permission conversation that goes with it.
///
/// **The permission split here is easy to get backwards, so it is worth stating.** Registering a
/// Carbon hotkey needs *no* Accessibility grant — `RegisterEventHotKey` is not an event tap.
/// Only *reading another application's selection* does. So the key can be bound and pressed by
/// someone who has granted nothing, and the grant is asked for at the first moment it is
/// actually needed, with a reason attached. (`NSEvent.addGlobalMonitorForEvents` would have
/// required the grant merely to observe the keystroke, which is why it is not used.)
///
/// **Unbound by default** (decision 2 in `specs/read-aloud.md`): nothing is registered
/// system-wide until the user picks a key, so a fresh install cannot collide with a shortcut
/// they already use elsewhere. The Services entry means the feature works before they ever do.
@MainActor
final class ReadAloudHotKey {

    static let shared = ReadAloudHotKey()

    /// Called when the hotkey fires and a selection was successfully read.
    var onSelection: ((String) -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    /// The same key plus Shift, which reads the whole focused element instead of the selection
    /// (tier 2). Registered only when the user's own binding does not already use Shift.
    private var wholeTextHotKeyRef: EventHotKeyRef?
    /// The same key plus Option: capture the focused window and read the pixels (tier 4).
    /// Registered only while the user has switched OCR on.
    private var ocrHotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Distinguishes our hotkey from any other Carbon hotkey in the process.
    private static let signature: OSType = 0x4254_4E52   // 'BTNR'

    private init() {}

    // MARK: - Registration

    /// Register (or re-register) the hotkey from the stored binding. Safe to call repeatedly —
    /// it always tears the old registration down first, so a rebind in Settings takes effect
    /// without leaking the previous key.
    func apply() {
        unregister()
        guard let binding = ReadAloudSettings.hotKey else { return }   // unbound: nothing to do

        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            registerWholeTextVariant(binding)
            registerOCRVariant(binding)
        } else {
            // The likeliest cause by far is that another application already owns this
            // combination. Log rather than alert: the user is not necessarily at the keyboard,
            // and Settings shows the state.
            readAloudLog.error("could not register the read-aloud hotkey (status \(status)) — another app may own it")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let wholeTextHotKeyRef {
            UnregisterEventHotKey(wholeTextHotKeyRef)
            self.wholeTextHotKeyRef = nil
        }
        if let ocrHotKeyRef {
            UnregisterEventHotKey(ocrHotKeyRef)
            self.ocrHotKeyRef = nil
        }
    }

    /// Shift + the chosen shortcut reads the whole focused element rather than the selection.
    ///
    /// Skipped when the binding already contains Shift — there is no "more shift" to add, and
    /// silently registering the same combination twice would give one of the two behaviours at
    /// random. In that case the user simply has the selection shortcut, which is the useful one.
    private func registerWholeTextVariant(_ binding: (keyCode: UInt32, modifiers: UInt32)) {
        guard binding.modifiers & UInt32(shiftKey) == 0 else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 2)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers | UInt32(shiftKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { wholeTextHotKeyRef = ref }
    }

    /// Option + the chosen shortcut reads the pixels. Only while OCR is switched on, and only
    /// when the binding does not already use Option, for the same reason as the Shift variant.
    private func registerOCRVariant(_ binding: (keyCode: UInt32, modifiers: UInt32)) {
        guard ReadAloudSettings.ocrEnabled, binding.modifiers & UInt32(optionKey) == 0 else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 3)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers | UInt32(optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { ocrHotKeyRef = ref }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            // A C callback: it captures nothing and hops to the main actor to do the work.
            var pressed = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard err == noErr, pressed.signature == ReadAloudHotKey.signature else { return noErr }
            let id = pressed.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ReadAloudHotKey.shared.fire(mode: ReadAloudHotKey.Mode(hotKeyID: id))
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    // MARK: - Firing

    /// Read the frontmost app's selection and hand it on — or explain what is missing.
    ///
    /// The "explain" half is an acceptance criterion, not politeness. A hotkey that silently
    /// does nothing when the grant is absent is indistinguishable from a broken feature, and
    /// the user has no way to discover which it is.
    /// Which of the three chords fired.
    enum Mode {
        /// The bare shortcut: whatever is selected.
        case selection
        /// Shift: the whole focused element.
        case wholeText
        /// Option: capture the focused window and read the pixels.
        case ocr

        init(hotKeyID: UInt32) {
            switch hotKeyID {
            case 2: self = .wholeText
            case 3: self = .ocr
            default: self = .selection
            }
        }
    }

    func fire(mode: Mode = .selection) {
        if case .ocr = mode {
            Task { await fireOCR() }
            return
        }
        switch mode == .wholeText ? SelectionReader.readFocusedText() : SelectionReader.readSelection() {
        case let .success(text):
            onSelection?(text)
        case .failure(.notTrusted):
            presentTrustExplanation()
        case .failure(.noSelection):
            // Nothing selected is an ordinary outcome, not an error worth a dialog. The one
            // thing it must not do is speak the previous selection.
            readAloudLog.notice("read-aloud hotkey pressed with nothing to read (mode: \(String(describing: mode)))")
            NSSound.beep()
        }
    }

    private func fireOCR() async {
        switch await ScreenTextOCR.readFocusedWindow() {
        case let .success(text):
            onSelection?(text)
        case .failure(.notPermitted):
            presentScreenRecordingExplanation()
        case let .failure(other):
            readAloudLog.notice("OCR read produced nothing: \(String(describing: other))")
            NSSound.beep()
        }
    }

    /// Shown at most once per launch: repeating a modal every time a hotkey is pressed is its
    /// own kind of broken.
    private var explainedThisLaunch = false
    private var explainedScreenRecordingThisLaunch = false

    private func presentScreenRecordingExplanation() {
        guard !explainedScreenRecordingThisLaunch else { NSSound.beep(); return }
        explainedScreenRecordingThisLaunch = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Baton needs Screen Recording to read a window it cannot get text from"
        alert.informativeText = """
        This shortcut captures the window you are looking at and reads the words out of the \
        picture, which is how it can read a PDF or an image. macOS gates that behind Screen \
        Recording.

        Baton captures only when you press this shortcut, only the window in front, and the \
        picture is never saved.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenTextOCR.requestPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func presentTrustExplanation() {
        guard !explainedThisLaunch else { NSSound.beep(); return }
        explainedThisLaunch = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Baton needs Accessibility access to read your selection"
        alert.informativeText = """
        The keyboard shortcut asks the app you are using for the text you have highlighted, and \
        macOS gates that behind Accessibility.

        You can skip this entirely: select text and choose Services → Speak with Baton, which \
        needs no permission at all.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            SelectionReader.requestTrust()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
