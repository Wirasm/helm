import Darwin
import Foundation

/// Which registry row belongs to the process running in this terminal.
///
/// `claude` is usually the pty's own foreground process, but not always — a
/// shell function, `env`, or a wrapper script can sit in between — so a direct
/// pid match is tried first and a walk only after it misses.
///
/// The selection rule is pure and takes the pid chain as an argument; only
/// `ancestors(of:)` touches live processes. That split is what makes the rule
/// testable without spawning anything.
enum AgentLocator {
    /// The row for `pid`, given the registry and `pid`'s ancestor chain.
    ///
    /// Order is the confidence order: an exact pid match is the agent, an
    /// ancestor match is the agent behind a wrapper, and a descendant match is
    /// the last resort for an agent launched *under* something that still owns
    /// the pty. Ties among descendants go to the newest session.
    static func session(
        in rows: [AgentSession], forPid pid: pid_t, ancestors: [pid_t],
        descendantsOf isDescendant: (AgentSession) -> Bool = { _ in false }
    ) -> AgentSession? {
        if let direct = rows.first(where: { $0.pid == pid }) { return direct }
        for step in ancestors {
            if let hit = rows.first(where: { $0.pid == step }) { return hit }
        }
        return rows.filter(isDescendant).first
    }

    /// The live version: reads the registry, walks the real process tree.
    static func session(
        forForegroundPid pid: pid_t, root: URL = AgentRegistry.defaultRoot
    )
        -> AgentSession?
    {
        let rows = AgentRegistry.sessions(in: root)
        return session(
            in: rows, forPid: pid, ancestors: ancestors(of: pid),
            descendantsOf: { row in
                isAlive(row.pid) && ancestors(of: row.pid).contains(pid)
            })
    }

    /// `sysctl(KERN_PROC_PID)` — a syscall, not a subprocess, so it is safe on a
    /// poll timer.
    static func parentPid(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// **The walk stops at helm's own pid, and that is load-bearing.**
    ///
    /// Everything running in this surface is *below* helm. Above helm is whatever
    /// launched it — very often the operator's own agent session, which an
    /// unbounded walk then reports as "the transcript of the terminal below".
    /// The spike hit exactly this and rendered a 3.4 MB transcript of a different
    /// conversation, confidently and indistinguishably.
    static func ancestors(of pid: pid_t, limit: Int = 16) -> [pid_t] {
        let helm = ProcessInfo.processInfo.processIdentifier
        var chain: [pid_t] = []
        var current = pid
        for _ in 0..<limit {
            guard let parent = parentPid(of: current), parent > 1, parent != helm else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }
}
