// Capture a window of a running app by owner name → PNG. Usage: swift winshot.swift Helm /tmp/shot.png
// Requires Screen Recording permission for the invoking context (one-time TCC grant).
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: winshot <ownerName> <out.png>\n", stderr); exit(2) }
let owner = args[1], out = args[2]
guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
let win = info.first { ($0[kCGWindowOwnerName as String] as? String) == owner && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 100 }
guard let win, let num = win[kCGWindowNumber as String] as? Int else { fputs("no window for \(owner)\n", stderr); exit(1) }
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l", String(num), out]
try task.run(); task.waitUntilExit()
exit(task.terminationStatus)
