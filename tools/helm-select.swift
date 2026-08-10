// Bring a pane forward — issue #284.
//
//   swift helm-select.swift <pane-uuid>
//
// The other half of `helm-close.swift`, and it needs exactly what that needs: nothing. No
// display, no focused window, no Accessibility grant, no keystrokes — a file appears in the
// spool, helm acts, helm writes a file back. It works with the screen locked, headless and over
// ssh.
//
// **What it is for.** `push.sh` offers an artifact rather than inserting it (#125), so on a busy
// bench it arrives as a background tab nobody can see. This makes it the pane its slot is
// showing, which is what *visible* means — so a re-pushed artifact (#272) is something the agent
// that pushed it can actually confirm reached the operator's screen.
//
// The uuid names a PANE, and a pane holds a terminal or a canvas — one uuid namespace, the same
// value `helm-close` takes. Three ways to know one: a spawn or command result's `terminalId`, the
// `HELM_PANE` of the pane you are running in, or — for an artifact you pushed, since `push.sh`
// hands back no id — the `id` of the `"kind": "canvas"` record in `~/.helm/bench/snapshot.json`.
//
// helm REFUSES a pane in the slot the operator is working in, and there is NO override — not for
// the pane they are typing in, and not for a tab hidden behind it, because the focused slot's
// selection IS the focused pane and showing one of its tabs takes the keyboard. `helm-close` has
// no override for that either; where their eyes are is not something a file on disk gets a say
// in.
//
// A nonzero exit is the point: each refusal has its own code, and stderr says what happened.

import Foundation

enum Exit: Int32 {
    case ok = 0
    case usage = 1
    /// helm never answered. Either it is not running, its spool is elsewhere, or
    /// `HELM_SPOOL_OFF` is set in the helm that is running.
    case noAnswer = 2
    /// helm read the request and said no: no such pane, or the pane is in the operator's own
    /// slot. `reason` says which.
    case refused = 3
    /// helm accepted it and could not carry it out. That is a helm defect, not a caller one.
    case failed = 4
    case abandoned = 6
}

func die(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data("helm-select: \(message)\n".utf8))
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

let usage = """
    usage: helm-select.swift <pane-uuid>
                             [--id NAME] [--spool DIR] [--timeout SECONDS]

    Asks the running helm to show a pane — a terminal or a canvas — by making it the one its
    slot displays. The keyboard does not move, and the result reports both readings of it so
    you can check that rather than take our word for it. No display, no keystrokes.

    The uuid is a spawn or command result's `terminalId`, the `HELM_PANE` of the pane you are
    in, or a pane's `id` in ~/.helm/bench/snapshot.json.

    helm refuses a pane in the slot the operator is working in, and nothing overrides that.

    Exits 2 no answer, 3 refused (read `reason`), 4 helm could not act.
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var pane: String?
var id = "select-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 4096...65535))"
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
    case "--help", "-h":
        print(usage)
        exit(Exit.ok.rawValue)
    default:
        guard !flag.hasPrefix("-") else { die("unknown flag \(flag)", .usage) }
        guard pane == nil else { die("one pane at a time, got \(flag) as well", .usage) }
        pane = flag
    }
}

guard let pane, !pane.isEmpty else { die(usage, .usage) }
// Caught here as well as in helm, because an empty `$HELM_PANE` expands to nothing and the
// round trip to a refusal file is a slow way to be told you passed an empty string.
// **This list is a hand-copy of `CloseRequest.waysToKnowAPane`, and it is checked rather than
// shared** — a script cannot `import HelmWire`, which is the same carve-out the JSON below gets.
// `SpoolWireConformanceTests.testHelmSelectNamesEveryRouteToAPaneUuidThatHelmWireDoes` runs this
// refusal and requires every route `HelmWire` names to appear here too.
guard UUID(uuidString: pane) != nil else {
    die(
        "\"\(pane)\" is not a pane id — it is a spawn or command result's `terminalId`, the "
            + "`HELM_PANE` of the pane you are running in, or a pane's `id` in "
            + "~/.helm/bench/snapshot.json", .usage)
}

let root = spoolRoot(spoolOverride)
guard FileManager.default.fileExists(atPath: root.path) else {
    die(
        "no spool at \(root.path) — helm creates it at launch, so either helm is not running "
            + "or it is watching a different one (HELM_SPOOL_DIR / HELM_DEFAULTS_SUITE).",
        .noAnswer)
}

// **The wire key is `pane`, where a close spells the same value `terminal`.** That is deliberate
// and argued in `SelectRequest`: `terminal` is a name `helm-close` keeps faith with because every
// helm since #176 decodes it, and this request has no such history to keep.
let payload: [String: Any] = ["id": id, "kind": "select", "pane": pane]

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

// One write, not two: helm selects synchronously, so there is no `started` state to pass through
// and nothing to keep waiting for after the first answer.
let resultURL = root.appendingPathComponent("results/\(id).json")
let deadline = Date().addingTimeInterval(timeout)

while Date() < deadline {
    if let data = try? Data(contentsOf: resultURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let status = json["status"] as? String
    {
        print(String(data: data, encoding: .utf8) ?? "{}")
        switch status {
        case "selected":
            let report = json["select"] as? [String: Any] ?? [:]
            // The focus rule, reported rather than assumed: helm read `focusedPane` on both
            // sides of the mutation, and these are those two readings. Read by name, which is
            // what makes this a real check of two fields rather than one — see
            // `helm-command.swift`, where the same canary is tested for the same reason.
            let before = report["focusedPaneBefore"] as? String
            let after = report["focusedPaneAfter"] as? String
            let moved =
                before == after
                ? ""
                : " — WARNING: focus MOVED, \(before ?? "none") → \(after ?? "none")"
            FileHandle.standardError.write(
                Data("helm-select: pane \(pane) is visible\(moved)\n".utf8))
            exit(Exit.ok.rawValue)
        case "refused": die(json["reason"] as? String ?? "refused", .refused)
        case "failed": die(json["reason"] as? String ?? "failed", .failed)
        case "abandoned": die(json["reason"] as? String ?? "abandoned", .abandoned)
        default: die("unexpected status \(status) for a select", .failed)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}

die(
    "no result at \(resultURL.path) within \(Int(timeout))s — is helm running, and is "
        + "HELM_SPOOL_OFF unset in it?", .noAnswer)
