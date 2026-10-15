// Read and drive a probe's windows through the Accessibility API, by process id.
//
//   probe-ax texts <pid>            every static text and button label, one per line
//   probe-ax press <pid> <label>    press the first button whose title or description is <label>
//   probe-ax show  <pid> <label>    scroll the first element labelled <label> into view
//   probe-ax scroll <pid> <0...1>   set the largest window's first vertical scroll bar
//   probe-ax windows <pid>          "<window id> <width> <height>" per on-screen window, largest first
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
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(element, $0) }
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
