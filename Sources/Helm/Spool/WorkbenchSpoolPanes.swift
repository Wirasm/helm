import Foundation
import HelmWire

/// The addressed edge: answers what helm can see about one pane, takes it off the bench, brings it
/// forward, and calls it something.
///
/// The inverse of `WorkbenchSpoolSpawner`, and it lives beside it for the same reason — it is
/// the spool's adapter onto the bench, not a bench feature (`AGENTS.md`).
///
/// **One adapter for every request that names a pane, and that is why it is no longer called a
/// closer (#284, and a third verb since #313).** `pane(_:)` was never close-specific: it reports
/// where the operator is, what the pane holds and what it is already called, which is what *any*
/// addressed request has to be judged against. Splitting it up would mean N lookups of the same
/// pane, N copies of the `sysctl` this file makes, and N answers to "where is the operator" — the
/// seam defect `AGENTS.md` names.
///
/// **It decides nothing.** Whether a pane may go is `SpoolClosePolicy`'s, whether it may be shown
/// is `SpoolSelectPolicy`'s and whether it may be renamed is `SpoolNamePolicy`'s, all on the far
/// side of a protocol, where they are reachable from `swift test`. Everything here is a fact helm
/// can only read from a live bench: what the pane holds, where the keyboard is, what it is called,
/// what the pty's foreground process is. Putting a rule in here would put it exactly where a test
/// cannot go.
@MainActor
final class WorkbenchSpoolPanes: SpoolClosing, SpoolSelecting, SpoolNaming {
    private let workbench: WorkbenchModel
    private let terminals: TerminalManager

    init(workbench: WorkbenchModel, terminals: TerminalManager) {
        self.workbench = workbench
        self.terminals = terminals
    }

    func pane(_ id: UUID) -> SpoolPaneState? {
        guard let bench = workbench.bench, let pane = bench.pane(id) else { return nil }
        let holdsTerminal: Bool
        switch pane.content {
        case .terminal: holdsTerminal = true
        case .canvas: holdsTerminal = false
        }
        // Still reported, and no longer a refusal on its own (#284): it is what tells
        // `SpoolPaneState.isBusy` whether the live-process rule has anything to test. A canvas
        // pane has no `TerminalSession`, so `foreground` below is nil for one either way — the
        // flag is what makes that a stated rule rather than a coincidence of this lookup.
        let foreground = terminals.sessions.first { $0.id == id }?.hostView.foregroundPid
        return SpoolPaneState(
            holdsTerminal: holdsTerminal,
            keyboard: Self.keyboard(for: id, in: bench),
            // Read off the *pane*, not off the session, and for a canvas there is no session to
            // read. `TerminalSession.name` is a copy `reconcileSessions` pushes for rendering;
            // the bench is where it lives and what persists it.
            name: pane.name,
            foreground: foreground,
            foregroundParent: foreground.flatMap(Self.parent),
            sessionLeader: foreground.flatMap(Self.sessionLeader))
    }

    /// Where the operator's keyboard is relative to one pane — the only reading of the live bench
    /// either policy's focus rule needs.
    ///
    /// **`.here` is `focusedPane`, not "visible", and `.inItsSlot` is why the two are not the same
    /// question.** Under a bench every slot's selected pane is on screen, so a visibility rule
    /// would refuse every teardown there is (`SpoolClosePolicy` argues that). What matters is the
    /// focused *slot*: its selection is the pane the keyboard is in, and its other tabs are the
    /// panes that would **take** the keyboard if helm showed one (`SpoolSelectPolicy`).
    private static func keyboard(for id: UUID, in bench: Workbench) -> SpoolPaneState.Keyboard {
        guard bench.slot(for: id)?.id == bench.focusedSlot else { return .elsewhere }
        return bench.focusedPane?.id == id ? .here : .inItsSlot
    }

    /// **Reports the bench's answer, not the request's hope** — `close`'s rule below, and it is
    /// the same rule for the same reason: `WorkbenchModel.offerSelect` answers whether the pane is
    /// actually *visible* afterwards, and saying "shown" about a pane still hidden behind another
    /// would be the exact silence #284 exists to remove.
    func select(_ id: UUID) -> Result<SelectReport, SpoolRefusal> {
        guard let bench = workbench.bench else {
            return .failure(
                SpoolRefusal(
                    "helm has no bench to show a pane on. Open a workspace, or send a spawn — "
                        + "its cwd is what opens one."))
        }
        let before = bench.focusedPane?.id
        let visible = workbench.offerSelect(id)
        // Bound rather than written inline, for `WorkbenchSpoolCommander`'s reason:
        // `workbench.bench?.focusedPane?.id.map(…)` keeps the optional chain going and calls
        // `map` on the `UUID` itself, which does not compile.
        let focusedAfter = workbench.bench?.focusedPane?.id
        return .success(
            SelectReport(
                pane: TerminalID(id), isVisible: visible,
                focusedPaneBefore: before.map(TerminalID.init),
                focusedPaneAfter: focusedAfter.map(TerminalID.init)))
    }

    /// **Reports the bench's answer, not the request's hope** — `select`'s rule and `close`'s,
    /// for their reason: `name` below re-reads the pane *after* the mutation rather than echoing
    /// what it was asked for, so a `named` result about a pane that did not change would be the
    /// same silence #176 and #284 each removed once.
    func name(_ id: UUID, to name: PaneName) -> Result<NameReport, SpoolRefusal> {
        guard workbench.bench != nil else {
            return .failure(
                SpoolRefusal(
                    "helm has no bench to name a pane on. Open a workspace, or send a spawn — "
                        + "its cwd is what opens one."))
        }
        guard let previous = workbench.name(id, to: name) else {
            // Unreachable through the spool — `SpoolNamePolicy` has already refused a uuid this
            // bench has no pane for — and reported rather than assumed away, exactly as
            // `SpoolModel`'s `staysHidden` branch is.
            return .failure(
                SpoolRefusal(
                    "helm's bench has no pane \(id.uuidString) to name. Nothing was changed"))
        }
        let applied = workbench.bench?.pane(id)?.name.text ?? name.text ?? ""
        return .success(
            NameReport(
                pane: TerminalID(id), previousName: previous.text, name: applied))
    }

    /// **Reports the bench's answer, not the request's hope.** `WorkbenchModel.close` returns
    /// nothing and legitimately does nothing when `Workbench.canClose` refuses — the bench's
    /// last pane — so this asks afterwards whether the pane is really gone. Saying "closed"
    /// about a pane still sitting there would be the exact silence #176 exists to remove.
    func close(_ id: UUID) -> Bool {
        guard workbench.bench?.pane(id) != nil else { return false }
        workbench.close(id)
        return workbench.bench?.pane(id) == nil
    }

    /// The pty session's leader — the per-pane `/usr/bin/login`, not the shell. nil when it
    /// cannot be asked, which `SpoolPaneState.isBusy` reads as busy rather than as idle.
    private static func sessionLeader(of pid: pid_t) -> pid_t? {
        let session = getsid(pid)
        return session == -1 ? nil : session
    }

    /// A process's parent, from `KERN_PROC_PID`.
    ///
    /// There is no `getppid(pid)` — the libc call answers only about the caller — so this is
    /// the one sysctl helm makes. A single-pid query rather than `KERN_PROC_ALL`: helm asks
    /// about one process, and snapshotting the whole table to answer that would be `helm-spawn`
    /// solving a problem it has and this does not.
    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let parent = info.kp_eproc.e_ppid
        return parent == 0 ? nil : parent
    }
}
