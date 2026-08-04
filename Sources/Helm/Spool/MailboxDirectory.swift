import Foundation

/// One mailbox's `owner.json` — who is reachable at that address.
///
/// Written by the agent's own side of the mailbox (`hooks/helm-mail.mjs` for Claude Code,
/// `pi/extensions/helm-mail/index.ts` for pi), never by helm. helm only reads it.
struct MailboxOwner: Decodable, Equatable {
    let handle: String
    let runtime: String?
    let pid: pid_t
    let sessionId: String?
    let cwd: String?
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
enum MailboxDirectory {
    /// Where the mail lives. `HELM_MAIL_DIR` is honoured because both mail implementations
    /// honour it — a test that redirects one and not the other is testing nothing.
    static let directoryVariable = "HELM_MAIL_DIR"

    static func resolve(
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

    /// Every readable owner under `root`. A missing directory, an unreadable file or a
    /// malformed one yields absence rather than an error — the same rule `AgentRegistry`
    /// follows, and for the same reason: one bad file costs its own row and nothing else.
    static func owners(in root: URL) -> [MailboxOwner] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let decoder = JSONDecoder()
        return entries.compactMap { entry in
            let owner = entry.appendingPathComponent("owner.json")
            guard let data = try? Data(contentsOf: owner) else { return nil }
            return try? decoder.decode(MailboxOwner.self, from: data)
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
    static func owner(
        in owners: [MailboxOwner],
        foregroundPid: pid_t?,
        shellPid: pid_t?,
        ancestors: (pid_t) -> [pid_t] = { AgentLocator.ancestors(of: $0) }
    ) -> MailboxOwner? {
        if let foregroundPid, let direct = owners.first(where: { $0.pid == foregroundPid }) {
            return direct
        }
        guard let shellPid else { return nil }
        return owners.first { ancestors($0.pid).contains(shellPid) }
    }
}
