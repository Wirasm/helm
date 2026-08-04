import Foundation

/// What a caller asks helm to do, as one of the kinds helm knows.
///
/// **This is the request side of the only capability on the ladder that a headless agent can
/// use.** Every other way of driving helm is GUI puppetry — `tools/helm-spawn.swift` needs an
/// unlocked screen, a visible window and an Accessibility grant on the invoking context, none
/// of which an agent can grant itself. A file appearing in a directory needs none of them, so
/// this works over ssh, with the screen locked, from a process with no display at all.
///
/// **A file, not an API (#54).** The operator's standing rule is that capability lives in
/// agent skills plus small CLIs, and *"helm exposes a tool the agent calls"* was declined four
/// separate times. A file is also the seam every other integration here already uses: the
/// session registry, the transcripts, the artifacts, the mailbox.
///
/// **A kind rather than a second directory (#174).** Self-capture arrived asking for a request
/// channel with exactly-once consumption and a result for every outcome, which is this one to
/// the letter. #33's ruling — *"there is no control channel, and building one would be the
/// mistake"* — is why a second one would have to be argued for rather than added; a second kind
/// on the channel #54 already justified needs no new argument.
///
/// Decoded permissively in shape and judged strictly afterwards — see `SpoolPolicy`. Splitting
/// those apart is what lets a malformed request be *refused with a reason* rather than dropped
/// by a decoder, which is the silence this whole ladder exists to remove.
enum SpoolRequest: Equatable {
    case spawn(SpawnRequest)
    case capture(CaptureRequest)
    /// A `kind` helm does not know. **Kept rather than thrown away**: a decoder that threw here
    /// would make "helm is older than this request" indistinguishable from "this file is not
    /// JSON", and the caller would be told the wrong thing about what to fix.
    case unrecognised(id: String, kind: String)

    /// The caller's own name for this request, whatever kind it is. It is what the result file
    /// is named after, so the caller can wait on `results/<id>.json` without discovering
    /// anything.
    var id: String {
        switch self {
        case .spawn(let request): request.id
        case .capture(let request): request.id
        case .unrecognised(let id, _): id
        }
    }
}

extension SpoolRequest: Decodable {
    private enum Envelope: String, CodingKey { case id, kind }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Envelope.self)
        // Absent means `spawn`, because every request written before #174 omits it and those
        // requests still mean what they meant.
        let kind =
            try container.decodeIfPresent(String.self, forKey: .kind) ?? SpawnRequest.kind
        switch kind {
        case SpawnRequest.kind: self = .spawn(try SpawnRequest(from: decoder))
        case CaptureRequest.kind: self = .capture(try CaptureRequest(from: decoder))
        default:
            self = .unrecognised(id: try container.decode(String.self, forKey: .id), kind: kind)
        }
    }
}

/// Start an agent: a directory, an agent, and the first thing to say to it.
struct SpawnRequest: Codable, Equatable {
    static let kind = "spawn"

    let id: String
    /// Where the agent runs. Becomes the terminal's working directory, and the workspace helm
    /// opens for it.
    let cwd: String
    /// The program to run — a bare name, gated by `SpoolPolicy.allowedCommands`.
    let command: String
    /// Arguments for it. Quoted by helm when the line is composed, so a caller never has to
    /// think about the shell. helm prepends the agent's unattended posture to these unless
    /// they settle it themselves — see `SpoolUnattendedPolicy`.
    var args: [String] = []
    /// The first thing said to the agent. Delivered through a file, never through the
    /// keyboard — see `SpoolLaunchLine`.
    var prompt: String?

    private enum CodingKeys: String, CodingKey { case id, cwd, command, args, prompt }

    init(id: String, cwd: String, command: String, args: [String] = [], prompt: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.command = command
        self.args = args
        self.prompt = prompt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cwd = try container.decode(String.self, forKey: .cwd)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
    }
}

/// Ask helm to draw its own window (#174).
///
/// **Nothing about a machine's permissions appears here, and that is the feature.** There is no
/// grant to name, no context to be the right one, and no rebuild that invalidates anything —
/// helm drawing itself is not screen capture. See `WindowCapture`.
struct CaptureRequest: Codable, Equatable {
    static let kind = "capture"

    let id: String
    /// Where to put the PNG. Absolute, ending in `.png`, in a directory that already exists.
    /// Omitted means the spool's own `captures/<id>.png`, which is always writable and always
    /// findable from the result.
    var path: String?
    /// Which window, matched case-insensitively against its title. Needed only when helm has
    /// more than one and none of them is key — otherwise the choice is unambiguous and helm
    /// makes it. An ambiguous capture is **refused**, never guessed: the window titles are the
    /// only thing telling an isolated instance from the operator's.
    var window: String?

    private enum CodingKeys: String, CodingKey { case id, path, window }

    init(id: String, path: String? = nil, window: String? = nil) {
        self.id = id
        self.path = path
        self.window = window
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        window = try container.decodeIfPresent(String.self, forKey: .window)
    }
}

/// Why helm will not do what a request asked.
///
/// A named type rather than a bare `String` because `Result`'s failure has to be an `Error` —
/// and because a refusal is a value the caller reads in `results/<id>.json`, so it deserves to
/// be one here too.
struct SpoolRefusal: Error, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// A request that has passed every gate, and therefore the only thing helm will act on.
///
/// A separate type per kind rather than a validated flag, so that "has this been checked?" is
/// answered by the compiler at every call site instead of by reading upwards.
enum SpoolWork: Equatable {
    case spawn(AcceptedSpawnRequest)
    case capture(AcceptedCaptureRequest)
}

struct AcceptedSpawnRequest: Equatable {
    let id: String
    let cwd: String
    let command: String
    /// **What will actually be on the command line**, not what the caller asked for: the
    /// request's own arguments with the agent's unattended posture prepended where it was
    /// missing (`SpoolUnattendedPolicy`). Resolving it here rather than in
    /// `SpoolLaunchLine.compose` keeps composition a pure quoter and makes this type honest
    /// about its name.
    let args: [String]
    let prompt: String?
}

struct AcceptedCaptureRequest: Equatable {
    let id: String
    /// **Resolved, never optional.** The default is applied here rather than at the edge, so
    /// no call site downstream can re-derive it differently — and so the one place that decides
    /// where a PNG lands is the one place that checked whether it may.
    let path: String
    let window: String?
}

/// Which requests helm will act on.
///
/// **Deliberately a strict allowlist, exactly like `TerminalURLPolicy`** — and for a stronger
/// reason. Terminal content is untrusted because a program can print anything; a spool request
/// is untrusted because it is a *file*, and anything that can write a file could otherwise
/// have helm run arbitrary commands in a login shell with the operator's whole environment.
///
/// The gate is therefore on **what may be started, not on what may be typed**: the command is
/// a bare program name from a fixed set, and everything else the caller controls is quoted
/// into a single argv element. `AGENTS.md` already names that set — *"Agent means a CLI agent
/// already in use — Claude Code, pi, codex"* — and #54 exists to start agents, so a spool that
/// can start `sh` is a spool that has stopped being about agents.
///
/// A capture starts nothing, so its gate is a different one: the only thing a caller controls
/// is where a PNG lands, and the rules below are what stop that being anywhere at all.
enum SpoolPolicy {
    /// The agents helm will start. Matched exactly: no paths, no arguments smuggled in, no
    /// case folding (these are real program names on a case-preserving filesystem).
    ///
    /// **This is the `spawn` kind's allowlist, and saying so is not pedantry now that there is
    /// more than one kind (#174).** A capture has no command at all, so "every command the
    /// spool accepts" and "every agent helm will start" stopped being the same sentence — and
    /// `SpoolUnattendedPolicy.postures` is keyed on *this* set, not on that one. A future kind
    /// that carries a command of its own would have to say whether it belongs here, rather than
    /// inheriting an answer nobody meant to give it.
    static let allowedCommands: Set<String> = ["claude", "pi", "codex"]

    /// An id is a filename component — `results/<id>.json` — so it is gated as one. `..` and
    /// `/` are the whole reason: an ungated id writes wherever the caller likes.
    static let idPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

    /// Bounds, so a malformed or hostile file costs a refusal rather than memory.
    static let maxArgs = 32
    static let maxArgLength = 4096
    static let maxPromptLength = 200_000

    /// The verdict on one decoded request.
    ///
    /// `isDirectory` is injected rather than reached for, so every rule below is a test that
    /// needs no filesystem. The two rules that genuinely need disk — does `cwd` exist, does a
    /// capture's destination directory exist — are the only things that come in through the
    /// closure.
    static func accept(
        _ request: SpoolRequest,
        captures: URL,
        isDirectory: (String) -> Bool
    ) -> Result<SpoolWork, SpoolRefusal> {
        guard request.id.range(of: idPattern, options: .regularExpression) != nil else {
            return .failure(
                SpoolRefusal(
                    "id must match \(idPattern) — it names the result file, so it is a filename"))
        }
        switch request {
        case .spawn(let spawn):
            return accept(spawn, isDirectory: isDirectory).map(SpoolWork.spawn)
        case .capture(let capture):
            return accept(capture, captures: captures, isDirectory: isDirectory)
                .map(SpoolWork.capture)
        case .unrecognised(_, let kind):
            return .failure(
                SpoolRefusal(
                    "kind \"\(kind)\" is not one helm knows. Allowed: "
                        + [SpawnRequest.kind, CaptureRequest.kind].joined(separator: ", ")))
        }
    }

    private static func accept(
        _ request: SpawnRequest, isDirectory: (String) -> Bool
    ) -> Result<AcceptedSpawnRequest, SpoolRefusal> {
        guard allowedCommands.contains(request.command) else {
            return .failure(
                SpoolRefusal(
                    "command \"\(request.command)\" is not one helm will start. Allowed: "
                        + allowedCommands.sorted().joined(separator: ", ")))
        }
        let cwd = Workspace.normalized(request.cwd)
        guard cwd.hasPrefix("/") else {
            return .failure(
                SpoolRefusal("cwd must be an absolute path, got \"\(request.cwd)\""))
        }
        guard isDirectory(cwd) else {
            return .failure(SpoolRefusal("cwd \"\(cwd)\" is not a directory that exists"))
        }
        guard request.args.count <= maxArgs else {
            return .failure(
                SpoolRefusal("too many args (\(request.args.count) > \(maxArgs))"))
        }
        for argument in request.args {
            guard argument.count <= maxArgLength else {
                return .failure(
                    SpoolRefusal("an argument is longer than \(maxArgLength) characters"))
            }
            // Control characters are refused rather than quoted. Single-quoting would in fact
            // make them literal, but an arg carrying a newline or a NUL is a caller doing
            // something it has not said out loud, and the cheap answer is to say no.
            guard
                argument.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0)
                })
            else {
                return .failure(SpoolRefusal("arguments may not contain control characters"))
            }
        }
        if let prompt = request.prompt {
            guard prompt.count <= maxPromptLength else {
                return .failure(
                    SpoolRefusal("prompt is longer than \(maxPromptLength) characters"))
            }
            guard !prompt.unicodeScalars.contains("\0") else {
                return .failure(SpoolRefusal("prompt may not contain a NUL byte"))
            }
        }
        return .success(
            AcceptedSpawnRequest(
                id: request.id, cwd: cwd, command: request.command,
                // Bounds above are judged on what the caller sent; the posture is helm's own
                // and is added after, so a request cannot spend its argument budget on flags
                // helm was going to supply anyway.
                args: SpoolUnattendedPolicy.arguments(
                    for: request.command, requested: request.args),
                // An empty prompt is no prompt: it would otherwise compose a line ending in
                // `""`, which some agents read as an empty first turn.
                prompt: request.prompt.flatMap { $0.isEmpty ? nil : $0 }))
    }

    /// **Where the PNG lands is the only thing a caller controls, so it is the only thing to
    /// gate.** The default is inside the spool the caller already writes to, so the common case
    /// asks for no permission at all; a named path has to be somewhere that already exists,
    /// because helm creating directories on a caller's word is a different capability than the
    /// one #174 asks for.
    private static func accept(
        _ request: CaptureRequest, captures: URL, isDirectory: (String) -> Bool
    ) -> Result<AcceptedCaptureRequest, SpoolRefusal> {
        var destination = captures.appendingPathComponent("\(request.id).png").path
        if let raw = request.path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardized
            guard path.path.hasPrefix("/") else {
                return .failure(
                    SpoolRefusal("path must be an absolute path, got \"\(raw)\""))
            }
            // A `.png` name rather than any name, because the result promises a PNG and a
            // caller that reads `capture.path` should not have to check what it got.
            guard path.pathExtension.lowercased() == "png" else {
                return .failure(SpoolRefusal("path must end in .png, got \"\(path.path)\""))
            }
            let parent = path.deletingLastPathComponent().path
            guard isDirectory(parent) else {
                return .failure(
                    SpoolRefusal(
                        "\"\(parent)\" is not a directory that exists — helm will not "
                            + "create one to put a capture in"))
            }
            destination = path.path
        }
        let window = request.window?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            AcceptedCaptureRequest(
                id: request.id, path: destination,
                window: window.flatMap { $0.isEmpty ? nil : $0 }))
    }
}

/// How an agent is started when **nobody is at the pane** — a separate boundary from
/// `SpoolPolicy`, and deliberately argued here rather than smuggled in as a flag (#179).
///
/// **The two boundaries.** `SpoolPolicy.allowedCommands` decides *what may run at all*: a
/// request is a file, so that gate is what stands between anything that can write a file and a
/// login shell with the operator's whole environment. This decides *what the agent may then do
/// once it is running* — a question that only exists because the agent was allowed to start.
/// Blurring them is how a security default gets made by accident, so they are two types.
///
/// **The failure this removes.** Every Claude agent the spool spawned stopped at a permission
/// prompt and did nothing: a pid with no child, a mailbox handle nobody could use, and a
/// worktree never created. A prompt assumes a human is looking at the pane. The spool's entire
/// purpose is that nobody is — it works with the screen locked, headless and over ssh — so an
/// agent that blocks on a dialog there is indistinguishable from one that never started. That
/// is the silent-failure shape this whole ladder exists to remove, and a default that produces
/// it is the wrong default.
///
/// **The rule.** *A question nobody will be there to answer must be answered in advance, and
/// answered so the agent can work.* Where an agent's answer differs below, the rule is the same
/// and the question is not.
///
/// **The corollary, and the durable part: blocking belongs in hooks and sandboxes, not in a
/// spawn posture.** An approval prompt is theatre — it stops nothing that a determined agent
/// cannot do a moment later, and with no one at the pane it stops *everything* instead. Real
/// enforcement is a thing that refuses without asking: a `PreToolUse` hook, a sandbox, a
/// review gate at the PR. So a posture removes prompts and never withholds capability to feel
/// safe. Withholding is the worse bug wearing the safer face: the agent starts, looks healthy,
/// and is quietly missing what it was pointed at — a failure of exactly the shape #179 exists
/// to remove, only harder to see, because there is no stalled pane to find.
///
/// - **`claude` → `--dangerously-skip-permissions`.** This is the operator's standing choice
///   on this machine, not helm's invention: `/Users/rasmus/.local/bin/cls` is exactly
///   `exec claude --dangerously-skip-permissions "$@"`, and `helm-spawn` — the GUI spawn path —
///   already types `cls`. Matching it is what makes the two paths agree about what "start a
///   Claude agent" means, which they did not. Claude Code has no sandbox, so there is nothing
///   narrower to preserve: the flag removes prompts, and prompts are the whole failure.
///
/// - **`codex` → `-p yolo`, which is what `cdxy` is.** `/Users/rasmus/.local/bin/cdxy` is
///   `exec codex -p yolo "$@"`, and `~/.codex/yolo.config.toml` is `approval_policy = "never"`
///   with `sandbox_mode = "danger-full-access"`. So this is the operator's standing choice for
///   codex, exactly as `--dangerously-skip-permissions` is his for claude, and the two lines
///   are one decision rather than two.
///
///   **The known cost, recorded rather than lost:** an earlier draft kept codex's
///   `workspace-write` sandbox and removed only the prompt, on the argument that a sandbox
///   blocks without asking and is therefore enforcement rather than theatre. The operator
///   overruled it: a posture that leaves a restraint on is still a posture that withholds
///   capability, and his gate is the pull request. Two further notes for whoever revisits
///   this. First, the profile's own comment says *"only run in a trusted directory"*, and the
///   `cwd` here comes from a request file — bounded by `SpoolPolicy`, not chosen by helm.
///   Second, this makes helm's posture depend on a file outside the repo, which is the same
///   objection that kept `cls` out of `allowedCommands`; the difference the operator accepted
///   is that this is an argument to a pinned program rather than the program itself, so a
///   missing profile is a bad codex run and not a different binary. The self-contained
///   spelling, if that ever matters, is `--dangerously-bypass-approvals-and-sandbox`, which
///   the profile's own comment calls equivalent.
///
/// - **`pi` → `--approve`.** pi has no sandbox and no per-tool prompt, so it never asks "may I
///   act?". It asks one thing, at startup and interactively only: *may I load project-local
///   settings, extensions and skills out of this directory?* (`defaultProjectTrust` is `ask`.)
///   It hangs identically when nobody answers, and the only two answers are grant or decline.
///
///   `--no-approve` was the first choice here and was wrong, on the operator's own principle.
///   It is neither theatre-removal nor enforcement: it withholds a capability, so a
///   spool-spawned pi would run without the settings, extensions and skills of the very
///   project it was pointed at — starting healthy and silently lacking its context. That is
///   the quieter failure, and this posture exists to remove failures nobody watches.
///
///   **The known cost, recorded rather than lost:** the directory comes from a request file,
///   so this does mean helm loads code from a `cwd` it did not choose. It is bounded rather
///   than open — `SpoolPolicy` already decides which directories may be named at all, and the
///   whole ladder assumes a caller that can write into the spool is already inside the trust
///   boundary — and where a real block is wanted it belongs in a hook, not in a flag helm
///   passes. A request that wants the other answer writes `--arg -na`.
///
/// **The allowlist is untouched.** No `cls` here, and that was the option to reject rather than
/// skip past: `cls` is a shell script on `PATH` that this repo does not define, cannot test and
/// cannot pin, so allowing it would turn a list of programs helm starts into a list of names
/// something else gets to define — and it buys nothing that naming the flag does not.
enum SpoolUnattendedPolicy {
    /// One agent's answer to "what happens when there is no human at the pane".
    struct Posture: Equatable {
        /// Prepended to the request's own arguments.
        let arguments: [String]
        /// Flags that mean *the caller has already decided*, so helm adds nothing. Matched on
        /// the flag name alone, so `--permission-mode plan` and `--permission-mode=plan` both
        /// count. This is the escape hatch, and it is the request's, not a helm setting.
        let settled: Set<String>
    }

    static let postures: [String: Posture] = [
        "claude": Posture(
            arguments: ["--dangerously-skip-permissions"],
            settled: ["--dangerously-skip-permissions", "--permission-mode"]),
        "codex": Posture(
            arguments: ["-p", "yolo"],
            settled: [
                "-a", "--ask-for-approval", "--dangerously-bypass-approvals-and-sandbox",
                "-p", "--profile",
            ]),
        "pi": Posture(
            arguments: ["--approve"],
            settled: ["-a", "--approve", "-na", "--no-approve"]),
    ]

    /// The arguments helm will actually run, given what the request asked for.
    ///
    /// **Prepended rather than applied only to an empty `args`.** "The caller passed no
    /// arguments" is not the same as "the caller thought about this": a request for
    /// `claude --model opus` is one that never mentioned permissions, and dropping the posture
    /// for it would reinstate the exact silent hang being fixed, in the case hardest to notice.
    /// So the posture goes on unless a flag from the same family is already there.
    ///
    /// **`settled` is matched against `requested` alone, never against the composed line, and
    /// that is load-bearing now that codex's posture is itself `-p yolo`.** `-p` is in codex's
    /// `settled` set meaning *the request already chose a profile*; if the check ever ran over
    /// the result instead, helm's own `-p` would answer its own question and every codex
    /// posture would cancel itself. The order below — decide from `requested`, then prepend —
    /// is what keeps those two `-p`s from being the same `-p`.
    static func arguments(for command: String, requested: [String]) -> [String] {
        guard let posture = postures[command] else { return requested }
        let named = Set(requested.map { String($0.prefix { $0 != "=" }) })
        guard named.isDisjoint(with: posture.settled) else { return requested }
        return posture.arguments + requested
    }
}

/// The one line helm writes into the new terminal's pty.
///
/// **Nothing here is a synthesised keystroke, and that is the acceptance criterion.**
/// `helm-spawn` had to drive CGEvents at whatever pane happened to hold the keyboard, which is
/// how #96 was filed. helm owns this surface, so the bytes go straight into *that* pty through
/// `ghostty_surface_text` — no focus, no display, no chance of landing in the wrong pane.
///
/// **The prompt never appears on the command line.** It is staged in a 0600 file and read back
/// with `"$(cat …)"`, which is `helm-spawn`'s trick and is what makes a multi-line prompt, a
/// leading `/`, and shell quoting all ordinary rather than three separate hazards.
///
/// There is no `cd`: the pane's working directory is already the request's `cwd`, because the
/// workspace helm opened for it *is* that directory.
enum SpoolLaunchLine {
    static func compose(_ request: AcceptedSpawnRequest, promptPath: String?) -> String {
        var parts = [quoted(request.command)]
        parts.append(contentsOf: request.args.map(quoted))
        if let promptPath {
            parts.append("\"$(cat \(quoted(promptPath)))\"")
        }
        return parts.joined(separator: " ")
    }

    /// POSIX single-quoting: everything inside is literal, and an embedded `'` is closed,
    /// escaped and reopened. The only escaping rule a shell has no exceptions to.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
