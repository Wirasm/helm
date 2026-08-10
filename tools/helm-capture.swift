// Ask helm to draw its own window — issue #174.
//
//   swift helm-capture.swift                         → ~/.helm/spool/captures/<id>.png
//   swift helm-capture.swift --out /tmp/bench.png
//   swift helm-capture.swift --window helm-issue174  → pick one of several helm windows
//
// **This needs no TCC grant of any kind, and that is the whole point.** `winshot.swift` next
// door uses `CGWindowListCreateImage`, which is Screen Recording: a grant that cannot be given
// from code, that keys on the code signature, and that attaches to the *invoking context* — so
// a fresh ad-hoc agent binary fails even on a machine where the operator granted everything
// they can see to grant. helm rendering its own view hierarchy is DRAWING, and TCC does not
// gate it. It also works with the screen locked, over ssh, and from a process with no display,
// because nothing here goes near the window server.
//
// **The result says what the PNG contains, including what it does not.** Read
// `capture.terminalContent`: `included` (every terminal pane's cells are in the image),
// `excluded` (none are — their regions carry a printed marker in the PNG itself), `partial`,
// or `absent` (no terminal in the window). It is computed per capture rather than assumed:
// #174 was scoped expecting `excluded` always, because ghostty's surface is a CAMetalLayer and
// Metal content does not come out of the layer tree — but the wrapper swaps that layer for an
// IOSurface-backed one once compositing starts, and that one DOES draw. Both states are real,
// so the field is the answer and neither assumption is.
//
// A nonzero exit is the point: each refusal has its own code, and stderr says what happened.

import Foundation

enum Exit: Int32 {
    case ok = 0
    case usage = 1
    /// helm never answered. Either it is not running, its spool is elsewhere, or
    /// `HELM_SPOOL_OFF` is set in the helm that is running.
    case noAnswer = 2
    /// The request was refused before anything was drawn — a bad path, an unknown kind.
    case refused = 3
    /// helm accepted it and could not draw: no visible window, an ambiguous one, a write that
    /// failed. `reason` says which.
    case failed = 4
    case abandoned = 6
}

func die(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data("helm-capture: \(message)\n".utf8))
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

var arguments = Array(CommandLine.arguments.dropFirst())
var out: String?
var window: String?
var id = "capture-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 4096...65535))"
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
    case "--out", "-o": out = next(flag)
    case "--window", "-w": window = next(flag)
    case "--id": id = next(flag)
    case "--spool": spoolOverride = next(flag)
    case "--timeout": timeout = Double(next(flag)) ?? timeout
    case "--help", "-h":
        print(
            """
            usage: helm-capture.swift [--out PATH.png] [--window TITLE-SUBSTRING]
                                      [--id NAME] [--spool DIR] [--timeout SECONDS]

            Asks the running helm to draw its own window. No TCC grant, no display, no
            keystrokes. Prints the result JSON; `capture.terminalContent` says whether
            terminal cells are in the PNG — included / excluded / partial / absent.
            Exits 2 no answer, 3 refused, 4 could not draw.
            """)
        exit(Exit.ok.rawValue)
    default: die("unknown flag \(flag)", .usage)
    }
}

// **The id names three files — `<id>.json`, `.staging-<id>.json` and `results/<id>.json` — so it
// is gated as the filename it is, here as well as in helm (#260).** helm's own gate is the
// authority and refuses the same strings; this one exists because that refusal cannot be *read*
// from here. A `..` in an id writes the request outside the spool, where no helm is watching, so
// the caller either burns the whole timeout waiting on a result path that was never going to
// appear, or — under `--no-wait` — exits 0 having landed the file nowhere.
//
// **A hand-copy of `RequestID.pattern`, under the carve-out this script already lives by**: it
// cannot `import HelmWire` (see AGENTS.md, "Why the spool is a script, and must stay one"), the
// same as the JSON below and the spool-root rules above. What makes it honest rather than drift is
// `SpoolWireConformanceTests.testEverySpoolScriptGatesItsIdWithHelmWiresOwnPattern`, which reads
// this literal out of the source and runs the refusal against a real subprocess.
let idPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
guard id.range(of: idPattern, options: .regularExpression) != nil else {
    die(
        "--id \"\(id)\" is not a filename — it must match \(idPattern), because it names the "
            + "request file and the result file helm answers in", .usage)
}

let root = spoolRoot(spoolOverride)
guard FileManager.default.fileExists(atPath: root.path) else {
    die(
        "no spool at \(root.path) — helm creates it at launch, so either helm is not running "
            + "or it is watching a different one (HELM_SPOOL_DIR / HELM_DEFAULTS_SUITE).",
        .noAnswer)
}

var payload: [String: Any] = ["id": id, "kind": "capture"]
if let out {
    // Resolved here rather than in helm, so a relative `--out` means what the caller's shell
    // would mean by it. helm refuses a relative path outright.
    payload["path"] =
        URL(
            fileURLWithPath: (out as NSString).expandingTildeInPath,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardized.path
}
if let window { payload["window"] = window }

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

// A capture is one write, not two: helm draws synchronously, so there is no `started` state to
// pass through and nothing to keep waiting for after the first answer.
let resultURL = root.appendingPathComponent("results/\(id).json")
let deadline = Date().addingTimeInterval(timeout)

while Date() < deadline {
    if let data = try? Data(contentsOf: resultURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let status = json["status"] as? String
    {
        print(String(data: data, encoding: .utf8) ?? "{}")
        switch status {
        case "captured":
            guard let capture = json["capture"] as? [String: Any],
                let path = capture["path"] as? String
            else { die("helm said captured and named no file — that is a helm defect", .failed) }
            let contains = (capture["terminalContent"] as? String) ?? "?"
            FileHandle.standardError.write(
                Data("helm-capture: \(path) — terminal content \(contains)\n".utf8))
            exit(Exit.ok.rawValue)
        case "refused": die(json["reason"] as? String ?? "refused", .refused)
        case "failed": die(json["reason"] as? String ?? "failed", .failed)
        case "abandoned": die(json["reason"] as? String ?? "abandoned", .abandoned)
        default: die("unexpected status \(status) for a capture", .failed)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}

die(
    "no result at \(resultURL.path) within \(Int(timeout))s — is helm running, and is "
        + "HELM_SPOOL_OFF unset in it?", .noAnswer)
