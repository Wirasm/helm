// Synthesise a mouse click at a screen point, with modifiers, via CGEvent.
//
//   swift click.swift 384 322            — plain click
//   swift click.swift 384 322 command    — ⌘-click (OSC 8 links, etc.)
//   swift click.swift --where helm 344 343  — convert IMAGE pixels from a winshot capture
//                                             of `helm` into screen points, then click
//
// Why not `osascript … click at {x, y}`: System Events' `click` does not carry the
// modifier state set by a separate `key down`, so a ⌘-click arrives as a plain click and
// the link is never followed. It also routes through the accessibility layer, which
// helm's terminal — a Metal-layer NSView with no child elements — does not populate.
// CGEvent posts to the window server directly and takes flags on the event itself.
//
// Needs the same Accessibility grant as focus.swift. A click is a real click: it lands
// wherever it lands, so `--where` exists to avoid hand-converting retina capture pixels
// into screen points and clicking the wrong thing.
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())

/// Window bounds for the first on-screen window whose owner matches, in screen points.
func windowBounds(owner: String) -> (x: Double, y: Double, w: Double, h: Double)? {
    let windows =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    for w in windows {
        let name = w[kCGWindowOwnerName as String] as? String ?? ""
        guard name.localizedCaseInsensitiveContains(owner),
            (w[kCGWindowLayer as String] as? Int) == 0,
            let b = w[kCGWindowBounds as String] as? [String: Any],
            let width = b["Width"] as? Double, let height = b["Height"] as? Double,
            let x = b["X"] as? Double, let y = b["Y"] as? Double
        else { continue }
        return (x, y, width, height)
    }
    return nil
}

var origin = (x: 0.0, y: 0.0)
var scale = 1.0
if args.first == "--where" {
    guard args.count >= 4 else { fail("usage: click.swift --where <app> <imgX> <imgY> [mods…]", 2) }
    let owner = args[1]
    guard let b = windowBounds(owner: owner) else {
        fail("no on-screen window for \"\(owner)\"", 1)
    }
    // winshot captures at backing scale; the capture is that many pixels per point.
    let backing = NSScreen.main?.backingScaleFactor ?? 2.0
    origin = (b.x, b.y)
    scale = 1.0 / backing
    args = Array(args.dropFirst(2))
}

guard args.count >= 2, let rawX = Double(args[0]), let rawY = Double(args[1]) else {
    fail("usage: click.swift [--where <app>] <x> <y> [command|shift|option|control]…", 2)
}

let point = CGPoint(x: origin.x + rawX * scale, y: origin.y + rawY * scale)

var flags: CGEventFlags = []
for name in args.dropFirst(2) {
    switch name.lowercased() {
    case "command", "cmd": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "option", "alt": flags.insert(.maskAlternate)
    case "control", "ctrl": flags.insert(.maskControl)
    default: fail("unknown modifier \"\(name)\"", 2)
    }
}

let source = CGEventSource(stateID: .combinedSessionState)

// Move first. A terminal only treats a link as clickable once it has been hovered — the
// same reason the underline appears on hover — so a click with no preceding motion can
// land on a link the view does not yet consider live.
// The modifiers go on the MOVE too, not just the click. A terminal only marks a link
// live while the modifier is held during hover — that is what draws the underline — so a
// bare move followed by a ⌘-click arrives at a link the view never activated.
if let move = CGEvent(
    mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
    mouseButton: .left)
{
    move.flags = flags
    move.post(tap: .cghidEventTap)
}
usleep(250_000)

for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    guard
        let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
            mouseButton: .left)
    else { fail("could not create \(type == .leftMouseDown ? "down" : "up") event", 3) }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(30_000)
}

print(
    "clicked at (\(Int(point.x)), \(Int(point.y)))\(flags.isEmpty ? "" : " with \(args.dropFirst(2).joined(separator: "+"))")"
)
