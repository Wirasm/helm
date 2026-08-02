// Start a Claude Code session in a NEW helm terminal, with a prompt, and PROVE every step.
//
//   swift helm-spawn.swift <cwd> <prompt…>          — prompt from argv
//   swift helm-spawn.swift <cwd> -                  — prompt from stdin
//   swift helm-spawn.swift <cwd> --prompt-file <p>  — prompt from a file
//   swift helm-spawn.swift <cwd> --dry-run          — preflight only, send nothing
//
// Add `--helm-pid <pid>` when more than one helm is running. Two is the NORMAL state while
// building helm — the operator's, plus a worktree build under test — and they are identical
// by name, so without this the tool refuses exactly when an agent is doing helm work.
//
// This packages the five steps an agent used to do by hand — focus helm, ⌘N, type `cls`,
// sleep and hope, type the prompt, submit — into one command. Doing it by hand worked, and
// it was bad: `osascript … set frontmost` fails SILENTLY, so a ⌘1 meant for helm once landed
// in another editor, and every wait was a `sleep` that hoped the shell had caught up.
//
// So the rule here is VERIFY, NEVER ASSUME. Each step waits on something observable:
//
//   focus        — poll until helm is frontmost AND has a focused window. Frontmost alone is
//                  not enough: an app on another macOS desktop is frontmost with no key
//                  window, and every keystroke sent at it disappears without an error
//   new terminal — poll for a NEW direct child of helm's pid (one `login` per terminal)
//   fresh shell  — that terminal's shell must have NO child, i.e. it is not already
//                  hosting an agent. This is the guard against typing into a live session.
//   agent booted — poll ~/.claude/sessions/ for a new <pid>.json whose pid is a descendant
//                  of THAT terminal and whose cwd is the one asked for
//
// And REFUSE LOUDLY. Locked screen, no Accessibility grant, no helm, more than one helm,
// focus that never lands, a helm with no key window because it sits on another desktop, a
// terminal that never appears, an agent that never registers — all exit nonzero with the
// reason on stderr. Silence is the failure mode being designed out.
//
// The prompt never passes through the keyboard or the shell's word splitting: it is written
// to a private temp file and the typed line reads it back with `"$(cat …)"`. That is what
// makes multi-line prompts, a leading `/`, and shell quoting all non-problems — the three
// things that caused real trouble when this was done by hand.
//
// CEILING, and it is the point of rung 1 (#51): this needs an unlocked screen, a visible helm
// window, and an Accessibility grant on the INVOKING context — the same per-context TCC rule
// as winshot's Screen Recording grant, and one no agent can grant itself. A headless agent
// cannot use this at all. Finding out whether the rest of the ergonomics are right is what
// this rung buys before anything is built into helm.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Refusals

/// One code per reason, so a caller can branch on *why* without parsing prose.
enum Refusal: Int32 {
    case usage = 2
    case screenLocked = 10
    case noAccessibility = 11
    case noHelm = 12
    case manyHelms = 13
    case focusFailed = 14
    case noNewTerminal = 15
    case terminalBusy = 16
    case agentNeverRegistered = 17
    case workspaceUntrusted = 18
    case noKeyWindow = 19
}

func refuse(_ message: String, _ reason: Refusal) -> Never {
    FileHandle.standardError.write(Data(("helm-spawn: " + message + "\n").utf8))
    exit(reason.rawValue)
}

/// Progress, on stderr. The caller is another agent, so stdout stays machine-readable: on
/// success it carries exactly one line, `<pid> <sessionId>`, and nothing else.
func note(_ message: String) {
    FileHandle.standardError.write(Data(("helm-spawn: " + message + "\n").utf8))
}

/// Wait for something to become observable. Returns nil if it never does.
///
/// Every wait in this tool goes through here rather than through `sleep`, because a sleep
/// long enough to be safe is also long enough to hide that the thing never happened.
func poll<T>(upTo seconds: Double, every interval: Double = 0.1, for probe: () -> T?) -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let value = probe() { return value }
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    }
    return probe()
}

// MARK: - Process table

/// A snapshot of every process's parent, taken in one `sysctl` call.
///
/// One call rather than `pgrep -P` per poll: this is read in a loop, and a subprocess per
/// tick would cost more than the thing being measured.
struct ProcessTable {
    private let parentOf: [pid_t: pid_t]

    static func snapshot() -> ProcessTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return .init([:]) }
        // The table can grow between sizing it and reading it, so ask for headroom and
        // trust the length sysctl writes back rather than the one we guessed.
        let slot = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / slot + 32)
        size = buffer.count * slot
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return .init([:]) }
        var parents: [pid_t: pid_t] = [:]
        for entry in buffer.prefix(size / slot) {
            parents[entry.kp_proc.p_pid] = entry.kp_eproc.e_ppid
        }
        return .init(parents)
    }

    private init(_ parentOf: [pid_t: pid_t]) { self.parentOf = parentOf }

    var isEmpty: Bool { parentOf.isEmpty }

    func children(of parent: pid_t) -> Set<pid_t> {
        Set(parentOf.filter { $0.value == parent }.keys)
    }

    func descendants(of root: pid_t) -> Set<pid_t> {
        var found: Set<pid_t> = []
        var frontier = children(of: root)
        while let next = frontier.popFirst() {
            guard found.insert(next).inserted else { continue }
            frontier.formUnion(children(of: next))
        }
        return found
    }
}

// MARK: - Session registry

/// A row in `~/.claude/sessions/` — the registry Claude Code writes at startup and helm
/// already watches. It is the only out-of-process proof that an agent actually booted.
struct SessionRow {
    let pid: pid_t
    let cwd: String
    let sessionId: String

    static let directory = URL(
        fileURLWithPath: NSHomeDirectory()
    ).appendingPathComponent(".claude/sessions")

    static func all() -> [SessionRow] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pid = json["pid"] as? Int, let cwd = json["cwd"] as? String
            else { return nil }
            return SessionRow(
                pid: pid_t(pid), cwd: cwd, sessionId: json["sessionId"] as? String ?? "?")
        }
    }
}

/// Symlinks collapsed, so `/tmp/x` and `/private/tmp/x` compare equal — the registry records
/// the resolved path and the caller may well not.
func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
}

/// Why Claude Code would stop at its workspace-trust dialog in this directory, or nil.
///
/// This is the failure that cost the most to find: everything worked — terminal opened, line
/// typed, `claude` running with the prompt — and no session ever registered, because an
/// interactive Claude Code in an untrusted directory sits on "Is this a project you trust?"
/// before it writes anything. From the outside that is indistinguishable from a slow start,
/// so it has to be ruled out BEFORE any key is sent rather than diagnosed from a timeout.
///
/// The rule, established by probing all three cases in a pty: trust is inherited from an
/// ancestor. A brand-new directory under `/private/tmp` prompts; a brand-new git worktree
/// under a project root that was accepted does not, even though the worktree has no record
/// of its own. So the question is whether ANY ancestor carries `hasTrustDialogAccepted`.
/// That is what makes the real case — spawning into a fresh worktree — work.
///
/// Fails OPEN. If the config cannot be read or parsed, say nothing and let the end-to-end
/// check decide: refusing a spawn that would have worked is the worse error, and the agent
/// still has to register before this tool reports success.
func untrustedWorkspace(_ cwd: String) -> String? {
    let configPath =
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
            $0 + "/.claude.json"
        } ?? NSHomeDirectory() + "/.claude.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let projects = root["projects"] as? [String: Any]
    else { return nil }

    var directory = URL(fileURLWithPath: cwd)
    while true {
        if let record = projects[directory.path] as? [String: Any],
            (record["hasTrustDialogAccepted"] as? NSNumber)?.boolValue == true
        {
            return nil
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    return """
        Claude Code has not been trusted in \(cwd) or any directory above it, so an interactive
        session there stops at its "Is this a project you trust?" dialog before it registers —
        which looks exactly like an agent that never started.

        Nothing was typed. Accept it once by hand, in a terminal:

            cd \(cwd) && claude

        and answer "1. Yes, I trust this folder". Trust is inherited, so accepting it at the
        project root covers every worktree under it. There is no non-interactive way to grant
        this: `claude -p` skips the dialog but records nothing, and this tool will not edit
        ~/.claude.json behind Claude Code's back — several live agents rewrite that file.
        """
}

// MARK: - Keystrokes

let source = CGEventSource(stateID: .combinedSessionState)

func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
    for isDown in [true, false] {
        // Never skip a failed event: dropping the key-up of ⌘N would leave Command stuck down
        // for everything typed afterwards. There is no recovery, so say so and stop.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
        else {
            refuse(
                "the window server refused to create a key event; keystrokes may be half-sent",
                .focusFailed)
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}

/// Type literal text. `keyboardSetUnicodeString` sidesteps the keycode table entirely, so
/// quotes, `$`, `(` and anything else in a path survive without a layout-specific mapping —
/// which is the layer that made `osascript … keystroke` unreliable for this.
func typeText(_ text: String) {
    // The API takes a short string per event; 16 UTF-16 units is comfortably inside it.
    for chunk in Array(Array(text.utf16).chunked(into: 16)) {
        for isDown in [true, false] {
            // Skipping a chunk would type a MANGLED command line and then submit it, which is
            // far worse than not typing at all — so a refused event is a refusal, not a gap.
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
            else {
                refuse(
                    """
                    the window server refused to create a key event partway through typing.
                    A terminal is open in helm with a PARTIAL command line in it — look before
                    retrying, and do not assume it is empty.
                    """, .focusFailed)
            }
            // Explicitly no modifiers: a Command still physically held by the operator would
            // otherwise turn typed text into a string of menu shortcuts.
            event.flags = []
            chunk.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(
                    stringLength: chunk.count, unicodeString: $0.baseAddress)
            }
            event.post(tap: .cghidEventTap)
            usleep(6_000)
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

let keyN: CGKeyCode = 45
let keyReturn: CGKeyCode = 36

// MARK: - Preconditions

/// True while the display is locked or this login session does not own the console.
///
/// Checked before anything is typed and again immediately before typing, because a lock that
/// lands mid-run turns the rest of the sequence into keystrokes sent at a shielded display —
/// no pty spawns behind one, and nothing reports the loss.
func screenIsUnusable() -> String? {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    if session.isEmpty { return "no window server session (running headless?)" }
    // Read through NSNumber rather than `as? Bool`: these arrive as CFBoolean today, but a
    // cast that silently returns nil on a CFNumber would make a LOCKED screen read as
    // "no opinion" — a fail-open on the one check whose whole job is to fail closed.
    func flag(_ key: String) -> Bool? { (session[key] as? NSNumber)?.boolValue }
    // Absent entirely while unlocked; present and true while locked.
    if flag("CGSSessionScreenIsLocked") == true { return "the screen is locked" }
    if flag("kCGSSessionOnConsoleKey") == false {
        return "this login session does not own the console"
    }
    return nil
}

/// The single running helm, or a refusal.
///
/// Selected by pid when one is given, otherwise by name. The pid path exists because two
/// helms is the *normal* state while building helm — the operator's, plus a worktree build
/// under test — and name matching cannot tell them apart, so the safe spawn path used to
/// disappear at exactly the moment an agent was doing helm work.
///
/// The name path needs two filters, and the second is not an optimisation.
/// `runningApplications` is a cached snapshot that intermittently reports a WebKit helper —
/// `helm Web Content`, which appears the moment a canvas opens a WKWebView — as `.regular`.
/// Intersecting with the owners of a real on-screen window breaks that tie with a fact, and
/// without it a lone helm would trip the "more than one" refusal at random. See
/// tools/focus.swift for the same trap.
func theOneHelm(named name: String, pid requested: pid_t?) -> NSRunningApplication {
    let running = NSWorkspace.shared.runningApplications

    func describe(_ app: NSRunningApplication) -> String {
        "\(app.localizedName ?? "?") (pid \(app.processIdentifier))"
    }

    let onScreen =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    // Layer 0 and tall enough to be a real window: popovers and sheets are their own windows
    // (tools/winshot.swift --list shows the extra rows), and a zero-sized or off-screen window
    // cannot receive a keystroke.
    let windowOwners = Set(
        onScreen
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .filter {
                guard let b = $0[kCGWindowBounds as String] as? [String: Any],
                    let height = b["Height"] as? Double, let width = b["Width"] as? Double
                else { return false }
                return height > 100 && width > 100
            }
            .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })

    var matches: [NSRunningApplication]
    if let requested {
        // Looked up across ALL running apps, not just the focusable ones, so that naming a
        // helper process is told apart from naming nothing at all.
        guard let app = running.first(where: { $0.processIdentifier == requested }) else {
            refuse("no running application has pid \(requested)", .noHelm)
        }
        guard app.activationPolicy == .regular else {
            refuse(
                """
                pid \(requested) is \(describe(app)), which can never take focus — its
                activation policy is not `.regular`, so it is a helper process rather than the
                app that owns the window. `swift tools/winshot.swift --list` shows the pid that
                does.
                """, .noHelm)
        }
        matches = [app]
    } else {
        let focusable = running.filter { $0.activationPolicy == .regular }
        let named = focusable.filter {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(name)
        }
        let exact = named.filter {
            ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
        matches = exact.isEmpty ? named : exact
        let windowed = matches.filter { windowOwners.contains($0.processIdentifier) }
        if !windowed.isEmpty { matches = windowed }
    }

    guard let only = matches.first else {
        refuse("no running app named \"\(name)\" with a visible window", .noHelm)
    }
    guard matches.count == 1 else {
        refuse(
            """
            \(matches.count) apps match "\(name)" — \(matches.map(describe).joined(separator: ", ")).
            Refusing rather than guessing which window to type into. A worktree build and the
            operator's own helm are indistinguishable by name, so say which you mean:
            --helm-pid \(matches.map { String($0.processIdentifier) }.joined(separator: " | "))
            """, .manyHelms)
    }
    guard windowOwners.contains(only.processIdentifier) else {
        refuse(
            """
            \(describe(only)) is running but owns no window this Space can see — nothing to
            type into. The likeliest cause is not a missing window but the wrong desktop:
            `.optionOnScreenOnly` excludes other Spaces, so a helm full of live ptys reports
            zero windows the moment the operator switches desktop. Check the desktop it is on
            before concluding its window is gone.
            """, .noHelm)
    }
    return only
}

/// The title of the app's key window, or nil if a keystroke would land nowhere.
///
/// Frontmost is necessary and NOT sufficient, and the gap is not theoretical: helm once sat
/// frontmost with `AXWindows count: 0` and `AXFocusedWindow: NONE (-25212)` while a whole
/// command typed at it vanished. Only the ⌘N landed, because a menu command routes to the app
/// rather than to a first responder — which is exactly what makes this failure so quiet.
/// Anything that is not a definite window is treated as no window: the caller is about to
/// synthesise keystrokes, so ambiguity has to resolve to a refusal. See tools/focus.swift,
/// which exits 5 and 6 on the same distinction.
func keyWindowTitle(of app: NSRunningApplication) -> String? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
            == .success,
        let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return nil }
    var title: CFTypeRef?
    AXUIElementCopyAttributeValue(raw as! AXUIElement, kAXTitleAttribute as CFString, &title)
    return (title as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "<untitled>"
}

func frontmostPid() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

/// Activate and poll until it is genuinely frontmost. `activate` reports only that the request
/// was made, and on current macOS it silently does nothing from a background process — the
/// accessibility path below is the one that actually works.
func focusAndProve(_ app: NSRunningApplication, upTo seconds: Double) -> Bool {
    func isFront() -> Bool { frontmostPid() == app.processIdentifier }
    if isFront() { return true }

    app.activate(options: [])
    if poll(upTo: 1.0, for: { isFront() ? true : nil }) == true { return true }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var windows: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
        let list = windows as? [AXUIElement], let first = list.first
    {
        AXUIElementPerformAction(first, kAXRaiseAction as CFString)
    }
    return poll(upTo: seconds, for: { isFront() ? true : nil }) == true
}

// MARK: - Arguments

let usage = """
    usage: helm-spawn.swift <cwd> <prompt…>
           helm-spawn.swift <cwd> -                   read the prompt from stdin
           helm-spawn.swift <cwd> --prompt-file <path>
           helm-spawn.swift <cwd> --dry-run           preflight only, send nothing

    options: --app <name>      app to drive          (default: helm)
             --helm-pid <pid>  which helm, by pid    (wins over --app)
             --timeout <secs>  wait for the agent    (default: 90)
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var appName = "helm"
var requestedHelmPid: pid_t?
var timeout = 90.0
var promptFile: String?
var dryRun = false
var positional: [String] = []

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    func value(_ flag: String) -> String {
        guard index + 1 < arguments.count else {
            refuse("\(flag) needs a value\n\n\(usage)", .usage)
        }
        index += 1
        return arguments[index]
    }
    switch argument {
    case "--app": appName = value("--app")
    case "--helm-pid":
        let raw = value("--helm-pid")
        guard let pid = pid_t(raw), pid > 0 else { refuse("bad --helm-pid \(raw)", .usage) }
        requestedHelmPid = pid
    case "--prompt-file": promptFile = value("--prompt-file")
    case "--dry-run": dryRun = true
    case "--timeout":
        let raw = value("--timeout")
        guard let seconds = Double(raw), seconds > 0 else { refuse("bad --timeout \(raw)", .usage) }
        timeout = seconds
    case "-h", "--help": print(usage); exit(0)
    default: positional.append(argument)
    }
    index += 1
}

guard let requestedCwd = positional.first else { refuse("missing <cwd>\n\n\(usage)", .usage) }

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: requestedCwd, isDirectory: &isDirectory),
    isDirectory.boolValue
else { refuse("<cwd> is not a directory: \(requestedCwd)", .usage) }
let cwd = resolved(requestedCwd)

/// argv, a file, or stdin. Prompts are long and shell quoting was a real source of trouble,
/// so argv is the convenience and the other two are the ones that always work.
func readPrompt() -> String {
    if let promptFile {
        guard let text = try? String(contentsOfFile: promptFile, encoding: .utf8) else {
            refuse("cannot read --prompt-file \(promptFile)", .usage)
        }
        return text
    }
    let rest = Array(positional.dropFirst())
    if rest == ["-"] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    return rest.joined(separator: " ")
}

let prompt = readPrompt().trimmingCharacters(in: .whitespacesAndNewlines)
guard dryRun || !prompt.isEmpty else {
    refuse("empty prompt — pass it as arguments, with --prompt-file, or on stdin", .usage)
}

// MARK: - Preflight

if let why = screenIsUnusable() {
    refuse(
        """
        \(why). Nothing was typed.
        This route needs an unlocked screen with a visible window — no pty spawns behind a
        shielded display, and keystrokes sent at one go nowhere quietly.
        """, .screenLocked)
}

guard AXIsProcessTrusted() else {
    refuse(
        """
        no Accessibility grant on this context, so synthesised keystrokes would go nowhere.
        It is a per-invoking-context TCC grant and cannot be self-granted: the operator has to
        add this context under System Settings → Privacy & Security → Accessibility.
        """, .noAccessibility)
}

if let why = untrustedWorkspace(cwd) { refuse(why, .workspaceUntrusted) }

let helm = theOneHelm(named: appName, pid: requestedHelmPid)
let helmPid = helm.processIdentifier
note("helm is pid \(helmPid), one visible window, screen unlocked, Accessibility granted")

guard !ProcessTable.snapshot().isEmpty else {
    refuse("could not read the process table; cannot verify a new terminal", .noNewTerminal)
}

if dryRun {
    note("dry run: preflight passed. Focus was NOT attempted and nothing was typed.")
    exit(0)
}

// MARK: - Focus

guard focusAndProve(helm, upTo: 3.0) else {
    refuse(
        """
        FAILED to bring \(appName) (pid \(helmPid)) to the front within 3s.
        Frontmost is pid \(frontmostPid().map(String.init) ?? "<none>"). Nothing was typed —
        a nonzero exit here means no keystrokes were sent anywhere.
        """, .focusFailed)
}
// Frontmost is not enough — see `keyWindowTitle`. This is checked BEFORE ⌘N so that a refusal
// costs nothing. Without it the run fails in the worst possible shape: the menu command lands,
// a terminal opens, the launch line is typed into no first responder at all, and the whole
// thing sits out its 90s timeout before reporting — leaving a stray empty terminal behind.
guard let keyWindow = poll(upTo: 2.0, for: { keyWindowTitle(of: helm) }) else {
    refuse(
        """
        \(appName) (pid \(helmPid)) is frontmost but has no focused window, so a keystroke
        would go nowhere. Nothing was typed.
        Its window is most likely on another macOS desktop — switch to it, or move the window
        to this one. Otherwise it is minimised or has no window open.
        """, .noKeyWindow)
}
note("focused \(appName) (pid \(helmPid)) — frontmost, key window \"\(keyWindow)\"")

// MARK: - New terminal

// The prompt goes to a private file BEFORE ⌘N so that a write failure costs nothing.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("helm-spawn-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(
    at: scratch, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
let promptPath = scratch.appendingPathComponent("prompt.txt")
do {
    try prompt.write(to: promptPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptPath.path)
} catch {
    refuse("could not stage the prompt at \(promptPath.path): \(error)", .usage)
}

// Baselines are taken HERE, not at preflight. "The new terminal" is defined as one that was
// not there a moment ago, so every second between the snapshot and ⌘N is a second in which a
// terminal the operator opened by hand could be mistaken for ours — and then typed into.
// Focus alone can take 3s, so measuring from preflight left a window worth closing.
let baselineTerminals = ProcessTable.snapshot().children(of: helmPid)
let baselineSessionPids = Set(SessionRow.all().map(\.pid))
note("\(baselineTerminals.count) terminal(s) open in helm before spawning")

postKey(keyN, flags: .maskCommand)

guard
    let terminal = poll(
        upTo: 5.0,
        for: {
            ProcessTable.snapshot().children(of: helmPid).subtracting(baselineTerminals).first
        })
else {
    try? FileManager.default.removeItem(at: scratch)
    refuse(
        """
        ⌘N did not open a terminal — no new child of pid \(helmPid) within 5s.
        Only ⌘N was sent; no text was typed.
        """, .noNewTerminal)
}
note("new terminal is pid \(terminal)")

// Its shell must exist, and must be the ONLY thing under it. Every terminal already hosting an
// agent has a `claude` under its zsh, so "no grandchild" is what separates a fresh prompt from
// a live session — and typing into a live session is the failure worth refusing hardest.
guard
    poll(
        upTo: 5.0,
        for: { () -> Bool? in
            let table = ProcessTable.snapshot()
            let shells = table.children(of: terminal)
            guard let shell = shells.first, shells.count == 1 else { return nil }
            return table.children(of: shell).isEmpty ? true : nil
        }) == true
else {
    try? FileManager.default.removeItem(at: scratch)
    refuse(
        """
        terminal \(terminal) never settled into an idle shell within 5s.
        Refusing to type: a shell that is already running something is a live session, and the
        keystrokes would become that agent's prompt. Only ⌘N was sent.
        """, .terminalBusy)
}

// The one guess left. Type-ahead is buffered by the tty line discipline, so this is not a race
// the shell can lose — it is a moment for ghostty to attach the new surface as first responder.
// The end-to-end check below is what actually decides whether it worked.
RunLoop.current.run(until: Date().addingTimeInterval(0.4))

// MARK: - Type

if let why = screenIsUnusable() {
    try? FileManager.default.removeItem(at: scratch)
    refuse("\(why) after the terminal opened. Nothing was typed.", .screenLocked)
}
guard frontmostPid() == helmPid else {
    try? FileManager.default.removeItem(at: scratch)
    refuse(
        """
        \(appName) stopped being frontmost before the prompt was typed (frontmost is now pid
        \(frontmostPid().map(String.init) ?? "<none>")). Refusing to type into another app.
        A terminal was opened in helm and is sitting at an empty prompt.
        """, .focusFailed)
}

/// Single-quote for the shell, the only escaping that has to be right — and the reason the
/// prompt itself is never on the command line.
func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// `cls` is `claude --dangerously-skip-permissions`, and `claude [prompt]` starts an interactive
// session with that prompt already submitted. Handing the prompt over as one argv element is
// what makes a multi-line prompt, or one starting with `/`, ordinary: nothing is typed into the
// TUI, so there is no Return to land early and no slash-command menu to eat it.
let line = "cd \(shellQuoted(cwd)) && cls \"$(cat \(shellQuoted(promptPath.path)))\""
typeText(line)
postKey(keyReturn)
note(
    "typed the launch line into terminal \(terminal); waiting up to \(Int(timeout))s for the agent")

// MARK: - Confirm the agent

let confirmed = poll(
    upTo: timeout, every: 0.25,
    for: { () -> SessionRow? in
        let descendants = ProcessTable.snapshot().descendants(of: terminal)
        return SessionRow.all().first {
            !baselineSessionPids.contains($0.pid) && descendants.contains($0.pid)
                && resolved($0.cwd) == cwd
        }
    })

guard let agent = confirmed else {
    refuse(
        """
        the agent never registered in \(SessionRow.directory.path) within \(Int(timeout))s.

        KEYSTROKES WERE ALREADY SENT — a terminal (pid \(terminal)) was opened in helm and the
        launch line was typed into it, so the world may have been touched. Look at that terminal
        before retrying.

        The prompt is still at \(promptPath.path) (not deleted, so it is not lost).
        Likely causes: `cls` not on the login shell's PATH; the agent stopped at a dialog
        preflight could not predict; or it took longer than \(Int(timeout))s to start —
        retry with --timeout.
        """, .agentNeverRegistered)
}

try? FileManager.default.removeItem(at: scratch)
note("agent running: pid \(agent.pid), session \(agent.sessionId), cwd \(agent.cwd)")
print("\(agent.pid) \(agent.sessionId)")
exit(0)
