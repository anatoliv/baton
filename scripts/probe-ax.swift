// Read and drive a probe's windows through the Accessibility API, by process id.
//
//   probe-ax texts <pid>            every static text and button label, one per line
//   probe-ax press <pid> <label>    press the first button whose title or description is <label>
//   probe-ax show  <pid> <label>    scroll the first element labelled <label> into view
//   probe-ax scroll <pid> <0...1>   set the largest window's first vertical scroll bar
//   probe-ax windows <pid>          "<window id> <width> <height>" per on-screen window, largest first
//   probe-ax toggle <pid> <label>   press the first checkbox or switch whose title or description is <label>
//   probe-ax value <pid> <label>    print that checkbox's value (1 on, 0 off)
//   probe-ax select <pid> <label>   select the first list or outline row showing the text <label>
//   probe-ax window <pid> <title>   the window id (for `screencapture -l`) of the window titled <title>
//   probe-ax focus <pid> <label>    focus the first text field whose placeholder or label is <label>
//   probe-ax type <pid> <text>      key presses for <text>, one character at a time, posted to <pid>
//   probe-ax clear <pid>            Command-A then Delete, posted to <pid>
//   probe-ax set <pid> <label> <text>  set the value of the first text field whose placeholder or label is <label>
//   probe-ax value-of <pid> <label>    print that text field's value
//
// AppleScript's `entire contents` of a Settings window holding a long grouped Form ran for
// minutes and then timed out with nothing, while the same walk through AXUIElement takes well
// under a second. Compiled on demand by scripts/probe-local-models.sh.
import ApplicationServices
import CoreGraphics
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func walk(_ root: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Bool) -> Bool {
    if visit(root) { return true }
    guard depth < 80, let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] else { return false }
    for child in children where walk(child, depth: depth + 1, visit) { return true }
    return false
}

func labels(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute].compactMap { string(element, $0) }
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else {
    FileHandle.standardError.write(Data("usage: probe-ax texts|press|show <pid> [label]\n".utf8))
    exit(64)
}
let app = AXUIElementCreateApplication(pid)
let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []

switch args[1] {
case "texts":
    for window in windows {
        _ = walk(window) { element in
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole, let value = string(element, kAXValueAttribute) { print(value) }
            if role == kAXButtonRole, let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) {
                print("[button] \(title)")
            }
            return false
        }
    }
case "press":
    guard args.count >= 4 else { exit(64) }
    let label = args[3]
    var done = false
    for window in windows where !done {
        done = walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXButtonRole, labels(element).contains(label) else { return false }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
    }
    print(done ? "done" : "not found: \(label)")
    exit(done ? 0 : 1)
case "show":
    // A grouped Form ignores AXScrollToVisible, so this moves the scroll bar itself until the
    // element sits in the top quarter of the scroll area, re-finding it after every step.
    guard args.count >= 4 else { exit(64) }
    let label = args[3]
    func find(_ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        for window in windows where found == nil {
            _ = walk(window) { element in
                if predicate(element) { found = element; return true }
                return false
            }
        }
        return found
    }
    func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name) else { return nil }
        var p = CGPoint.zero
        // swiftlint:disable:next force_cast
        return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
    }
    func size(_ element: AXUIElement) -> CGSize? {
        guard let value = attribute(element, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        // swiftlint:disable:next force_cast
        return AXValueGetValue(value as! AXValue, .cgSize, &s) ? s : nil
    }
    guard let area = find({ string($0, kAXRoleAttribute) == kAXScrollAreaRole && attribute($0, kAXVerticalScrollBarAttribute) != nil }),
          let barValue = attribute(area, kAXVerticalScrollBarAttribute),
          let top = point(area, kAXPositionAttribute), let height = size(area)?.height else {
        print("no scroll area"); exit(1)
    }
    // swiftlint:disable:next force_cast
    let bar = barValue as! AXUIElement
    var value = 0.0
    while value <= 1.0001 {
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: value))
        usleep(120_000)
        if let element = find({ labels($0).contains(label) }), let y = point(element, kAXPositionAttribute)?.y {
            let offset = y - top.y
            if offset >= 0 && offset <= height * 0.25 { print("done"); exit(0) }
            if offset < 0 { print("done (passed it)"); exit(0) }
        }
        value += 0.02
    }
    print("not found: \(label)")
    exit(1)
case "scroll":
    guard args.count >= 4, let fraction = Double(args[3]) else { exit(64) }
    var done = false
    for window in windows where !done {
        done = walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXScrollAreaRole,
                  let bar = attribute(element, kAXVerticalScrollBarAttribute) else { return false }
            // swiftlint:disable:next force_cast
            return AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString,
                                                NSNumber(value: fraction)) == .success
        }
    }
    print(done ? "done" : "no scroll bar")
    exit(done ? 0 : 1)
case "checkboxes":
    for window in windows {
        _ = walk(window) { element in
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == kAXCheckBoxRole || string(element, kAXSubroleAttribute) == "AXSwitch" {
                print("[\(role)/\(string(element, kAXSubroleAttribute) ?? "")] " + labels(element).joined(separator: " | ")
                      + " parent: " + ((attribute(element, kAXParentAttribute)).map { labels($0 as! AXUIElement).joined(separator: " | ") } ?? ""))
            }
            return false
        }
    }
case "toggle", "value":
    guard args.count >= 4 else { exit(64) }
    let label = args[3]
    var done = false
    for window in windows where !done {
        done = walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXCheckBoxRole, labels(element).contains(label) else { return false }
            if args[1] == "value" {
                print((attribute(element, kAXValueAttribute) as? NSNumber)?.intValue ?? -1)
                return true
            }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
    }
    if args[1] == "toggle" { print(done ? "done" : "not found: \(label)") }
    exit(done ? 0 : 1)
case "focus", "set", "value-of":
    guard args.count >= (args[1] == "set" ? 5 : 4) else { exit(64) }
    let label = args[3]
    var done = false
    for window in windows where !done {
        done = walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXTextFieldRole,
                  labels(element).contains(label) || string(element, kAXPlaceholderValueAttribute) == label else { return false }
            if args[1] == "set" {
                return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, args[4] as CFString) == .success
            }
            if args[1] == "value-of" {
                print(string(element, kAXValueAttribute) ?? "")
                return true
            }
            return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
    }
    if args[1] != "value-of" || !done { print(done ? "done" : "not found: \(label)") }
    exit(done ? 0 : 1)
case "type", "clear":
    // Posted to the process rather than through System Events, which types into whatever app is
    // in front: these reach the probe or nothing.
    func post(_ code: CGKeyCode, _ text: String? = nil, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            if let text { let units = Array(text.utf16); event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
            event.postToPid(pid)
            usleep(40_000)
        }
    }
    if args[1] == "clear" {
        post(0, flags: .maskCommand)   // Command-A
        post(51)                       // Delete
    } else {
        guard args.count >= 4 else { exit(64) }
        for character in args[3] { post(0, String(character)) }
    }
    print("done")
case "select":
    guard args.count >= 4 else { exit(64) }
    let label = args[3]
    var done = false
    for window in windows where !done {
        done = walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXRowRole else { return false }
            let shows = walk(element) { inner in
                string(inner, kAXRoleAttribute) == kAXStaticTextRole && string(inner, kAXValueAttribute) == label
            }
            guard shows else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
        }
    }
    print(done ? "done" : "not found: \(label)")
    exit(done ? 0 : 1)
case "window":
    guard args.count >= 4 else { exit(64) }
    func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
    guard let wanted = windows.first(where: { string($0, kAXTitleAttribute) == args[3] }).flatMap(rect) else {
        print("not found: \(args[3])"); exit(1)
    }
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for entry in info where (entry[kCGWindowOwnerPID as String] as? Int) == Int(pid) {
        guard let id = entry[kCGWindowNumber as String] as? Int, let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue, let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let w = (bounds["Width"] as? NSNumber)?.doubleValue, let h = (bounds["Height"] as? NSNumber)?.doubleValue,
              abs(x - wanted.minX) < 2, abs(y - wanted.minY) < 2, abs(w - wanted.width) < 2, abs(h - wanted.height) < 2 else { continue }
        print(id); exit(0)
    }
    print("not on screen: \(args[3])"); exit(1)
case "windows":
    // Window ids for `screencapture -l`, which captures that window alone: a screen region
    // also captures whatever else happens to be on top of it.
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 }
    let sized = mine.compactMap { entry -> (Int, Int, Int)? in
        guard let id = entry[kCGWindowNumber as String] as? Int,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let w = (bounds["Width"] as? NSNumber)?.intValue, let h = (bounds["Height"] as? NSNumber)?.intValue else { return nil }
        return (id, w, h)
    }
    for (id, w, h) in sized.sorted(by: { $0.1 * $0.2 > $1.1 * $1.2 }) { print("\(id) \(w) \(h)") }
default:
    exit(64)
}
