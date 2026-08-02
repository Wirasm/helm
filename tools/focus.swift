// Bring a running app to the front and PROVE it, by owner name or pid.
//
//   swift focus.swift helm     — activate the app named helm, verify, exit 0
//   swift focus.swift 8778     — same, by pid (exact)
//   swift focus.swift --who    — print the frontmost app and exit
//
// Why this exists rather than `osascript … set frontmost`: that path fails SILENTLY.
// It returns no error when it does not work, so a script that activates and then
// synthesises keystrokes will type into whatever app was already frontmost — which is
// how a ⌘1 meant for helm landed in another editor. Anything driving a UI must verify
// focus rather than assume it, because the failure is invisible and the keystrokes are
// not: they go somewhere, and that somewhere may be a live agent session.
//
// So this activates via NSRunningApplication and then POLLS `isActive` until it is
// actually true, exiting nonzero if it never becomes true. A nonzero exit means: do not
// send keys.
//
// Note this only settles which APP has focus. Which view inside it holds first responder
// — which terminal tab, say — is not observable from out here, so a caller that cares
// should still confirm with a capture before typing.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let deadlineSeconds = 3.0

func frontmost() -> NSRunningApplication? {
    NSWorkspace.shared.frontmostApplication
}

func describe(_ app: NSRunningApplication?) -> String {
    guard let app else { return "<none>" }
    return "\(app.localizedName ?? "?") (pid \(app.processIdentifier))"
}

let args = Array(CommandLine.arguments.dropFirst())
guard let target = args.first else {
    FileHandle.standardError.write(Data("usage: focus.swift <app-name|pid|--who>\n".utf8))
    exit(2)
}

if target == "--who" {
    print(describe(frontmost()))
    exit(0)
}

let running = NSWorkspace.shared.runningApplications
var matches: [NSRunningApplication]
if let pid = Int32(target) {
    matches = running.filter { $0.processIdentifier == pid }
} else {
    // Only apps that can actually BE frontmost. Without this, "helm" matches its own
    // WebKit helpers — `helm Networking`, `helm Web Content`, `AutoFill (helm)` — which
    // appear the moment a canvas opens a WKWebView. They can never take focus, so
    // including them would turn an ordinary state into a refusal.
    let focusable = running.filter { $0.activationPolicy == .regular }
    let named = focusable.filter {
        ($0.localizedName ?? "").localizedCaseInsensitiveContains(target)
    }
    // Prefer an exact name match when there is one: "helm" should mean helm even if
    // something called "helm-something-else" is also running.
    let exact = named.filter {
        ($0.localizedName ?? "").caseInsensitiveCompare(target) == .orderedSame
    }
    matches = exact.isEmpty ? named : exact

    // Then prefer whoever actually owns a window. `runningApplications` is a cached
    // snapshot and intermittently reports a WebKit helper as `.regular`, which made this
    // tool fail with "ambiguous" at random — fine when run by hand, useless in a script.
    // A helper never owns an on-screen layer-0 window, so the window list breaks the tie
    // with a fact rather than a heuristic.
    if matches.count > 1 {
        let onScreen =
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            ?? []
        let owners = Set(
            onScreen
                .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
                .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        let windowed = matches.filter { owners.contains($0.processIdentifier) }
        if !windowed.isEmpty { matches = windowed }
    }
}

guard !matches.isEmpty else {
    FileHandle.standardError.write(Data("no running app matching \"\(target)\"\n".utf8))
    exit(1)
}
guard matches.count == 1 else {
    let names = matches.map { describe($0) }.joined(separator: ", ")
    FileHandle.standardError.write(
        Data("ambiguous: \(matches.count) apps match \"\(target)\" — \(names)\n".utf8))
    exit(3)
}

let app = matches[0]

/// Poll until the target is genuinely frontmost. `activate` returns a Bool, but it
/// reports only that the request was *made*.
func becameFrontmost(within seconds: Double) -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        if let front = frontmost(), front.processIdentifier == app.processIdentifier {
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return false
}

app.activate(options: [])

// Modern macOS will not let an arbitrary process steal focus this way — the call
// succeeds and nothing moves. Fall back to the accessibility API, which does work,
// and which needs the Accessibility grant on the invoking context (same per-context
// TCC rule as winshot's Screen Recording grant: check the exit code, never assume).
if !becameFrontmost(within: 1.0) {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var windows: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
        let list = windows as? [AXUIElement], let first = list.first
    {
        AXUIElementPerformAction(first, kAXRaiseAction as CFString)
    }
}

if becameFrontmost(within: deadlineSeconds) {
    print("focused: \(describe(app))")
    exit(0)
}

FileHandle.standardError.write(
    Data(
        """
        FAILED to focus \(describe(app)) within \(deadlineSeconds)s.
        Frontmost is still \(describe(frontmost())). Do NOT send keystrokes.

        """.utf8))
exit(4)
