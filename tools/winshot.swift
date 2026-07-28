// Inspect or capture the windows of a running app, by owner name.
//
//   swift winshot.swift Helm /tmp/shot.png   — capture to PNG
//   swift winshot.swift --list [owner]       — print geometry, no capture
//
// Capture needs a Screen Recording grant for the INVOKING context (one-time TCC prompt),
// which an unattended agent generally does not have and cannot grant itself.
//
// --list needs no permission at all: CGWindowListCopyWindowInfo returns owner, pid, title,
// layer and bounds to anyone; only reading a window's PIXELS is gated. That is enough to
// tell "launched, with a real window" from "crashed", "zero-sized" or "off-screen" — the
// launch failures no unit test reaches, and the ones that report success loudest. It says
// nothing about what is DRAWN in the window; only a human or a capture can say that.
import CoreGraphics
import Foundation

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
}

func ownerName(_ w: [String: Any]) -> String { w[kCGWindowOwnerName as String] as? String ?? "" }

func bounds(_ w: [String: Any]) -> (w: Double, h: Double, x: Double, y: Double)? {
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
        let width = b["Width"] as? Double, let height = b["Height"] as? Double,
        let x = b["X"] as? Double, let y = b["Y"] as? Double
    else { return nil }
    return (width, height, x, y)
}

let args = CommandLine.arguments

if args.count >= 2, args[1] == "--list" {
    // Substring, case-insensitive: an app's owner name is not always its bundle name, and
    // getting that wrong reads as "no window" — the same answer as a crash.
    let filter = args.count >= 3 ? args[2].lowercased() : ""
    let matches = windows().filter { filter.isEmpty || ownerName($0).lowercased().contains(filter) }
    for w in matches {
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let title = w[kCGWindowName as String] as? String ?? ""
        let size = bounds(w).map { "\(Int($0.w))x\(Int($0.h)) at (\(Int($0.x)),\(Int($0.y)))" }
        print(
            "\(ownerName(w))  pid \(pid)  layer \(layer)  \(size ?? "no bounds")  "
                + "title=\(title.isEmpty ? "<none>" : title)")
    }
    if matches.isEmpty { fputs("no windows\(filter.isEmpty ? "" : " for \(filter)")\n", stderr) }
    exit(matches.isEmpty ? 1 : 0)
}

guard args.count == 3 else {
    fputs("usage: winshot <ownerName> <out.png> | winshot --list [owner]\n", stderr)
    exit(2)
}
let owner = args[1]
let out = args[2]
// Height filter skips the small helper windows an app keeps alongside its real one.
let win = windows().first { ownerName($0) == owner && (bounds($0)?.h ?? 0) > 100 }
guard let win, let num = win[kCGWindowNumber as String] as? Int else {
    fputs("no window for \(owner)\n", stderr)
    exit(1)
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l", String(num), out]
try task.run()
task.waitUntilExit()
// screencapture prints "could not create image from window" and exits nonzero when the
// grant is missing; pass that through rather than reporting a capture that did not happen.
exit(task.terminationStatus)
