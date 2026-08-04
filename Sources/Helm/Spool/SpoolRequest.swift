import Foundation

/// What a caller asks helm to start: a directory, an agent, and the first thing to say to it.
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
/// Decoded permissively in shape and judged strictly afterwards — see `SpoolPolicy`. Splitting
/// those apart is what lets a malformed request be *refused with a reason* rather than dropped
/// by a decoder, which is the silence this whole ladder exists to remove.
struct SpoolRequest: Codable, Equatable {
    /// The caller's own name for this request. It is what the result file is named after, so
    /// the caller can wait on `results/<id>.json` without having to discover anything.
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
/// A separate type rather than a validated flag, so that "has this been checked?" is answered
/// by the compiler at every call site instead of by reading upwards.
struct AcceptedSpoolRequest: Equatable {
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
enum SpoolPolicy {
    /// The agents helm will start. Matched exactly: no paths, no arguments smuggled in, no
    /// case folding (these are real program names on a case-preserving filesystem).
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
    /// needs no filesystem. The one rule that genuinely needs disk — does `cwd` exist — is the
    /// one thing that comes in through the closure.
    static func accept(
        _ request: SpoolRequest,
        isDirectory: (String) -> Bool
    ) -> Result<AcceptedSpoolRequest, SpoolRefusal> {
        guard request.id.range(of: idPattern, options: .regularExpression) != nil else {
            return .failure(
                SpoolRefusal(
                    "id must match \(idPattern) — it names the result file, so it is a filename"))
        }
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
            AcceptedSpoolRequest(
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
/// **The rule.** *A question nobody will be there to answer must be answered in advance, with
/// the narrowest answer that lets the agent work.* Narrowest matters: the point is an agent
/// that runs, not an agent with every restraint removed, and the `cwd` in a request comes from
/// an untrusted file. Where an agent's answer differs below, the rule is the same and the
/// question is not.
///
/// - **`claude` → `--dangerously-skip-permissions`.** This is the operator's standing choice
///   on this machine, not helm's invention: `/Users/rasmus/.local/bin/cls` is exactly
///   `exec claude --dangerously-skip-permissions "$@"`, and `helm-spawn` — the GUI spawn path —
///   already types `cls`. Matching it is what makes the two paths agree about what "start a
///   Claude agent" means, which they did not. Claude Code has no sandbox, so there is nothing
///   narrower to preserve: the flag removes prompts, and prompts are the whole failure.
///
/// - **`codex` → `--ask-for-approval never`, and the sandbox is left alone.** codex asks too
///   (its default policy escalates to a human mid-run), so it has the same problem — but
///   unlike Claude Code it *has* a sandbox, and its default `workspace-write` is a real
///   boundary that costs the agent nothing here, since the workspace is the `cwd` it was
///   spawned for. `never` removes the prompt; failures outside the sandbox come back to the
///   model as errors instead of to a human as a dialog. The operator's own codex convention
///   (`cdxy` → `codex -p yolo`) goes further to `danger-full-access`, and that profile's own
///   comment says *"only run in a trusted directory"* — which is precisely what helm cannot
///   check about a directory named in a file it did not write. A request that wants it says so.
///
/// - **`pi` → `--no-approve`, which is the narrow answer in the other direction.** pi has no
///   sandbox and no per-tool prompt, so it never asks "may I act?". It asks one thing, at
///   startup and interactively only: *may I load project-local settings, extensions and skills
///   out of this directory?* (`defaultProjectTrust` is `ask`.) It hangs identically when
///   nobody answers. But nothing about "start an agent here" implies "and execute whatever
///   code this directory carries" — and the directory came from an untrusted request — so
///   `--approve` would be helm granting on the caller's behalf the one thing pi's prompt
///   exists to withhold. Declining is the half of a trust question that grants nothing, and it
///   still leaves the agent running. A caller that does want project trust writes `--arg -a`,
///   where it is explicit and auditable in the request file.
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
            arguments: ["--ask-for-approval", "never"],
            settled: [
                "-a", "--ask-for-approval", "--dangerously-bypass-approvals-and-sandbox",
                "-p", "--profile",
            ]),
        "pi": Posture(
            arguments: ["--no-approve"],
            settled: ["-a", "--approve", "-na", "--no-approve"]),
    ]

    /// The arguments helm will actually run, given what the request asked for.
    ///
    /// **Prepended rather than applied only to an empty `args`.** "The caller passed no
    /// arguments" is not the same as "the caller thought about this": a request for
    /// `claude --model opus` is one that never mentioned permissions, and dropping the posture
    /// for it would reinstate the exact silent hang being fixed, in the case hardest to notice.
    /// So the posture goes on unless a flag from the same family is already there.
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
    static func compose(_ request: AcceptedSpoolRequest, promptPath: String?) -> String {
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
