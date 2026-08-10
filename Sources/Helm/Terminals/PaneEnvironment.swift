import Foundation
import HelmWire

/// The environment a pane's pty child gets: what helm **publishes** into it, and what helm
/// refuses to let it **inherit**.
///
/// Both halves are one subject, which is why they are one file. A hosted agent asking "which
/// session am I?" had two sources of truth and they disagreed: helm passed nothing of its own
/// (#94), while the `CLAUDE_*` variables of whatever session launched helm rode all the way
/// into every pane (#139). Fixing only the second leaves the agent with no identity at all;
/// fixing only the first leaves the wrong one still readable next to the right one, which is
/// worse than either.
enum PaneEnvironment {
    // MARK: - What helm publishes

    /// The variable naming the pane a child is running in — `TerminalSession.id`, the same
    /// uuid the tab row is persisted under.
    ///
    /// **Publish-only, and that is the whole design (#33, #94).** helm tells the child what
    /// pane it is in; nothing reads back, and helm exposes nothing to call. An agent that
    /// wants to be addressable writes the uuid somewhere itself — a mailbox handle, a result
    /// file — which needs no protocol and no control channel.
    static let paneVariable = "HELM_PANE"

    /// The environment every pty child gets on top of the ones it inherits.
    ///
    /// **Truecolor, declared instead of inherited.** `term` is pinned to
    /// `xterm-256color` (see `TerminalSession.sessionOverrides`) because the embedded
    /// xcframework ships no terminfo, and a great many programs read that name alone as
    /// "256 colours, no more". pi and ghostty got 24-bit output here anyway, but only by
    /// accident: something in helm's own environment — `GHOSTTY_RESOURCES_DIR`, set for shell
    /// integration — was being inherited by the child and read as a ghostty tell. That is a
    /// coincidence one refactor away from ending, and its failure is silent: every colour in
    /// the palette would quietly snap to the nearest of 256 with nothing logged and nothing to
    /// see except that helm looks slightly wrong. Saying it outright costs two strings.
    ///
    /// `TERM_PROGRAM` is the same statement in the other vocabulary — the variable ghostty
    /// itself exports, and the one a program asks when `TERM` has been overridden.
    static let terminalDeclaration: [String: String] = [
        "COLORTERM": "truecolor",
        "TERM_PROGRAM": "ghostty",
    ]

    /// The suite an isolated instance runs under, declared into the child rather than left to
    /// be inherited — #285.
    ///
    /// **It is the same argument `terminalDeclaration` makes about `COLORTERM`, on a variable
    /// that is now load-bearing.** helm's own `environ` already carries this, and ghostty builds
    /// each surface's child environment from `environ`, so a hosted agent can read it today —
    /// which is why `staleIdentityKeys` deliberately leaves it alone ("helm telling the child
    /// the truth"). But that is inheritance, and inheritance is what `COLORTERM` was: correct by
    /// coincidence, one refactor away from ending, and silent when it does. Since #285 the
    /// mailbox's two writers resolve their root from this variable — an agent that cannot see it
    /// claims in the **operator's** `~/.helm/mail` instead of the instance's own, which is the
    /// exact leak #285 exists to close, restored with nothing to see.
    ///
    /// **The decided name, never the raw value.** `DefaultsSuite.override` is what helm itself
    /// obeyed at launch, so a child can never be told a suite helm refused — and under no suite
    /// nothing is published at all, because the default *is* the default and a variable saying
    /// so would be a second way to spell it.
    static func suiteDeclaration(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard case .suite(let name) = DefaultsSuite.override(in: environment) else { return [:] }
        return [DefaultsSuite.suiteVariable: name]
    }

    /// What a pane's pty child is spawned with: the terminal declaration, the instance's suite
    /// when there is one, plus this pane's own identity.
    ///
    /// Set once, at `TerminalSession.init`, and baked into the child at spawn — so it costs
    /// nothing at the two moments #94 asks about. A pane **moved** between containers keeps
    /// it because moving does not respawn the surface; a pane **restored** after a relaunch
    /// gets the persisted uuid back because `TerminalSession.id` is injected on restore, and
    /// the child is new anyway.
    static func forPane(
        _ id: UUID, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = terminalDeclaration
        result.merge(suiteDeclaration(in: environment)) { _, suite in suite }
        result[paneVariable] = id.uuidString
        return result
    }

    // MARK: - What helm refuses to pass on

    /// The namespaces a coding agent uses to say *"you are inside this session of me"*.
    ///
    /// helm's own process carries whatever the session that launched it exported, and
    /// libghostty spawns each pty from that environment — so without this, a Claude Code
    /// session that ran `swift run helm` hands its `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`
    /// to every agent helm hosts, and a *pi* in a pane prints `CLAUDECODE=1` alongside
    /// `PI_CODING_AGENT=true` (#139). The failure has no error in it: an agent reading
    /// `$CLAUDE_CODE_SESSION_ID` gets a confident, plausible, other agent's identity.
    ///
    /// **Prefixes rather than the six names actually observed, because a list is what goes
    /// stale.** The next variable Claude Code adds would walk straight back through a name
    /// list and the bug would return wearing a new label. `CLAUDE` has no underscore on
    /// purpose — `CLAUDECODE` is one of the leaked names. `PI_` does, so `PIP_*` and friends
    /// are untouched.
    ///
    /// **What the prefix costs is paid back by the login shell.** A pane runs `$SHELL` as a
    /// login shell, so anything the operator genuinely *configured* — an export in
    /// `~/.zshrc`, `CLAUDE_CONFIG_DIR`, `PI_CODING_AGENT_DIR` — is re-established inside the
    /// pane. What does not come back is session state, which is exactly the part that lies.
    ///
    /// `ANTHROPIC_*` is deliberately **not** here: an API key is credentials the hosted agent
    /// needs, not an identity claim about a session it is not in.
    static let staleIdentityPrefixes = ["CLAUDE", "PI_"]

    /// The keys `removeStaleIdentity` would take out of `environment`, sorted. Pure, so the
    /// rule above is a test rather than a claim.
    static func staleIdentityKeys(in environment: [String: String]) -> [String] {
        environment.keys
            .filter { key in staleIdentityPrefixes.contains { key.hasPrefix($0) } }
            .sorted()
    }

    /// Drop the stale identity from **helm's own process**, once, at launch.
    ///
    /// This is the only mechanism that actually removes them. libghostty's per-surface
    /// `env_vars` hook is a `put` into ghostty's config map (`Surface.zig`), so it can set a
    /// variable to empty but never unset one — and `CLAUDE_CODE_SESSION_ID=` present-but-empty
    /// is still a second answer to "which session am I?". ghostty builds each surface's child
    /// environment from `environ` at surface init, so `unsetenv` here means the child is
    /// spawned without them at all. Process-wide by nature, which also covers the subprocesses
    /// helm runs itself — `ArchonCLI` inherits `ProcessInfo.processInfo.environment`.
    ///
    /// **Neither obvious way of checking this from outside works, and both look like a
    /// finding.** `ps eww -p <helm pid>` reads the exec-time argv/env page, not the live
    /// `environ`, so it lists the stale variables for as long as helm runs whether or not
    /// this ever ran — it is where #139 was measured, and it cannot show the fix. And a
    /// pane's own shell has no readable environment at all: ghostty spawns it through
    /// setuid `/usr/bin/login`, which sets `P_SUGID`, and `ps` refuses `KERN_PROCARGS2` for
    /// a sugid process and all of its descendants. What does work is asking the shell:
    /// launch helm with `ZDOTDIR` pointing at a directory whose `.zshenv` runs `env > file`,
    /// and read the file. Measured that way (2026-08-04): nine variables in the pane's shell
    /// without this call, none with it, `HELM_PANE` present either way.
    ///
    /// Loud rather than silent: this quietly changes what a pane inherits, so it says which
    /// keys went.
    static func removeStaleIdentity(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let keys = staleIdentityKeys(in: environment)
        guard !keys.isEmpty else { return }
        for key in keys { unsetenv(key) }
        NSLog(
            "helm: dropped %d inherited agent-identity variable(s) from the pane environment: %@",
            keys.count, keys.joined(separator: ", "))
    }
}
