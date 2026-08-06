import Foundation

/// One mailbox's `owner.json` — who is reachable at that address.
///
/// Written by the agent's own side of the mailbox (`hooks/helm-mail.mjs` for Claude Code,
/// `pi/extensions/helm-mail/index.ts` for pi), never by helm. helm only reads it.
package struct MailboxOwner: Decodable, Equatable {
    package let handle: String
    package let runtime: String?
    package let pid: pid_t
    package let sessionId: String?
    package let cwd: String?

    /// Epoch milliseconds, set by the agent's own side when this mailbox's owner was judged gone
    /// (#236). Present means **retired**: the directory and its `read/` archive are still on disk,
    /// but nobody is listening at that address.
    ///
    /// helm reads it for one reason — `owners(in:)` drops these rows, and its header says why.
    /// A `Double` rather than a `Date` because the writers are JavaScript and write `Date.now()`;
    /// decoding it as a `Date` would need a strategy this decoder does not set, and the value is
    /// never rendered, only tested for presence.
    package let retiredAt: Double?

    /// **A `package`-visible fixture constructor, not a second route off disk — and since #233
    /// not a second route past the validation either.** It exists for test code across the
    /// module boundary (`Tests/HelmTests/Board/BenchSnapshotTests.swift` builds owner records
    /// directly to drive `OwnerRecord`); nothing in `Sources/` calls it.
    ///
    /// It takes a `Handle` rather than a raw `String` because `init(from:)` below closed only
    /// the untrusted-input half: a malformed `owner.json` costs its own row, but in-package
    /// Swift could still hand-construct an owner nothing can address, and `Handle(readingFrom:)`
    /// would copy that verbatim. That was left carried by a comment on `Handle`, which is
    /// accurate right up until someone stops reading it. A caller that genuinely wants a
    /// specific handle now writes `Handle(validating: "…")!` and says so out loud.
    package init(
        handle: Handle, runtime: String?, pid: pid_t, sessionId: String?, cwd: String?,
        retiredAt: Double? = nil
    ) {
        self.handle = handle.value
        self.runtime = runtime
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.retiredAt = retiredAt
    }

    private enum CodingKeys: String, CodingKey {
        case handle, runtime, pid, sessionId, cwd, retiredAt
    }

    /// The one runtime that publishes a pid→session registry helm can read.
    ///
    /// Spelled once here rather than at each comparison: `AddressBook` asks this question on
    /// every join, and "is this owner one the registry can speak for" is the whole difference
    /// between resolving by session and resolving by pid (#247).
    package static let claudeRuntime = "claude"

    /// Can Claude Code's session registry answer "where is this owner now"?
    ///
    /// **Only for a `claude` owner carrying a session id.** pi keys its sessions by cwd-slug
    /// (`~/.pi/agent/sessions/--path--`) and publishes no pid→session mapping at all, so a pi
    /// owner's `sessionId` is pi's own and means nothing to `~/.claude/sessions` — #236 settled
    /// that on the JS side and #245 is where pi's own rule gets decided. An owner the registry
    /// cannot speak for keeps being resolved on its recorded pid, which is the only answer
    /// available for it.
    package var isRegistryBacked: Bool {
        runtime == Self.claudeRuntime && !(sessionId ?? "").isEmpty
    }

    /// **Validated on the way in, not just decoded.** `owner.json` has exactly two writers —
    /// `hooks/helm-mail.mjs` and `pi/extensions/helm-mail/index.ts` — and neither is Swift, so
    /// this decode is the one place Swift gets to refuse a malformed file rather than silently
    /// building a `MailboxOwner` nothing can address. An empty handle is exactly that kind of
    /// malformed, and since #239 so is one outside `[a-z0-9-]` — the alphabet those two writers'
    /// `slug` can emit, so neither can produce a file this refuses (`Handle`'s header has the
    /// measurement, and why the rule is deliberately looser than what they actually emit).
    /// `MailboxDirectory.owners(in:)`'s own header already promises "a missing directory, an
    /// unreadable file or a malformed one yields absence rather than an error… one bad file costs
    /// its own row and nothing else" for JSON that fails to parse at all, and its
    /// `compactMap { try? decoder.decode(…) }` is what turns a thrown error here into that same
    /// promise rather than a crash — an unaddressable handle is malformed by the same rule, not a
    /// different one.
    ///
    /// **It calls `Handle(validating:)` rather than restating it, and that is the fix #233
    /// finished.** #231 closed this hole by copying the trim-and-reject in here, which bought
    /// the behaviour and left two hand-maintained spellings of one rule with only a comment
    /// asking them to agree — the same defect one size smaller, and one that had already shipped
    /// once between these very routes (`9863944`). Trimming comes with the call, so `handle` is
    /// still never stored with the whitespace a hand-edited file might carry.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .handle)
        guard let validated = Handle(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .handle, in: container,
                debugDescription:
                    "handle must be non-empty and drawn from [a-z0-9-] — the alphabet both "
                    + "owner.json writers' slug emits")
        }
        handle = validated.value
        runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
        pid = try container.decode(pid_t.self, forKey: .pid)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        retiredAt = try container.decodeIfPresent(Double.self, forKey: .retiredAt)
    }
}

/// `~/.helm/mail` — where the address book lives, and how it is read off disk.
///
/// **`owner.json` is still the identity, and the Claude registry is still not a second source
/// of truth.** An earlier plan for #54 treated `~/.claude/sessions` as the truth and pi as a
/// degraded case with a null `sessionId`; post-rung-3 that is backwards, because `owner.json`
/// carries `handle`, `runtime`, `pid`, `sessionId` and `cwd` **for both runtimes** and the
/// registry describes only one of them. What #247 changed is narrower and does not disturb
/// that: the registry is how a **pid** is turned into a session id, and the session id is what
/// the address book is joined on. The identity still comes out of `owner.json`. See
/// `AddressBook`.
///
/// # The handle is read, never derived
///
/// It *looks* derivable — `<cwd basename>-<last 4 of the session id>` — and that is the trap.
/// `deriveHandle` (`hooks/helm-mail.mjs`) widens the suffix 4 → 6 → 8 → full when a live
/// process already holds the shorter form, so a computed handle is wrong whenever the
/// derivation widened, and the caller cannot see that it did. It also short-circuits entirely
/// on a `HELM_MAIL_HANDLE` pin, so a derivation can be wrong with no collision at all.
///
/// **Rare, silent and undetectable from outside is worse than common.** Measured across six
/// handles on one machine — four of them agents sharing a single directory — every one
/// resolved at width 4 and none collided. A derivation would have been right every time in
/// testing and wrong the first time two session ids happened to end in the same four
/// characters. Reading the file is the only correct resolution, so it is the only one here.
///
/// **Lives in `HelmWire` (#221)** — the join used to default `ancestors` to
/// `AgentLocator.ancestors(of:)`, but `AgentLocator` is `Helm`-only (`Chat/AgentLocator.swift`,
/// used by `ChatModel` too) and this library depends on nothing in `Helm` — the dependency
/// graph only runs the other way. So there is no default, and the callers across the module
/// boundary pass the live lookups in. `AddressBook.sessionFor` arrived by the same rule.
package enum MailboxDirectory {
    /// Where the mail lives. `HELM_MAIL_DIR` is honoured because both mail implementations
    /// honour it — a test that redirects one and not the other is testing nothing.
    package static let directoryVariable = "HELM_MAIL_DIR"

    package static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment[directoryVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".helm/mail")
    }

    /// Every **addressable** owner under `root`. A missing directory, an unreadable file or a
    /// malformed one yields absence rather than an error — the same rule `AgentRegistry`
    /// follows, and for the same reason: one bad file costs its own row and nothing else.
    ///
    /// # Retired owners are dropped here, and here is the only place that can be right
    ///
    /// Before #236 a gone owner's `owner.json` was **deleted**, so helm was correct by
    /// construction: the row stopped existing and nothing could join to it. #236 stopped
    /// deleting — `read/` was going with it, and the delete raced a sender mid-write — so a
    /// retired mailbox now keeps its file, with its last-known pid, **forever**.
    ///
    /// That is a live hazard for every consumer here, because they all join on pid: macOS
    /// reuses pids, and this workspace churns them (a process per spawn, a process per hook
    /// firing). The first stale retired pid the OS hands to an unrelated live terminal would
    /// make `owner(in:foregroundPid:…)` return the wrong mailbox — `SpoolModel` answering a
    /// spawn with a dead agent's `handle`, and `BenchSnapshot` attributing a dead session's
    /// identity to a live pane every two seconds, in the file outside agents are told to trust.
    /// Silent in both cases: no error, just a wrong answer.
    ///
    /// **Filtered at the source rather than at the joins, because there are two joins and only
    /// one of them goes through `owner(in:…)`** — `BenchSnapshot.TerminalRecord` does its own
    /// `owners.first(where: { $0.pid == pid })`. Two call sites each remembering to exclude
    /// retired rows is the same shape of defect as the one #236 fixed: one rule, two spellings,
    /// and nothing to notice when they disagree. A consumer that genuinely wants retired rows
    /// should decode them deliberately rather than filter them back out.
    package static func owners(in root: URL) -> [MailboxOwner] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let decoder = JSONDecoder()
        return entries.compactMap { entry in
            let owner = entry.appendingPathComponent("owner.json")
            guard let data = try? Data(contentsOf: owner) else { return nil }
            guard let decoded = try? decoder.decode(MailboxOwner.self, from: data) else {
                return nil
            }
            return decoded.retiredAt == nil ? decoded : nil
        }
    }

}

/// Everyone addressable right now, together with the one lookup that turns a pid into an
/// identity — and the single place "which agent is in this pane" is answered.
///
/// # A recorded pid is neither identity nor liveness (#236, #247)
///
/// `owner.json` records a pid at `SessionStart` and is **never rewritten**, so a helm restart
/// brings every agent back in the same session under a new pid and leaves a stale number in
/// every owner file. #236 taught the JS half to ask the session first; this is the same rule on
/// the Swift side, and it was left behind:
///
/// ```swift
/// owners.first(where: { $0.pid == foregroundPid })   // what this used to be
/// ```
///
/// **#236 made that more reachable, not less.** Before it, a live owner with a stale pid was
/// reaped and vanished, so the join could not hit it. Now — correctly — that row survives, so
/// the population of live rows carrying stale pids goes *up* while macOS keeps recycling pids
/// (a process per spawn, a process per hook firing). The first collision answers a spool spawn
/// with another agent's `handle` and attributes the wrong session to a pane in
/// `snapshot.json`, the file agents outside the process are told to trust. Silent both ways.
///
/// The rule is therefore **pid → registry row → `sessionId` → mailbox**, with the pid match
/// kept only for an owner the registry cannot speak for.
///
/// # Why a value rather than two arguments
///
/// There are two joins — `SpoolModel` through `owner(foregroundPid:shellPid:ancestors:)`, and
/// `BenchSnapshot.TerminalRecord` through `owner(forPid:)` — and `BenchSnapshot` carries what
/// it joins on down through five nested initializers. Two parallel parameters riding that far
/// together, with only a habit keeping them in step, is the shape this repo has been bitten by
/// before; one value carries the rule with it and neither side can bring half of it.
///
/// Pure, and both lookups are closures, so every rule here is testable without spawning a
/// process or reading a registry. **No defaults** — see `MailboxDirectory`'s header for why.
package struct AddressBook {
    /// Everyone addressable — `MailboxDirectory.owners(in:)`'s output, retired rows already
    /// dropped at the source (#236) so no join here has to remember to exclude them.
    package let owners: [MailboxOwner]

    /// Which Claude Code session is running in a given pid, per that runtime's own registry
    /// (`~/.claude/sessions/<pid>.json`, read by `AgentRegistry`).
    ///
    /// A closure for exactly the reason `ancestors` is one: `HelmWire` depends on nothing in
    /// `Helm`, and `AgentRegistry`/`AgentLocator` live in `Helm`. `nil` means **the registry
    /// says nothing about that pid** — never "that pid has no session", and never a licence to
    /// guess.
    package let sessionFor: (pid_t) -> String?

    package init(owners: [MailboxOwner], sessionFor: @escaping (pid_t) -> String?) {
        self.owners = owners
        self.sessionFor = sessionFor
    }

    /// The mailbox belonging to the process running at `pid`.
    ///
    /// **Ask the registry which session is in that process, then join on the session.** The pid
    /// is how the session is found and nothing more, which is what makes a recycled pid
    /// harmless and a stale one survivable: an agent resumed into a new process still resolves,
    /// because the registry row moved with it while `owner.json` did not.
    ///
    /// **One sentence: a registry-backed owner is matched only by its session; everyone else is
    /// matched by their recorded pid.** That is what makes the pid branch safe to keep — it can
    /// never return a Claude owner, so no fallback can quietly undo the rule above it.
    ///
    /// The consequences are worth stating, because both are deliberate:
    ///
    /// - **A known session that no mailbox carries is absence.** If the pane runs Claude session
    ///   *X* and no owner claims *X*, any owner whose recorded pid happens to equal this one is
    ///   stale or recycled by definition. The agent has no mailbox yet, and a caller that polls
    ///   (`SpoolModel`) sees one the moment its `SessionStart` hook writes it.
    /// - **pi is never taken off the air by the registry.** pi publishes no pid→session mapping
    ///   anywhere on disk, so its recorded pid is the whole answer available — deliberate, and
    ///   #245 is where it gets revisited. A stale Claude row sitting on a pid pi now holds does
    ///   not cost pi its mailbox, because the pid branch is still reached.
    package func owner(forPid pid: pid_t) -> MailboxOwner? {
        if let session = sessionFor(pid), !session.isEmpty,
            let claimed = owners.first(where: { $0.isRegistryBacked && $0.sessionId == session })
        {
            return claimed
        }
        return owners.first { !$0.isRegistryBacked && $0.pid == pid }
    }

    /// The mailbox belonging to the process running in a terminal, given that terminal's two
    /// pids.
    ///
    /// **Two ways to match, in confidence order.** The agent is usually the pty's own
    /// foreground process — the direct hit above, and the same assumption `BoardModel` makes
    /// when it looks a pane's foreground pid up in the registry. It is not always: a shell
    /// function, `env`, or a wrapper script can sit in between, and then the agent is a
    /// *descendant of the pane's login shell* while something else holds the foreground.
    ///
    /// **The ancestry branch is deliberately left on the pid, and it is not the defect the
    /// direct match was.** `ancestors` walks the **live** process tree, so a dead recorded pid
    /// yields an empty chain and matches nothing, and a recycled one has to genuinely be
    /// running under *this pane's own shell* before it can match. That is a far narrower
    /// coincidence than bare pid equality anywhere on the machine, and it is liveness-checked
    /// by construction rather than by remembering to check.
    ///
    /// **The residual that argument leaves, stated rather than hidden.** It defends against a
    /// wrong match and says nothing about a missed one: an agent that resumed under a new pid
    /// *and* sits behind a wrapper is found by neither branch — the direct one because the
    /// wrapper holds the foreground and has no registry row, this one because it still walks up
    /// from the owner's stale recorded pid, which is dead and has no ancestors. The failure is
    /// an absence, not a misattribution — `SpoolModel` answers `unclaimed` and keeps polling
    /// until the agent is the foreground process again — so it is the safe direction to fail
    /// in, and it is not a regression: the pre-#247 join missed that case too.
    ///
    /// Closing it needs the inverse of `sessionFor` (session → live pid) or a walk *down* from
    /// the shell, and neither is a lookup this signature has. That is deliberately not invented
    /// here: it would widen "which agent is in this pane" into process-tree search on the
    /// strength of a case nothing has yet reported.
    package func owner(
        foregroundPid: pid_t?,
        shellPid: pid_t?,
        ancestors: (pid_t) -> [pid_t]
    ) -> MailboxOwner? {
        if let foregroundPid, let direct = owner(forPid: foregroundPid) { return direct }
        guard let shellPid else { return nil }
        return owners.first { ancestors($0.pid).contains(shellPid) }
    }
}
