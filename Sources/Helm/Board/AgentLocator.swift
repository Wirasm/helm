import Darwin
import Foundation

/// A process's ancestor chain, up to (never past) helm itself.
///
/// The spool's owner join and the canvas-note courier both need to know which pane a
/// process runs under, and an agent is not always the pty's own foreground process — a
/// shell function, `env`, or a wrapper script can sit in between. The walk is the answer
/// to "whose child is this", and it is a syscall per step, not a subprocess.
enum AgentLocator {
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

    /// **The walk stops at helm's own pid, and that is load-bearing.**
    ///
    /// Everything running in a pane is *below* helm. Above helm is whatever launched
    /// it — very often the operator's own agent session, which an unbounded walk then
    /// attributes to "the terminal below". The chat spike hit exactly this and rendered
    /// a 3.4 MB transcript of a different conversation, confidently and
    /// indistinguishably.
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
