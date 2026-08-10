// Call a pane something — issue #313.
//
//   swift helm-name.swift <pane-uuid> <name> [--rename]
//
// The third request that names a pane, after `helm-close.swift` and `helm-select.swift`, and it
// needs exactly what those need: nothing. No display, no focused window, no Accessibility grant,
// no keystrokes — a file appears in the spool, helm acts, helm writes a file back. It works with
// the screen locked, headless and over ssh.
//
// **What it is for.** Since #93 an agent is handed a *path* rather than a prompt, so Claude Code
// titles its session after the pointer and a spool-spawned tab reads "Read and act on spool prompt
// file". helm already gives such a pane a name of its own — `claude · <tree>` — and this is how
// the agent replaces it with something that says what the pane is actually for.
//
// The uuid names a PANE, and a pane holds a terminal or a canvas — one uuid namespace, the same
// value `helm-close` and `helm-select` take. Three ways to know one: a spawn or command result's
// `terminalId`, the `HELM_PANE` of the pane you are running in, or — for an artifact you pushed,
// since `push.sh` hands back no id — the `id` of the `"kind": "canvas"` record in
// `~/.helm/bench/snapshot.json`.
//
// **Where the name can be read back, said exactly, because the first draft of this text overclaimed
// it.** The `name` block of this script's own result always carries it. `snapshot.json` carries it
// only for a **live terminal** pane, via `terminal.title` — `BenchSnapshot` reaches a name through
// `TerminalSession.displayTitle`, so a pane whose session is gone reports `title: null`, and
// `CanvasRecord` has never had a title field at all. So a canvas you name shows the name on its tab
// and reports it here, and is silent in the snapshot. Giving the snapshot a name field of its own
// is `BenchSnapshot`'s change to make, not this one's.
//
// helm REFUSES a pane somebody has already named, unless you pass `--rename`. A pane nothing has
// named, and a pane wearing only helm's own derived label, need no such thing — that is the whole
// rule, and it is about ownership rather than about the keyboard: naming moves nothing and
// destroys nothing, so unlike `helm-close` and `helm-select` there is no focus refusal here at all.
//
// `--rename` is you saying THE OPERATOR ASKED. helm cannot check that and does not pretend to;
// it is the same kind of claim `helm-close --force` makes, and it defaults to off for the same
// reason. A label they have been reading for an hour is part of how they find their work.
//
// A nonzero exit is the point: each refusal has its own code, and stderr says what happened.

import Foundation

enum Exit: Int32 {
    case ok = 0
    case usage = 1
    /// helm never answered. Either it is not running, its spool is elsewhere, or
    /// `HELM_SPOOL_OFF` is set in the helm that is running.
    case noAnswer = 2
    /// helm read the request and said no: no such pane, a pane somebody already named and no
    /// `--rename`, or a name it will not put on a tab. `reason` says which.
    case refused = 3
    /// helm accepted it and could not carry it out. That is a helm defect, not a caller one.
    case failed = 4
    case abandoned = 6
}

func die(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data("helm-name: \(message)\n".utf8))
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
    usage: helm-name.swift <pane-uuid> <name> [--rename]
                           [--id NAME] [--spool DIR] [--timeout SECONDS]

    Asks the running helm to call a pane — a terminal or a canvas — something. The name goes on
    its tab, and it survives a restart. No display, no keystrokes.

    What reads it back, exactly: the `name` block of THIS result always. A live terminal pane's
    name also reaches its notifications and `terminal.title` in ~/.helm/bench/snapshot.json. A
    CANVAS pane's name does not reach the snapshot at all — read it out of the result here.

    The uuid is a spawn or command result's `terminalId`, the `HELM_PANE` of the pane you are
    in, or a pane's `id` in ~/.helm/bench/snapshot.json.

    helm refuses a pane somebody has already named unless you pass --rename, which is you
    saying the operator asked for the change. A pane nothing has named, and a pane wearing only
    helm's own derived label, need no flag.

    Exits 2 no answer, 3 refused (read `reason`), 4 helm could not act.
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var pane: String?
var name: String?
var rename = false
var id = "name-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 4096...65535))"
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
    case "--rename": rename = true
    case "--id": id = next(flag)
    case "--spool": spoolOverride = next(flag)
    case "--timeout": timeout = Double(next(flag)) ?? timeout
    case "--help", "-h":
        print(usage)
        exit(Exit.ok.rawValue)
    default:
        if pane == nil {
            // A name may legitimately start with `-` once the pane is known — "-- draft --" is a
            // name — so this check lives inside the branch that fills the pane's slot rather than
            // being a `||` a reader has to run De Morgan over.
            guard !flag.hasPrefix("-") else { die("unknown flag \(flag)", .usage) }
            pane = flag
        } else if name == nil {
            name = flag
        } else {
            die("one name at a time — quote it if it has spaces, got \(flag) as well", .usage)
        }
    }
}

guard let pane, !pane.isEmpty else { die(usage, .usage) }
// Caught here as well as in helm, because an empty `$HELM_PANE` expands to nothing and the
// round trip to a refusal file is a slow way to be told you passed an empty string.
// **This list is a hand-copy of `CloseRequest.waysToKnowAPane`, and it is checked rather than
// shared** — a script cannot `import HelmWire`, which is the same carve-out the JSON below gets.
// `SpoolWireConformanceTests.testHelmNameNamesEveryRouteToAPaneUuidThatHelmWireDoes` runs this
// refusal and requires every route `HelmWire` names to appear here too.
guard UUID(uuidString: pane) != nil else {
    die(
        "\"\(pane)\" is not a pane id — it is a spawn or command result's `terminalId`, the "
            + "`HELM_PANE` of the pane you are running in, or a pane's `id` in "
            + "~/.helm/bench/snapshot.json", .usage)
}
// helm judges the name too, and its refusal is the authority — this only catches the case that
// is certainly a mistake at the command line rather than a decision, so that `helm-name <uuid>`
// with the name forgotten prints the usage instead of a refusal file.
guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    die("a name is required — helm-name.swift <pane-uuid> <name>", .usage)
}

let root = spoolRoot(spoolOverride)
guard FileManager.default.fileExists(atPath: root.path) else {
    die(
        "no spool at \(root.path) — helm creates it at launch, so either helm is not running "
            + "or it is watching a different one (HELM_SPOOL_DIR / HELM_DEFAULTS_SUITE).",
        .noAnswer)
}

// **The wire key is `pane`, as `helm-select` spells it** — `SelectRequest.pane` argues why a
// request with no wire history gets the name the value has actually had since a pane could hold a
// canvas, while `helm-close` keeps faith with `terminal`.
let payload: [String: Any] = [
    "id": id, "kind": "name", "pane": pane, "name": name, "rename": rename,
]

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

// One write, not two: helm names synchronously, so there is no `started` state to pass through
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
        case "named":
            let report = json["name"] as? [String: Any] ?? [:]
            // Read by name, and read back off the *result* rather than echoed from what we sent:
            // helm re-read the pane after the mutation, so this is what the tab actually says.
            // The same reason `helm-select` reads its two focus fields by name.
            let applied = report["name"] as? String ?? name
            let was = (report["previousName"] as? String).map { " (was \"\($0)\")" } ?? ""
            FileHandle.standardError.write(
                Data("helm-name: pane \(pane) is now \"\(applied)\"\(was)\n".utf8))
            exit(Exit.ok.rawValue)
        case "refused": die(json["reason"] as? String ?? "refused", .refused)
        case "failed": die(json["reason"] as? String ?? "failed", .failed)
        case "abandoned": die(json["reason"] as? String ?? "abandoned", .abandoned)
        default: die("unexpected status \(status) for a name", .failed)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}

die(
    "no result at \(resultURL.path) within \(Int(timeout))s — is helm running, and is "
        + "HELM_SPOOL_OFF unset in it?", .noAnswer)
