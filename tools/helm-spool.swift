// Start an agent in helm WITHOUT the display — issue #54, rung 2 of #51.
//
//   swift helm-spool.swift <cwd> --prompt-file <p>
//   swift helm-spool.swift <cwd> --prompt "..." --command pi
//   swift helm-spool.swift <cwd> -                    read the prompt from stdin
//
// This is the whole point of the rung. `helm-spawn.swift` next door does the same job through
// the GUI and therefore needs an unlocked screen, a visible helm window and an Accessibility
// grant on the invoking context — none of which an agent can grant itself, and all of which a
// headless or ssh session simply does not have. This writes a file and reads a file. It works
// with the screen locked.
//
// It writes `{id, cwd, command, args, prompt}` into helm's spool, then WAITS on
// `results/<id>.json` — no registry polling, no process-table walk, no heuristic about which
// new session belongs to this spawn. helm created the terminal, so helm knows.
//
// PREFER `--prompt-file` OR `-` TO `--prompt` (#93). The spawned agent's own argv never carries
// the prompt — helm stages it 0600 and hands the agent a path — but `--prompt TEXT` puts it in
// THIS process's argv while this process runs, which is exactly what #93 is about, one hop
// earlier. The other two forms never put it on a command line at all.
//
// The `handle` in the result is the thing worth waiting for: it is the spawned agent's mailbox
// address, so the caller's next move — "now tell it something" — needs no lookup of its own.
// helm reads it out of `~/.helm/mail/*/owner.json`; it is never derived from cwd and session id
// (see MailboxDirectory for why a derivation is silently wrong).
//
// helm adds the agent's unattended posture to `--arg` for you — `--dangerously-skip-permissions`
// for claude, `-p yolo` for codex, `--approve` for pi — because a prompt in a pane nobody is
// watching is a spawn that silently did nothing (#179). Each is the operator's own standing
// choice (`cls`, `cdxy`), and a posture removes a prompt rather than withholding capability.
// Naming a flag from the same family yourself turns that off for the run; the reasoning, and the
// costs weighed against it, are in `SpoolUnattendedPolicy`.
//
// A nonzero exit is the point: each refusal has its own code, and stderr says what happened.

import Foundation

// MARK: - Exits

enum Exit: Int32 {
    case ok = 0
    case usage = 1
    /// helm never answered. Either it is not running, its spool is elsewhere, or
    /// `HELM_SPOOL_OFF` is set in the helm that is running.
    case noAnswer = 2
    case refused = 3
    case failed = 4
    /// It started, and it cannot be addressed — no mailbox appeared for it.
    case unclaimed = 5
    /// helm restarted mid-flight and deliberately did not re-run the request.
    case abandoned = 6
}

func die(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data("helm-spool: \(message)\n".utf8))
    exit(code.rawValue)
}

// MARK: - Where the spool is

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

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
guard let cwdArgument = arguments.first, !cwdArgument.hasPrefix("--") else {
    die(
        """
        usage: helm-spool.swift <cwd> [--command claude|pi|codex] [--arg X]…
                                     [--prompt TEXT | --prompt-file PATH | -]
                                     [--id NAME] [--spool DIR] [--timeout SECONDS] [--no-wait]
        """, .usage)
}
arguments.removeFirst()

var command = "claude"
var args: [String] = []
var promptText: String?
var promptFile: String?
var readStdin = false
var id = "spool-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 4096...65535))"
var spoolOverride: String?
var timeout: Double = 180
var wait = true

func next(_ flag: String) -> String {
    guard let value = arguments.first else { die("\(flag) needs a value", .usage) }
    arguments.removeFirst()
    return value
}

while let flag = arguments.first {
    arguments.removeFirst()
    switch flag {
    case "-": readStdin = true
    case "--command": command = next(flag)
    case "--arg": args.append(next(flag))
    case "--prompt": promptText = next(flag)
    case "--prompt-file": promptFile = next(flag)
    case "--id": id = next(flag)
    case "--spool": spoolOverride = next(flag)
    case "--timeout": timeout = Double(next(flag)) ?? timeout
    case "--no-wait": wait = false
    default: die("unknown flag \(flag)", .usage)
    }
}

var prompt: String?
if readStdin {
    prompt = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
} else if let promptFile {
    guard let text = try? String(contentsOfFile: promptFile, encoding: .utf8) else {
        die("cannot read --prompt-file \(promptFile)", .usage)
    }
    prompt = text
} else {
    prompt = promptText
}
prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
if prompt?.isEmpty == true { prompt = nil }

let cwd = URL(fileURLWithPath: (cwdArgument as NSString).expandingTildeInPath).standardized.path

// MARK: - Submit

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

var payload: [String: Any] = ["id": id, "cwd": cwd, "command": command, "args": args]
if let prompt { payload["prompt"] = prompt }

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

guard wait else {
    print(destination.path)
    exit(Exit.ok.rawValue)
}

// MARK: - Wait on the answer alone

let resultURL = root.appendingPathComponent("results/\(id).json")
let deadline = Date().addingTimeInterval(timeout)
var lastStatus = ""

while Date() < deadline {
    if let data = try? Data(contentsOf: resultURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let status = json["status"] as? String
    {
        // `started` is the first of two writes: helm has the request and the terminal exists,
        // but the agent has not claimed a mailbox yet, so there is no handle to report. Keep
        // waiting for the change rather than reporting a null handle as an answer.
        if status != "started" {
            print(String(data: data, encoding: .utf8) ?? "{}")
            switch status {
            case "ready": exit(Exit.ok.rawValue)
            case "refused": die(json["reason"] as? String ?? "refused", .refused)
            case "failed": die(json["reason"] as? String ?? "failed", .failed)
            case "unclaimed": die(json["reason"] as? String ?? "unclaimed", .unclaimed)
            case "abandoned": die(json["reason"] as? String ?? "abandoned", .abandoned)
            default: die("unknown status \(status)", .failed)
            }
        }
        if status != lastStatus {
            lastStatus = status
            FileHandle.standardError.write(
                Data("helm-spool: \(id) started — waiting for it to become addressable\n".utf8))
        }
    }
    Thread.sleep(forTimeInterval: 0.25)
}

die(
    lastStatus.isEmpty
        ? "no result at \(resultURL.path) within \(Int(timeout))s — is helm running, and is "
            + "HELM_SPOOL_OFF unset in it?"
        : "the agent started but never became addressable within \(Int(timeout))s "
            + "(see \(resultURL.path))",
    lastStatus.isEmpty ? .noAnswer : .unclaimed)
