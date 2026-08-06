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

    /// **Validated on the way in, not just decoded.** `owner.json` has exactly two writers —
    /// `hooks/helm-mail.mjs` and `pi/extensions/helm-mail/index.ts` — and neither is Swift, so
    /// this decode is the one place Swift gets to refuse a malformed file rather than silently
    /// building a `MailboxOwner` nothing can address. An empty handle is exactly that kind of
    /// malformed, and since #239 so is one outside `[a-z0-9-]` — the alphabet those two writers'
    /// `slug` can emit, so neither can produce a file this refuses (`Handle`'s header has the
    /// measurement, including the `helm--678` case that keeps the rule from being tighter).
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

/// `~/.helm/mail` — the address book, read by pid.
///
/// **This is the identity lookup, and it replaces the Claude session registry rather than
/// supplementing it.** An earlier plan for #54 treated `~/.claude/sessions` as the source of
/// truth and pi as a degraded case with a null `sessionId`. Post-rung-3 that is backwards:
/// `owner.json` carries `handle`, `runtime`, `pid`, `sessionId` and `cwd` **for both
/// runtimes**, and helm already knows the pid authoritatively because it created the terminal.
/// So one join on pid gives a real answer for pi — where the Claude registry gives nothing at
/// all — and the same answer for Claude. One lookup, both runtimes, strictly less code than a
/// source of truth plus a degradation path.
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
/// **Lives in `HelmWire` (#221)** — `owner(in:foregroundPid:shellPid:ancestors:)` used to
/// default `ancestors` to `AgentLocator.ancestors(of:)`, but `AgentLocator` is `Helm`-only
/// (`Chat/AgentLocator.swift`, used by `ChatModel` too) and this library depends on nothing in
/// `Helm` — the dependency graph only runs the other way. So the default is gone and the one
/// caller across the module boundary, `SpoolModel.swift`, passes `{ AgentLocator.ancestors(of: $0) }`
/// explicitly; the tests that used to lean on the default do the same with a stand-in closure.
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

    /// The mailbox belonging to the process running in a terminal, given every owner and that
    /// terminal's two pids.
    ///
    /// **Two ways to match, in confidence order.** The agent is usually the pty's own
    /// foreground process, which is the direct hit and the one `BoardModel` already relies on.
    /// It is not always: a shell function, `env`, or a wrapper script can sit in between, and
    /// then the agent is a *descendant of the pane's login shell* while something else holds
    /// the foreground. `AgentLocator` makes exactly this distinction against the Claude
    /// registry; this is the same rule against the mailbox.
    ///
    /// Pure, and the ancestry is a closure, so the rule is a test that spawns nothing.
    /// **No default** — see the type's own header for why.
    package static func owner(
        in owners: [MailboxOwner],
        foregroundPid: pid_t?,
        shellPid: pid_t?,
        ancestors: (pid_t) -> [pid_t]
    ) -> MailboxOwner? {
        if let foregroundPid, let direct = owners.first(where: { $0.pid == foregroundPid }) {
            return direct
        }
        guard let shellPid else { return nil }
        return owners.first { ancestors($0.pid).contains(shellPid) }
    }
}
