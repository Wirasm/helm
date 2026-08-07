// Close a pane an agent opened — issues #176 and #284.
//
//   swift helm-close.swift <pane-uuid>
//   swift helm-close.swift <pane-uuid> --force     it is running something, and I mean it
//   swift helm-close.swift "$HELM_PANE"            the pane this agent is running in
//
// The inverse of `helm-spool.swift`, and it needs exactly what that needs: nothing. No display,
// no focused window, no Accessibility grant, no keystrokes — a file appears in the spool, helm
// acts, helm writes a file back. It works with the screen locked, headless and over ssh.
//
// The uuid names a PANE, and a pane holds a terminal or a canvas — one uuid namespace, so there
// is nothing extra to say about which (`CloseRequest` argues why the request grew no
// discriminator). Three ways to know one, and knowing it is the scoping: a spawn or command
// result's `terminalId`, the `HELM_PANE` of the pane you are running in, or — for an artifact
// you pushed, since `push.sh` hands back no id — the `id` of the `"kind": "canvas"` record in
// `~/.helm/bench/snapshot.json`. helm does not check that it spawned the pane for you, so an
// agent may tidy up a teammate — but only one it was told about.
//
// helm REFUSES two things, loudly, and they are not the same refusal:
//   - the pane the operator is working in. `--force` does not override this one, and it holds
//     for a canvas exactly as for a terminal. Their eyes are not something a file on disk gets
//     a say in.
//   - a pane with a live process in it, unless you pass `--force`. Closing it kills whatever
//     was running and loses whatever it had not written down. A canvas has no process, so this
//     one never fires for one: the artifact is a file on disk and the operator's annotations
//     are a `.notes.md` sidecar beside it, both of which outlive the tab.
//
// A nonzero exit is the point: each refusal has its own code, and stderr says what happened.

import Foundation

enum Exit: Int32 {
    case ok = 0
    case usage = 1
    /// helm never answered. Either it is not running, its spool is elsewhere, or
    /// `HELM_SPOOL_OFF` is set in the helm that is running.
    case noAnswer = 2
    /// helm read the request and said no: no such pane, the operator is in it, something is
    /// running in it and `--force` was not given. `reason` says which.
    case refused = 3
    /// helm accepted it and could not carry it out. That is a helm defect, not a caller one.
    case failed = 4
    case abandoned = 6
}

func die(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data("helm-close: \(message)\n".utf8))
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
    usage: helm-close.swift <pane-uuid> [--force]
                            [--id NAME] [--spool DIR] [--timeout SECONDS]

    Asks the running helm to close a pane — a terminal or a canvas. The uuid is a spawn or
    command result's `terminalId`, the `HELM_PANE` of the pane you are in, or a pane's `id`
    in ~/.helm/bench/snapshot.json. No display, no keystrokes.

    --force  close it even though something is running in it. A canvas never has anything
             running in it, so it never needs this. Does NOT override helm's refusal to
             close the pane the operator is working in, whichever the pane holds.

    Exits 2 no answer, 3 refused (read `reason`), 4 helm could not act.
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var pane: String?
var force = false
var id = "close-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 4096...65535))"
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
    case "--force", "-f": force = true
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
// `SpoolWireConformanceTests.testHelmCloseNamesEveryRouteToAPaneUuidThatHelmWireDoes` runs this
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

// **The wire key is `terminal`, and it stays that spelling.** It is what every helm built since
// #176 decodes, so renaming it here would make a new script and an older helm — the normal state
// on a machine running two of them — disagree about a request that has not otherwise changed at
// all. The VALUE is a pane id, whichever kind of pane it names (#284); `CloseRequest` in
// `HelmWire` carries the same field under the same name and the same argument.
let payload: [String: Any] = ["id": id, "kind": "close", "terminal": pane, "force": force]

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

// One write, not two: helm closes synchronously, so there is no `started` state to pass
// through and nothing to keep waiting for after the first answer.
let resultURL = root.appendingPathComponent("results/\(id).json")
let deadline = Date().addingTimeInterval(timeout)

while Date() < deadline {
    if let data = try? Data(contentsOf: resultURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let status = json["status"] as? String
    {
        print(String(data: data, encoding: .utf8) ?? "{}")
        switch status {
        case "closed":
            let killed = (json["pid"] as? Int).map { " — pid \($0) went with it" } ?? ""
            FileHandle.standardError.write(
                Data("helm-close: pane \(pane) is gone\(killed)\n".utf8))
            exit(Exit.ok.rawValue)
        case "refused": die(json["reason"] as? String ?? "refused", .refused)
        case "failed": die(json["reason"] as? String ?? "failed", .failed)
        case "abandoned": die(json["reason"] as? String ?? "abandoned", .abandoned)
        default: die("unexpected status \(status) for a close", .failed)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}

die(
    "no result at \(resultURL.path) within \(Int(timeout))s — is helm running, and is "
        + "HELM_SPOOL_OFF unset in it?", .noAnswer)
