//! Is a pid still the process a file says it is? A registry row names a pid and the moment
//! it started; a pid alone can be reused by an unrelated process, so the start time is
//! compared too.

/// How far a process's real start may be from the start a file claims. Claude's `startedAt`
/// is taken a moment after exec, and the kernel's start time is whole seconds.
pub const START_TOLERANCE_SECS: u64 = 60;

/// The process is alive, and — when the caller knows when it started — started then.
pub fn alive(pid: u32, claimed_start_ms: Option<u64>) -> bool {
    let Some(started) = started_at_secs(pid) else {
        return false;
    };
    match claimed_start_ms {
        Some(ms) => started.abs_diff(ms / 1000) < START_TOLERANCE_SECS,
        None => true,
    }
}

/// Whether `pid` runs on a controlling terminal. The half of the mailbox claim rule a
/// declared variable cannot fake (`bench_wire::hook::claims_a_mailbox`): a pane's agent holds
/// the pane's tty, while anything started from its tool calls runs without one. A process
/// that does not exist has none.
#[cfg(target_os = "macos")]
pub fn has_terminal(pid: u32) -> bool {
    bsdinfo(pid).is_some_and(|info| info.e_tdev != u32::MAX)
}

/// Linux: field 7 of `/proc/<pid>/stat`, `tty_nr`, is 0 for no controlling terminal.
#[cfg(target_os = "linux")]
pub fn has_terminal(pid: u32) -> bool {
    let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return false;
    };
    let Some(close) = stat.rfind(')') else {
        return false;
    };
    stat[close + 1..]
        .split_whitespace()
        .nth(4)
        .and_then(|t| t.parse::<i64>().ok())
        .is_some_and(|t| t != 0)
}

#[cfg(target_os = "macos")]
fn bsdinfo(pid: u32) -> Option<libc::proc_bsdinfo> {
    let pid = i32::try_from(pid).ok().filter(|p| *p > 0)?;
    // SAFETY: proc_pidinfo writes at most `size` bytes into `info`, a plain C struct, and
    // returns how many it wrote; anything short of a whole struct is treated as absent.
    unsafe {
        let mut info: libc::proc_bsdinfo = std::mem::zeroed();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        let n = libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        );
        (n == size).then_some(info)
    }
}

/// When `pid` started, in seconds since the epoch; `None` when there is no such process.
#[cfg(target_os = "macos")]
pub fn started_at_secs(pid: u32) -> Option<u64> {
    bsdinfo(pid).map(|info| info.pbi_start_tvsec)
}

/// Linux (the daemon's CI): field 22 of `/proc/<pid>/stat` is the start in clock ticks after
/// boot, and `/proc/stat`'s `btime` is the boot in epoch seconds.
#[cfg(target_os = "linux")]
pub fn started_at_secs(pid: u32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // The command name is parenthesised and may itself contain spaces or ')'.
    let after_comm = &stat[stat.rfind(')')? + 1..];
    let ticks: u64 = after_comm.split_whitespace().nth(19)?.parse().ok()?;
    let boot: u64 = std::fs::read_to_string("/proc/stat")
        .ok()?
        .lines()
        .find_map(|l| l.strip_prefix("btime "))?
        .trim()
        .parse()
        .ok()?;
    // SAFETY: sysconf has no preconditions.
    let per_sec = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let per_sec = u64::try_from(per_sec).ok().filter(|t| *t > 0)?;
    Some(boot + ticks / per_sec)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_process_is_alive_at_its_own_start_and_not_at_a_start_a_day_away() {
        let me = std::process::id();
        let started = started_at_secs(me).expect("the test process exists");
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(started <= now && now - started < 3600, "{started} vs {now}");
        assert!(alive(me, Some(started * 1000)));
        assert!(
            !alive(me, Some((started - 86_400) * 1000)),
            "a reused pid is not the process the file named"
        );
        assert!(!alive(0, None));
        assert!(!alive(u32::MAX, None));
    }

    /// A child moved into its own session has no controlling terminal, whatever the test
    /// runner has; no process at all has none either. The terminal-holding side needs a real
    /// pty and is covered end to end in the conformance suite.
    #[test]
    fn a_detached_process_and_no_process_have_no_terminal() {
        use std::os::unix::process::CommandExt;
        let mut cmd = std::process::Command::new("sleep");
        cmd.arg("30");
        // SAFETY: setsid is async-signal-safe and touches nothing of the parent's.
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        let mut child = cmd.spawn().expect("spawn sleep");
        let detached = has_terminal(child.id());
        let _ = child.kill();
        let _ = child.wait();
        assert!(!detached, "a new session has no controlling terminal");
        assert!(!has_terminal(0));
        assert!(!has_terminal(u32::MAX));
    }
}
