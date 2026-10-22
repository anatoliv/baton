// Read and drive a probe's windows through the Accessibility API, by process id.
//
//   probe-ax texts <pid>            every static text, heading and button label, one per line
//   probe-ax press <pid> <label>    press the first button or segment whose title or description is <label>
//   probe-ax show  <pid> <label>    scroll the first element labelled <label> into view
//   probe-ax scroll <pid> <0...1>   set the largest window's first vertical scroll bar
//   probe-ax scroll-to <pid> <label> <0...1>  set the scroll bar of the scroll area holding <label>
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
//   probe-ax frame <pid> <label>       the centre of the text or button <label>, "x,y" in screen points
//   probe-ax title <pid> <identifier>  the title of the button with that identifier
//   probe-ax pick <pid> <identifier> <item>  open the menu button with that identifier, choose <item>
//   probe-ax guard <pid> [x,y]         exit 0 only if the probe is frontmost (and x,y is in its window)
//   probe-ax selected <pid>            identifiers of the selected elements (the lit read-along sentence)
//   probe-ax menuitems <pid> <text>    the context menu items of the element showing <text>, then Escape
//   probe-ax menu <pid> <text> <item>  open the context menu of the element showing <text> and
//                                      choose <item> from it
//
// AppleScript's `entire contents` of a Settings window holding a long grouped Form ran for
// minutes and then timed out with nothing, while the same walk through AXUIElement takes well
// under a second. Compiled on demand by scripts/probe-local-models.sh.
import AppKit
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

/// A static text showing exactly `text`, or a button whose label starts with it: SwiftUI merges
/// a plain button's label into one title ("Probe Machine, 3 chapters · 1 m, On this Mac"), so a
/// book row in the Mac's list has no static text of its own.
func showsText(_ element: AXUIElement, _ text: String) -> Bool {
    let role = string(element, kAXRoleAttribute)
    if role == kAXStaticTextRole { return string(element, kAXValueAttribute) == text }
    if role == kAXButtonRole { return labels(element).contains { $0 == text || $0.hasPrefix(text + ",") } }
    return false
}

/// Whether a synthetic click or key press may go ahead (after another lane's clicks
/// landed in the owner's app): the probe's own process must be the frontmost app, and a point,
/// when given, must lie inside one of its on-screen windows. Prints why when it refuses.
func safeToDrive(_ pid: pid_t, at point: CGPoint?) -> Bool {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard front == pid else {
        FileHandle.standardError.write(Data("refused: the frontmost app is pid \(front.map(String.init) ?? "none"), not the probe \(pid)\n".utf8))
        return false
    }
    guard let point else { return true }
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    // The topmost on-screen window at the point must be the probe's.
    for entry in info where (entry[kCGWindowLayer as String] as? Int) == 0 {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue, let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let w = (bounds["Width"] as? NSNumber)?.doubleValue, let h = (bounds["Height"] as? NSNumber)?.doubleValue,
              CGRect(x: x, y: y, width: w, height: h).contains(point) else { continue }
        if (entry[kCGWindowOwnerPID as String] as? Int) == Int(pid) { return true }
        FileHandle.standardError.write(Data("refused: the window at \(Int(point.x)),\(Int(point.y)) belongs to pid \(entry[kCGWindowOwnerPID as String] ?? "?"), not the probe\n".utf8))
        return false
    }
    FileHandle.standardError.write(Data("refused: no window at \(Int(point.x)),\(Int(point.y))\n".utf8))
    return false
}

/// A real right-click at the centre of `element`, for a SwiftUI row whose context menu has no
/// AXShowMenu action. The probe must be in front.
func rightClick(_ element: AXUIElement, pid: pid_t) -> Bool {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return false }
    var origin = CGPoint.zero, size = CGSize.zero
    // swiftlint:disable force_cast
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    // swiftlint:enable force_cast
    let point = CGPoint(x: origin.x + min(size.width / 2, 120), y: origin.y + size.height / 2)
    guard safeToDrive(pid, at: point) else { return false }
    let click = Process()
    click.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cliclick")
    click.arguments = ["rc:\(Int(point.x)),\(Int(point.y))"]
    guard (try? click.run()) != nil else { return false }
    click.waitUntilExit()
    return click.terminationStatus == 0
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
            // A SwiftUI header (`.isHeader`) is a heading, not static text.
            if role == "AXHeading", let title = labels(element).first(where: { !$0.isEmpty }) { print("[heading] \(title)") }
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
            // A segmented picker's segments are radio buttons.
            let role = string(element, kAXRoleAttribute)
            guard role == kAXButtonRole || role == kAXRadioButtonRole, labels(element).contains(label) else { return false }
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
case "scroll-to":
    // probe-ax scroll-to <pid> <label> <0...1>: set the vertical scroll bar of the scroll area
    // that holds the element labelled <label> (a sheet's list, not the window's first one).
    guard args.count >= 5, let fraction = Double(args[4]) else { exit(64) }
    let label = args[3]
    var done = false
    for window in windows where !done {
        done = walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXScrollAreaRole,
                  let bar = attribute(element, kAXVerticalScrollBarAttribute),
                  walk(element, { labels($0).contains(label) }) else { return false }
            // swiftlint:disable:next force_cast
            return AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString,
                                                NSNumber(value: fraction)) == .success
        }
    }
    print(done ? "done" : "no scroll area holds \(label)")
    exit(done ? 0 : 1)
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
case "menu":
    // The element showing <text>, or the nearest ancestor that offers a context menu, opens it
    // (AXShowMenu); the item is then pressed wherever the menu appeared.
    guard args.count >= 5 else { exit(64) }
    var target: AXUIElement?
    for window in windows where target == nil {
        _ = walk(window) { element in
            guard showsText(element, args[3]) else { return false }
            target = element
            return true
        }
    }
    // A row that is one button (its label read as one line: "<title>, <author>, …") offers its
    // menu on the button itself.
    for window in windows where target == nil {
        _ = walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXButtonRole,
                  labels(element).contains(where: { $0 == args[3] || $0.hasPrefix(args[3] + ", ") }) else { return false }
            target = element
            return true
        }
    }
    guard var element = target else { print("not found: \(args[3])"); exit(1) }
    let shown = element
    var opened = false
    for _ in 0..<8 {
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String], list.contains("AXShowMenu"),
           AXUIElementPerformAction(element, "AXShowMenu" as CFString) == .success {
            opened = true
            break
        }
        guard let parent = attribute(element, kAXParentAttribute) else { break }
        element = parent as! AXUIElement   // swiftlint:disable:this force_cast
    }
    if !opened { opened = rightClick(shown, pid: pid) }
    guard opened else { print("no context menu for: \(args[3])"); exit(1) }
    var pressed = false
    for _ in 0..<20 where !pressed {
        Thread.sleep(forTimeInterval: 0.1)
        // Not the menu bar: "Play" is a menu bar command too, and that one is not the row's.
        let roots = (attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .filter { string($0, kAXRoleAttribute) != kAXMenuBarRole }
        for root in roots where !pressed {
            pressed = walk(root) { candidate in
                guard string(candidate, kAXRoleAttribute) == kAXMenuItemRole, string(candidate, kAXTitleAttribute) == args[4] else { return false }
                return AXUIElementPerformAction(candidate, kAXPressAction as CFString) == .success
            }
        }
    }
    print(pressed ? "done" : "no menu item: \(args[4])")
    exit(pressed ? 0 : 1)
case "frame":
    // The centre of the first static text or button showing <label>, in screen points, for a
    // real double-click with cliclick.
    guard args.count >= 4 else { exit(64) }
    var centre: CGPoint?
    for window in windows where centre == nil {
        _ = walk(window) { element in
            let role = string(element, kAXRoleAttribute)
            guard showsText(element, args[3]) || ((role == kAXStaticTextRole || role == kAXButtonRole) && labels(element).contains(args[3])),
                  let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return false }
            var origin = CGPoint.zero, size = CGSize.zero
            // swiftlint:disable force_cast
            AXValueGetValue(p as! AXValue, .cgPoint, &origin)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            // swiftlint:enable force_cast
            centre = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            return true
        }
    }
    guard let centre else { print("not found: \(args[3])"); exit(1) }
    print("\(Int(centre.x)),\(Int(centre.y))")
case "title":
    // The title (or description) of the first button whose identifier is <identifier>, so a
    // check reads one button and not another with the same words (the book's Pause
    // and the transport's Pause).
    guard args.count >= 4 else { exit(64) }
    var found: String?
    for window in windows where found == nil {
        _ = walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXButtonRole, string(element, kAXIdentifierAttribute) == args[3] else { return false }
            found = string(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? string(element, kAXDescriptionAttribute) ?? ""
            return true
        }
    }
    guard let found else { print("not found: \(args[3])"); exit(1) }
    print(found)
case "pick":
    // Press the button (a SwiftUI Menu) whose identifier is <identifier>, then choose <item>
    // from the menu it opens: the open book's More menu.
    guard args.count >= 5 else { exit(64) }
    var button: AXUIElement?
    for window in windows where button == nil {
        _ = walk(window) { element in
            guard string(element, kAXIdentifierAttribute) == args[3] else { return false }
            button = element
            return true
        }
    }
    guard let button else { print("not found: \(args[3])"); exit(1) }
    var names: CFArray?
    AXUIElementCopyActionNames(button, &names)
    let actions = names as? [String] ?? []
    let opened = actions.contains("AXShowMenu")
        ? AXUIElementPerformAction(button, "AXShowMenu" as CFString) == .success
        : AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    guard opened else { print("could not open \(args[3]) (actions: \(actions))"); exit(1) }
    var chosen = false
    for _ in 0..<20 where !chosen {
        Thread.sleep(forTimeInterval: 0.1)
        for root in (attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? []) where !chosen && string(root, kAXRoleAttribute) != kAXMenuBarRole {
            chosen = walk(root) { candidate in
                guard string(candidate, kAXRoleAttribute) == kAXMenuItemRole, string(candidate, kAXTitleAttribute) == args[4] else { return false }
                return AXUIElementPerformAction(candidate, kAXPressAction as CFString) == .success
            }
        }
        if !chosen {   // a SwiftUI Menu's items hang off the button itself
            chosen = walk(button) { candidate in
                guard string(candidate, kAXRoleAttribute) == kAXMenuItemRole, string(candidate, kAXTitleAttribute) == args[4] else { return false }
                return AXUIElementPerformAction(candidate, kAXPressAction as CFString) == .success
            }
        }
    }
    print(chosen ? "done" : "no menu item: \(args[4])")
    exit(chosen ? 0 : 1)
case "guard":
    // probe-ax guard <pid> [x,y]: exit 0 only when the probe is frontmost (and the point is in its
    // window). Every coordinate click and key press in the probe scripts asks this first.
    var point: CGPoint?
    if args.count >= 4 {
        let parts = args[3].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { exit(64) }
        point = CGPoint(x: parts[0], y: parts[1])
    }
    exit(safeToDrive(pid, at: point) ? 0 : 1)
case "selected":
    // Identifiers of the elements marked selected, the lit read-along sentence among them
    // (`readalong-sentence-N` carries `.isSelected`), one per line.
    for window in windows {
        _ = walk(window) { element in
            if (attribute(element, kAXSelectedAttribute) as? Bool) == true, let id = string(element, kAXIdentifierAttribute) {
                print(id)
            }
            return false
        }
    }
case "menuitems":
    // The titles of the context menu of the element showing <text>, one per line (enabled ones
    // plain, disabled ones in brackets), and the menu is closed again with Escape.
    guard args.count >= 4 else { exit(64) }
    var target: AXUIElement?
    for window in windows where target == nil {
        _ = walk(window) { element in
            guard showsText(element, args[3]) else { return false }
            target = element
            return true
        }
    }
    guard var element = target else { print("not found: \(args[3])"); exit(1) }
    let shown = element
    var opened = false
    for _ in 0..<8 {
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String], list.contains("AXShowMenu"),
           AXUIElementPerformAction(element, "AXShowMenu" as CFString) == .success {
            opened = true
            break
        }
        guard let parent = attribute(element, kAXParentAttribute) else { break }
        element = parent as! AXUIElement   // swiftlint:disable:this force_cast
    }
    if !opened { opened = rightClick(shown, pid: pid) }
    guard opened else { print("no context menu for: \(args[3])"); exit(1) }
    var menu: AXUIElement?
    for _ in 0..<20 where menu == nil {   // a right-clicked row's menu can take a moment
        Thread.sleep(forTimeInterval: 0.1)
        for root in (attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? []) where string(root, kAXRoleAttribute) != kAXMenuBarRole {
            _ = walk(root) { candidate in
                guard string(candidate, kAXRoleAttribute) == kAXMenuRole else { return false }
                menu = candidate
                return true
            }
            if menu != nil { break }
        }
    }
    guard let menu else { print("no menu appeared"); exit(1) }
    _ = walk(menu) { item in
        guard string(item, kAXRoleAttribute) == kAXMenuItemRole, let title = string(item, kAXTitleAttribute), !title.isEmpty else { return false }
        let enabled = (attribute(item, kAXEnabledAttribute) as? Bool) ?? true
        print(enabled ? title : "[\(title)]")
        return false
    }
    AXUIElementPerformAction(menu, kAXCancelAction as CFString)
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
