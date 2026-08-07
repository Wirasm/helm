// Drive the bench with one of helm's own commands — issue #269.
//
//   swift helm-command.swift splitRight        a new column, focus stays where it is
//   swift helm-command.swift splitDown         a new row under the focused slot
//   swift helm-command.swift newTerminal       a bare login shell in a pane of its own
//   swift helm-command.swift toggleRail        show/hide the Archon rail
//   swift helm-command.swift --list            the commands helm will take from an agent
//
// The fourth sibling of `helm-spool.swift`, `helm-close.swift` and `helm-capture.swift`, and it
// needs exactly what they need: nothing. No display, no focused window, no Accessibility grant,
// no keystrokes — a file appears in the spool, helm acts, helm writes a file back. It works with
// the screen locked, headless and over ssh.
//
// helm has twenty commands and will take four of them from an agent. The rule is one sentence:
// REARRANGING THE BENCH IS FINE, TAKING FOCUS IS NOT. An agent selecting the operator's active tab
// mid-thought is the wrong-terminal click in a supported API — so every command that moves the
// keyboard, or that acts on "the focused pane" without saying which pane it means, is refused with
// the reason and, where one exists, the route to use instead — `helm-close` names a pane and
// refuses the operator's, `push.sh` puts an artifact on the bench without seizing, and a
// `helm-spool` spawn's `cwd` is the workspace helm opens for it.
// `--list` names the four without sending anything; send any other command to read helm's own
// refusal, which says why. `SpoolCommandPolicy` in `Sources/HelmWire/Spool/SpoolRequest.swift`
// argues the whole verdict.
//
// The result says what happened rather than making you re-read `snapshot.json` and race it:
// `command.paneCreated` (also copied to `terminalId`, so `helm-close` is the next move with no
// lookup), `command.focusedPaneBefore`/`After` — equal, which is the focus rule made checkable —
// and the bench's column and pane counts after.
//
// A nonzero exit is the point: each refusal has its own code, and stderr says what happened.

import Foundation

enum Exit: Int32 {
    case ok = 0
    case usage = 1
    /// helm never answered. Either it is not running, its spool is elsewhere, or
    /// `HELM_SPOOL_OFF` is set in the helm that is running.
    case noAnswer = 2
    /// helm read the request and said no: not a command helm has, or not one it will take from
    /// an agent. `reason` says which, and `--list` says so without sending anything.
    case refused = 3
    /// helm accepted it and could not carry it out. That is a helm defect, not a caller one.
    case failed = 4
    case abandoned = 6
}

func die(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data("helm-command: \(message)\n".utf8))
    exit(code.rawValue)
}

/// The same three rules `SpoolDirectory.resolve` follows, because a CLI that guessed at a
/// different directory than helm watches would fail in the one way nobody can see.
func spoolRoot(_ override: String?) -> URL {
    if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    let environment = ProcessInfo.processInfo.environment
    if let raw = environment["HELM_SPOOL_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
    {
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".helm")
    let suite =
        environment["HELM_DEFAULTS_SUITE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !suite.isEmpty, suite != "com.wirasm.helm" {
        return base.appendingPathComponent("spool-\(suite)")
    }
    return base.appendingPathComponent("spool")
}

/// **The one thing this script restates from `HelmWire` beyond the JSON shape, and it is
/// restated on purpose.** `--list` has to answer without a running helm — "may I send this?" is
/// exactly the question an agent asks *before* deciding to send anything — and a single-file
/// script cannot `import HelmWire` (see `AGENTS.md`, "Why the spool is a script, and must stay
/// one"). So the four names live here as well as in `SpoolCommandPolicy.verdict`, and
/// `SpoolWireConformanceTests.testHelmCommandListsExactlyTheCommandsSpoolCommandPolicyAllows`
/// runs this script and compares its output against the real policy — the same way every other
/// duplicate across this boundary is kept honest. Sending an unlisted command still works and
/// still gets helm's own refusal with its own reason; this list only saves a round trip.
let allowed = ["newTerminal", "splitRight", "splitDown", "toggleRail"]

let usage = """
    usage: helm-command.swift <command> [--id NAME] [--spool DIR] [--timeout SECONDS]
           helm-command.swift --list

    Asks the running helm to carry out one of its own commands. No display, no keystrokes.

    Commands helm takes from an agent:
      \(allowed.joined(separator: "  "))

    Everything else is refused with a reason — rearranging the bench is fine, taking the
    operator's keyboard is not. `--list` names the four above without sending anything;
    send any other command to read helm's own refusal, which says why and what to use.

    Exits 2 no answer, 3 refused (read `reason`), 4 helm could not act.
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var command: String?
var id = "command-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 4096...65535))"
var spoolOverride: String?
var timeout: Double = 30

func next(_ flag: String) -> String {
    guard let value = arguments.first else { die("\(flag) needs a value", .usage) }
    arguments.removeFirst()
    return value
}

while let flag = arguments.first {
    arguments.removeFirst()
    switch flag {
    case "--id": id = next(flag)
    case "--spool": spoolOverride = next(flag)
    case "--timeout": timeout = Double(next(flag)) ?? timeout
    case "--list":
        for name in allowed { print(name) }
        exit(Exit.ok.rawValue)
    case "--help", "-h":
        print(usage)
        exit(Exit.ok.rawValue)
    default:
        guard !flag.hasPrefix("-") else { die("unknown flag \(flag)", .usage) }
        guard command == nil else { die("one command at a time, got \(flag) as well", .usage) }
        command = flag
    }
}

guard let command, !command.isEmpty else { die(usage, .usage) }

let root = spoolRoot(spoolOverride)
guard FileManager.default.fileExists(atPath: root.path) else {
    die(
        "no spool at \(root.path) — helm creates it at launch, so either helm is not running "
            + "or it is watching a different one (HELM_SPOOL_DIR / HELM_DEFAULTS_SUITE).",
        .noAnswer)
}

// **Not pre-validated against `allowed` above, deliberately.** helm is the authority on what it
// will take, and its refusal names the reason and the alternative route; a local check would
// answer a stale copy of the policy and hide a helm that had since changed its mind. `--list` is
// the fast path for a caller that wants to ask first.
let payload: [String: Any] = ["id": id, "kind": "command", "command": command]

// **Written under a dot name and renamed into place.** helm skips hidden files, and the rename
// is atomic — so there is no instant at which helm can claim half a request.
let staging = root.appendingPathComponent(".staging-\(id).json")
let destination = root.appendingPathComponent("\(id).json")
do {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try data.write(to: staging, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
    try FileManager.default.moveItem(at: staging, to: destination)
} catch {
    try? FileManager.default.removeItem(at: staging)
    die("could not write the request: \(error)", .failed)
}

// One write, not two: helm applies a command to the bench synchronously, so there is no
// `started` state to pass through and nothing to keep waiting for after the first answer.
let resultURL = root.appendingPathComponent("results/\(id).json")
let deadline = Date().addingTimeInterval(timeout)

while Date() < deadline {
    if let data = try? Data(contentsOf: resultURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let status = json["status"] as? String
    {
        print(String(data: data, encoding: .utf8) ?? "{}")
        switch status {
        case "ran":
            let report = json["command"] as? [String: Any] ?? [:]
            let made = (report["paneCreated"] as? String).map { " — new pane \($0)" } ?? ""
            let bench =
                (report["panes"] as? Int).map { panes in
                    " — \(panes) panes in \((report["columns"] as? Int) ?? 0) columns"
                } ?? ""
            // The focus rule, reported rather than assumed: helm read `focusedPane` on both
            // sides of the mutation, and these are those two readings.
            let before = report["focusedPaneBefore"] as? String
            let after = report["focusedPaneAfter"] as? String
            let moved =
                before == after
                ? ""
                : " — WARNING: focus MOVED, \(before ?? "none") → "
                    + "\(after ?? "none")"
            FileHandle.standardError.write(
                Data("helm-command: \(command) ran\(made)\(bench)\(moved)\n".utf8))
            exit(Exit.ok.rawValue)
        case "refused": die(json["reason"] as? String ?? "refused", .refused)
        case "failed": die(json["reason"] as? String ?? "failed", .failed)
        case "abandoned": die(json["reason"] as? String ?? "abandoned", .abandoned)
        default: die("unexpected status \(status) for a command", .failed)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}

die(
    "no result at \(resultURL.path) within \(Int(timeout))s — is helm running, and is "
        + "HELM_SPOOL_OFF unset in it?", .noAnswer)
