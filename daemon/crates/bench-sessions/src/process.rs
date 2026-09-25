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

/// When `pid` started, in seconds since the epoch; `None` when there is no such process.
#[cfg(target_os = "macos")]
pub fn started_at_secs(pid: u32) -> Option<u64> {
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
        (n == size).then_some(info.pbi_start_tvsec)
    }
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
}
