// Inspect or capture the windows of a running app, by owner name.
//
//   swift winshot.swift helm /tmp/shot.png   — capture to PNG, by owner name
//   swift winshot.swift 71347 /tmp/shot.png  — capture to PNG, by pid (exact)
//   swift winshot.swift --list [owner]       — print geometry, no capture
//
// Capture needs a Screen Recording grant on the INVOKING context (one-time TCC prompt).
// It is a per-context grant, not a property of agents as a class: some agent contexts
// have it and some don't, and none can grant it to themselves. Run it and read the exit
// code rather than assuming either way.
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
    fputs("usage: winshot <ownerName|pid> <out.png> | winshot --list [owner]\n", stderr)
    exit(2)
}
let target = args[1]
let out = args[2]
// A bare number is a pid. Owner names stop identifying anything the moment two instances
// run — a worktree build and the operator's own helm both report `helm` — and capturing
// the operator's window instead of your own is worse than capturing nothing, because it
// looks like it worked. Anything else is the same case-insensitive substring match --list
// uses: an app's owner name is not always its bundle name (helm reports `helm`, not
// `Helm`), and an exact match that misses reads as "no window", the answer a crash gives
// too. The height filter skips the small helper windows an app keeps alongside its real one.
func tallEnough(_ w: [String: Any]) -> Bool { (bounds(w)?.h ?? 0) > 100 }
let candidates =
    Int(target).map { pid in
        windows().filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && tallEnough($0) }
    }
    ?? windows().filter {
        ownerName($0).lowercased().contains(target.lowercased()) && tallEnough($0)
    }
if candidates.count > 1 {
    fputs("ambiguous: \(candidates.count) windows match \(target) — pass a pid instead\n", stderr)
    for w in candidates {
        fputs("  pid \(w[kCGWindowOwnerPID as String] as? Int ?? 0)  \(ownerName(w))\n", stderr)
    }
    exit(3)
}
guard let win = candidates.first, let num = win[kCGWindowNumber as String] as? Int else {
    fputs("no window for \(target)\n", stderr)
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
