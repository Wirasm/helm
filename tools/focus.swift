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
// actually true — and then asks a SECOND question, because the first one is not enough:
// does the app have a focused window?
//
// An app can be frontmost and still have no key window, and then keystrokes go NOWHERE.
// The way that happens in practice is the operator switching macOS desktop: helm reported
// `AXFrontmost: true` with `AXWindows count: 0` and `AXFocusedWindow: NONE (-25212)`, and a
// full command typed at it vanished. Only the ⌘N before it landed — because a menu command
// is routed to the app rather than to a first responder. That is the tell, and a nasty one:
// the run looks half-successful, so you keep going and type the next thing.
//
// Exit codes. Every one but 0 means: do not send keys.
//   0  frontmost AND has a focused window — safe to type
//   1  no app matches
//   2  usage
//   3  ambiguous — more than one app matches
//   4  never became frontmost
//   5  frontmost but NO focused window (another Space, minimised, no window open)
//   6  cannot verify — no Accessibility grant on this context, so the key window is
//      unaskable. Distinct from 5 deliberately: 5 is a fact, 6 is ignorance.
//
// Which VIEW inside that window holds first responder — which terminal tab, say — is still
// not observable from out here, so a caller that cares should confirm with a capture.
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

guard becameFrontmost(within: deadlineSeconds) else {
    FileHandle.standardError.write(
        Data(
            """
            FAILED to focus \(describe(app)) within \(deadlineSeconds)s.
            Frontmost is still \(describe(frontmost())). Do NOT send keystrokes.

            """.utf8))
    exit(4)
}

/// Whether anything in the app will actually receive a keystroke.
///
/// `noGrant` and `unanswered` are split because collapsing them produces a confident, wrong
/// diagnosis: the first run of this tool told an operator holding a working Accessibility
/// grant that they did not have one, because TextEdit declined to answer. "I could not ask"
/// and "you may not ask" are different problems with different fixes.
enum KeyWindow {
    case present(String)
    case missing
    case noGrant
    case unanswered(AXError)
}

/// The app's focused window, or why there is nothing to report.
///
/// `AXFocusedWindow` is the key window — the one a synthesised keystroke reaches. Asking
/// `AXWindows` instead would be wrong twice over: a window can exist without being key, and
/// on the failure this guards against, that list came back EMPTY anyway.
func keyWindow(of app: NSRunningApplication) -> KeyWindow {
    guard AXIsProcessTrusted() else { return .noGrant }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
        axApp, kAXFocusedWindowAttribute as CFString, &value)
    switch status {
    case .success:
        guard let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .missing }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(
            raw as! AXUIElement, kAXTitleAttribute as CFString, &title)
        let named = (title as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .present(named ?? "<untitled>")
    // The app is answering and simply has no key window. -25212 kAXErrorNoValue is the one
    // seen in practice — Finder, Terminal and zoom with every window closed all return it,
    // and it is what helm returned on the other Space. -25205 kAXErrorAttributeUnsupported
    // is the same answer from an app that does not vend the attribute at all.
    case .noValue, .attributeUnsupported:
        return .missing
    // Everything else is the app not answering its accessibility port — hung, launching, or
    // refusing. Not a fact about its windows, so it is never reported as one. Windowless
    // Safari and TextEdit both return -25204 kAXErrorCannotComplete here, which is why this
    // is a separate answer and not folded into `missing`.
    default:
        return .unanswered(status)
    }
}

/// Focus settles a beat before the window does, so poll — asking once would refuse a run that
/// was about to succeed. Only `missing` is worth waiting on: a grant does not appear by
/// waiting, and an app that will not answer keeps not answering.
func settledKeyWindow(within seconds: Double) -> KeyWindow {
    let start = Date()
    while true {
        let answer = keyWindow(of: app)
        guard case .missing = answer else { return answer }
        guard Date().timeIntervalSince(start) < seconds else { return .missing }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

// Frontmost is necessary and not sufficient — see the header. This is the check that would
// have caught a whole command typed into nothing.
switch settledKeyWindow(within: 2.0) {
case .present(let title):
    print("focused: \(describe(app)) — key window \"\(title)\"")
    exit(0)

case .missing:
    FileHandle.standardError.write(
        Data(
            """
            \(describe(app)) is frontmost but has NO focused window, so a keystroke would go
            nowhere at all. Do NOT send keystrokes.
            Usually this means its window is on another macOS desktop — switch to that desktop
            or move the window here. Otherwise it is minimised, or has no window open.

            """.utf8))
    exit(5)

case .noGrant:
    FileHandle.standardError.write(
        Data(
            """
            \(describe(app)) is frontmost, but this context has no Accessibility grant, so
            whether it has a focused window CANNOT be checked — and an app that is frontmost
            with no key window swallows keystrokes silently. Do NOT send keystrokes.
            Grant it under System Settings → Privacy & Security → Accessibility. It is a
            per-invoking-context TCC grant; no agent can grant it to itself.

            """.utf8))
    exit(6)

case .unanswered(let status):
    FileHandle.standardError.write(
        Data(
            """
            \(describe(app)) is frontmost, but did not answer AXFocusedWindow (AXError
            \(status.rawValue)), so whether a keystroke would land anywhere is unknown.
            Do NOT send keystrokes.
            The Accessibility grant IS present — this is the app not responding, which usually
            means it is hung or still launching. Retry, or check it is alive.

            """.utf8))
    exit(6)
}
