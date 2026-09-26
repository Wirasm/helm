//! The pty itself: open one, start a process on it, resize it, end the process. rustix
//! for the pty and process calls, `std::process::Command` for fork/exec, and `libc`
//! only for the signal reset, which rustix has no stable API for.
//!
//! What the spawned process gets, and why each part is here:
//! - **Its own session, with the pty as controlling terminal** (`setsid`, then
//!   `TIOCSCTTY` on its stdin). Without that there is no SIGWINCH on resize, no
//!   `/dev/tty`, and no job control for a shell.
//! - **Default signal dispositions and an empty mask.** An ignored signal survives exec,
//!   and a daemon started as `(benchd &)` from a script has SIGINT and SIGQUIT ignored.
//!   std resets only SIGPIPE and passes the parent's mask through unchanged.
//! - **The daemon's environment**, plus `TERM` and whatever the caller declares.
//!
//! The `pre_exec` closure runs between fork and exec in a multithreaded process, so it
//! makes only async-signal-safe calls and never allocates. Every fd benchd opens is
//! close-on-exec (std and rustix open them that way, and the master is marked as soon
//! as it exists), so nothing else needs closing in the child.

use rustix::fd::{BorrowedFd, OwnedFd};
use rustix::fs::{Mode, OFlags};
use rustix::io::{FdFlags, fcntl_setfd};
use rustix::process::{Pid, Signal, ioctl_tiocsctty, kill_process, setsid};
use rustix::pty::{OpenptFlags, grantpt, openpt, ptsname, unlockpt};
use rustix::termios::{Winsize, tcsetwinsize};
use std::fs::File;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

/// Open a pty sized `rows`×`cols`. The master is returned as a `File`, because
/// reads and writes on it are ordinary file I/O.
fn open(rows: u16, cols: u16) -> std::io::Result<(File, OwnedFd)> {
    let master = openpt(OpenptFlags::RDWR | OpenptFlags::NOCTTY)?;
    fcntl_setfd(&master, FdFlags::CLOEXEC)?;
    grantpt(&master)?;
    unlockpt(&master)?;
    let name = ptsname(&master, Vec::new())?;
    let slave = rustix::fs::open(
        name.as_c_str(),
        OFlags::RDWR | OFlags::NOCTTY | OFlags::CLOEXEC,
        Mode::empty(),
    )?;
    let master = File::from(master);
    resize(&master, rows, cols)?;
    Ok((master, slave))
}

/// Set the window size. The kernel sends SIGWINCH to the pty's foreground process group.
pub(crate) fn resize(master: &File, rows: u16, cols: u16) -> std::io::Result<()> {
    tcsetwinsize(
        master,
        Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        },
    )?;
    Ok(())
}

/// Start `program` on a fresh pty and return the master and the child.
pub(crate) fn spawn(
    program: &str,
    args: &[String],
    cwd: &str,
    env: &[(String, String)],
    rows: u16,
    cols: u16,
) -> std::io::Result<(File, Child)> {
    let (master, slave) = open(rows, cols)?;
    let mut cmd = Command::new(program);
    // Identity benchd's own launcher may carry: a Claude session's inbox and token, its
    // marker, and helm's pane. A session benchd spawns reports as itself (#358), never as
    // whatever started the daemon.
    for inherited in [
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDECODE",
        "HELM_PANE",
    ] {
        cmd.env_remove(inherited);
    }
    cmd.args(args)
        .current_dir(cwd)
        .env("TERM", "xterm-256color")
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave));
    // SAFETY: the closure only calls async-signal-safe functions (sigaction via
    // `signal`, `sigprocmask`, `setsid`, `ioctl`) and allocates nothing.
    unsafe {
        cmd.pre_exec(|| {
            for sig in [
                libc::SIGCHLD,
                libc::SIGHUP,
                libc::SIGINT,
                libc::SIGQUIT,
                libc::SIGTERM,
                libc::SIGALRM,
            ] {
                libc::signal(sig, libc::SIG_DFL);
            }
            let empty: libc::sigset_t = std::mem::zeroed();
            libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
            setsid()?;
            ioctl_tiocsctty(BorrowedFd::borrow_raw(0))?;
            Ok(())
        });
    }
    let child = cmd.spawn()?;
    // `cmd` holds the parent's copies of the slave. They must close now, or the master
    // never reads EOF when the child exits.
    drop(cmd);
    Ok((master, child))
}

/// The end of drain-then-die: SIGHUP, up to 250ms for the process to go by itself,
/// then SIGKILL, then reap. A child that has already been reaped is left alone. Its pid
/// may belong to another process by now, and signalling it is how that process gets
/// killed.
pub(crate) fn hang_up_then_kill(child: &mut Child) {
    if let Ok(Some(_)) = child.try_wait() {
        return;
    }
    let _ = kill_process(Pid::from_child(child), Signal::HUP);
    for attempt in 0..5 {
        if attempt > 0 {
            std::thread::sleep(Duration::from_millis(50));
        }
        if let Ok(Some(_)) = child.try_wait() {
            return;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    /// Run `script` under `/bin/sh` on a pty and return everything it wrote, after it
    /// exits. `after_start` runs against the master once the child is up.
    fn run(script: &str, env: &[(String, String)], after_start: impl FnOnce(&File)) -> String {
        let (master, mut child) = spawn(
            "/bin/sh",
            &["-c".into(), script.into()],
            "/tmp",
            env,
            24,
            80,
        )
        .expect("spawn /bin/sh on a pty");
        let reader = master.try_clone().unwrap();
        let output = std::thread::spawn(move || drain(reader));
        after_start(&master);
        let _ = child.wait();
        output.join().unwrap()
    }

    /// Everything the child writes, up to the pty's EOF (EIO once the slave is gone).
    fn drain(mut master: File) -> String {
        let mut out = Vec::new();
        let mut chunk = [0u8; 4096];
        while let Ok(n) = master.read(&mut chunk) {
            if n == 0 {
                break;
            }
            out.extend_from_slice(&chunk[..n]);
        }
        String::from_utf8_lossy(&out).replace("\r\n", "\n")
    }

    #[test]
    fn the_child_leads_its_own_session_and_the_pty_is_its_controlling_terminal() {
        // `ps` itself is the child, so nothing between the spawn and the check opens the
        // tty (a shell would, and a session leader acquires its terminal by opening it).
        // pgid == pid only after setsid; tpgid is set only with a controlling terminal.
        let (master, mut child) = spawn(
            "/bin/ps",
            &["-x".into(), "-o".into(), "pid=,pgid=,tpgid=".into()],
            "/tmp",
            &[],
            24,
            80,
        )
        .unwrap();
        let pid = child.id().to_string();
        let out = drain(master);
        let _ = child.wait();
        let row: Vec<&str> = out
            .lines()
            .map(|l| l.split_whitespace().collect::<Vec<_>>())
            .find(|cols| cols.first() == Some(&pid.as_str()))
            .unwrap_or_else(|| panic!("no row for {pid} in {out:?}"));
        assert_eq!(row, vec![pid.as_str(); 3], "pid pgid tpgid");
    }

    #[test]
    fn the_child_sees_the_size_it_was_opened_with_and_every_resize() {
        let out = run("stty size; read x; stty size", &[], |master| {
            std::thread::sleep(Duration::from_millis(300));
            resize(master, 50, 132).unwrap();
            (&*master).write_all(b"\n").unwrap();
        });
        assert!(out.contains("24 80"), "opened size not seen: {out:?}");
        assert!(out.contains("50 132"), "resize not seen: {out:?}");
    }

    #[test]
    fn an_ignored_sigint_in_the_daemon_is_not_inherited() {
        // Start from what `(benchd &)` inherits from a script: SIGINT ignored. This is
        // process-wide for the test binary, which is fine: every spawn resets it.
        let previous = unsafe { libc::signal(libc::SIGINT, libc::SIG_IGN) };
        let out = run("kill -INT $$; echo SURVIVED", &[], |_| {});
        unsafe { libc::signal(libc::SIGINT, previous) };
        assert!(
            !out.contains("SURVIVED"),
            "SIGINT stayed ignored in the child: {out:?}"
        );
    }

    #[test]
    fn the_child_gets_the_daemons_environment_plus_term_and_the_declared_extras() {
        let home = std::env::var("HOME").unwrap_or_default();
        let out = run(
            r#"echo "T=$TERM X=$BENCH_TEST_EXTRA H=$HOME""#,
            &[("BENCH_TEST_EXTRA".into(), "declared".into())],
            |_| {},
        );
        assert!(
            out.contains(&format!("T=xterm-256color X=declared H={home}")),
            "{out:?}"
        );
    }

    #[test]
    fn close_hangs_up_first_and_leaves_a_reaped_child_alone() {
        // A process that exits on SIGHUP is gone before the kill; one already reaped is
        // not signalled again (try_wait answers from the cached status).
        let (_master, mut child) = spawn(
            "/bin/sh",
            &["-c".into(), "sleep 30".into()],
            "/tmp",
            &[],
            24,
            80,
        )
        .unwrap();
        let started = std::time::Instant::now();
        hang_up_then_kill(&mut child);
        let status = child.try_wait().unwrap().expect("reaped");
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(status.signal(), Some(libc::SIGHUP), "{status:?}");
        assert!(started.elapsed() < Duration::from_millis(250));
        hang_up_then_kill(&mut child);
    }
}
