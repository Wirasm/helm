import Foundation
import HelmWire

/// The teardown edge: answers what helm can see about one pane, and takes it off the bench.
///
/// The inverse of `WorkbenchSpoolSpawner`, and it lives beside it for the same reason — it is
/// the spool's adapter onto the bench, not a bench feature (`AGENTS.md`).
///
/// **It decides nothing.** Whether a pane may go is `SpoolClosePolicy`'s, on the far side of
/// `SpoolClosing`, where it is reachable from `swift test`. Everything here is a fact helm can
/// only read from a live bench: what the pane holds, where the keyboard is, what the pty's
/// foreground process is. Putting a rule in here would put it exactly where a test cannot go.
@MainActor
final class WorkbenchSpoolCloser: SpoolClosing {
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
        let foreground = terminals.sessions.first { $0.id == id }?.hostView.foregroundPid
        return SpoolPaneState(
            holdsTerminal: holdsTerminal,
            // The pane the operator is typing in, which is exactly `focusedPane`: the focused
            // slot's selected pane. Not "visible" — see `SpoolClosePolicy` for why a
            // visibility rule would refuse every teardown there is.
            holdsKeyboard: bench.focusedPane?.id == id,
            foreground: foreground,
            foregroundParent: foreground.flatMap(Self.parent),
            sessionLeader: foreground.flatMap(Self.sessionLeader))
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
