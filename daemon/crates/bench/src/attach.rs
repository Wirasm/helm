//! `bench attach <session>`: the response line, then the connection is a relay. The session's
//! output comes down raw, so escape sequences reach the local terminal unchanged. What goes up is
//! framed (`bench_wire::attach`): the keys, raw-mode so Ctrl-C reaches the agent, and this
//! terminal's size whenever it changes. Ctrl-\ detaches.
//!
//! Since M3 this is also what a helm pane runs to show a session, so it behaves like the pane it
//! is in: when the pane is resized the session's pty follows, and when the session ends the
//! client ends too, which is what tells helm the pane's process exited. `--in-pane` is that use:
//! nothing printed of its own, and no detach key, because in a shell Ctrl-\ is SIGQUIT.
//!
//! A pane dragged across the screen resizes its terminal many times a second, and every size the
//! session's pty takes is a SIGWINCH and a full redraw of whatever runs there. So sizes are
//! coalesced: at most one per [`SIZE_EVERY`], plus a trailing one when the changes stop, and the
//! size sent is the one the terminal has when it is sent (#359's resize note).

use crate::{Cli, EXIT_NO_DAEMON, fail, open, read_response_line};
use bench_wire::attach::Frame;
use bench_wire::{Response, Status};
use rustix::termios::tcgetwinsize;
use std::io::{IsTerminal, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

/// The shortest gap between two sizes sent to the session: one frame at 60 Hz.
pub const SIZE_EVERY: Duration = Duration::from_millis(16);

/// Why the relay stopped.
enum Ended {
    /// The viewer pressed Ctrl-\ or closed its input.
    Detached,
    /// The daemon closed the stream: the session ended, was closed, or another viewer took it.
    StreamClosed,
}

pub fn run(cli: Cli, in_pane: bool) -> i32 {
    let size_changes = hear_size_changes();
    let sent_size = match (cli.args["rows"].as_u64(), cli.args["cols"].as_u64()) {
        (Some(r), Some(c)) => Some((r as u16, c as u16)),
        _ => None,
    };
    let (stream, request_line) = match open(&cli) {
        Ok(pair) => pair,
        Err(code) => return code,
    };
    if let Err(e) = (&stream).write_all(request_line.as_bytes()) {
        eprintln!("bench: write failed ({e})");
        return EXIT_NO_DAEMON;
    }
    let Some(reply) = read_response_line(&stream) else {
        eprintln!(
            "bench: no answer within {}s",
            bench_wire::CLIENT_READ_TIMEOUT.as_secs()
        );
        return EXIT_NO_DAEMON;
    };
    let response: Response = match serde_json::from_str(&reply) {
        Ok(r) => r,
        Err(e) => return fail(&format!("unreadable response ({e}): {}", reply.trim())),
    };
    if response.status != Status::Ok {
        if let Some(reason) = &response.reason {
            eprintln!("bench: {reason}");
        }
        return response.status.exit_code();
    }
    if !in_pane {
        eprintln!("bench: attached — Ctrl-\\ detaches");
    }
    let _ = stream.set_read_timeout(None);

    let saved = raw_mode();
    let (done, ended) = mpsc::channel();
    let down = match stream.try_clone() {
        Ok(sock) => sock,
        Err(_) => return fail("cannot clone stream"),
    };
    // Two threads send frames (keys, sizes); one frame is written whole under this lock.
    let up = Arc::new(Mutex::new(stream));
    relay_down(down, done.clone());
    relay_up(Arc::clone(&up), !in_pane, done);
    if let (Some(changes), Some(sent)) = (size_changes, sent_size) {
        follow_size(up, changes, sent);
    }

    let ended = ended.recv().unwrap_or(Ended::Detached);
    restore(saved);
    if !in_pane {
        match ended {
            Ended::Detached => eprintln!("\nbench: detached"),
            Ended::StreamClosed => eprintln!(
                "\nbench: the session's stream closed — it ended, was closed, or another attach took it over"
            ),
        }
    }
    0
}

/// Socket → stdout, byte for byte: escape sequences ride through, which is what lets an OSC
/// from the agent reach whatever terminal hosts this client.
fn relay_down(mut sock: UnixStream, done: mpsc::Sender<Ended>) {
    std::thread::spawn(move || {
        let mut out = std::io::stdout();
        let mut chunk = [0u8; 8192];
        loop {
            match sock.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out.write_all(&chunk[..n]).is_err() {
                        break;
                    }
                    let _ = out.flush();
                }
            }
        }
        let _ = done.send(Ended::StreamClosed);
    });
}

fn send(up: &Mutex<UnixStream>, frame: &Frame) -> std::io::Result<()> {
    let sock = up.lock().unwrap();
    (&*sock).write_all(&frame.encode())
}

/// Stdin → socket as input frames, until EOF or, when `detach_key` is set, Ctrl-\ (0x1C), which
/// is never forwarded.
fn relay_up(up: Arc<Mutex<UnixStream>>, detach_key: bool, done: mpsc::Sender<Ended>) {
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut chunk = [0u8; 4096];
        loop {
            let n = match stdin.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            let detach_at = chunk[..n].iter().position(|&b| detach_key && b == 0x1c);
            let keys = &chunk[..detach_at.unwrap_or(n)];
            if !keys.is_empty() && send(&up, &Frame::Input(keys.to_vec())).is_err() {
                break;
            }
            if detach_at.is_some() {
                break;
            }
        }
        let _ = up.lock().unwrap().shutdown(std::net::Shutdown::Both);
        let _ = done.send(Ended::Detached);
    });
}

/// When sizes may go out, given when the terminal changed. Pure, so the rate is a unit test
/// rather than a timing race.
#[derive(Debug)]
struct Coalescer {
    every: Duration,
    last: Option<Instant>,
    pending: bool,
}

impl Coalescer {
    fn new(every: Duration) -> Coalescer {
        Coalescer {
            every,
            last: None,
            pending: false,
        }
    }

    /// The terminal changed size.
    fn changed(&mut self) {
        self.pending = true;
    }

    /// Whether a size goes out now. A change is sent at once when the last send is at least
    /// `every` ago, and otherwise held until then: that held one is the trailing size.
    fn due(&mut self, now: Instant) -> bool {
        let ready = self
            .last
            .is_none_or(|last| now.saturating_duration_since(last) >= self.every);
        if self.pending && ready {
            self.pending = false;
            self.last = Some(now);
            return true;
        }
        false
    }

    /// How long to wait for the next change: for ever with nothing held, else until it is due.
    fn wait(&self, now: Instant) -> Option<Duration> {
        self.pending.then(|| {
            self.last.map_or(Duration::ZERO, |last| {
                self.every
                    .saturating_sub(now.saturating_duration_since(last))
            })
        })
    }
}

/// The write end of the pipe the SIGWINCH handler pokes, or -1 before there is one.
static WINCH_PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_winch(_: libc::c_int) {
    let fd = WINCH_PIPE.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: write(2) is async-signal-safe; the fd is non-blocking, so a full pipe (a
        // change already waiting to be read) drops this byte instead of blocking the handler.
        unsafe { libc::write(fd, [1u8].as_ptr().cast(), 1) };
    }
}

/// Hear this terminal change size: SIGWINCH writes a byte into a pipe, and this answers the
/// pipe's read end. Installed before the attach request is sent, because a change between the
/// size that request carries and a handler existing would otherwise be lost: SIGWINCH is ignored
/// by default.
fn hear_size_changes() -> Option<libc::c_int> {
    terminal_size()?;
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: pipe(2) fills two fds; fcntl only sets flags on the fd it is given.
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            return None;
        }
        for fd in fds {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
        libc::fcntl(fds[1], libc::F_SETFL, libc::O_NONBLOCK);
    }
    WINCH_PIPE.store(fds[1], Ordering::Relaxed);
    // SAFETY: the handler only calls write(2) on an fd it loads atomically.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_winch as *const () as usize;
        action.sa_flags = libc::SA_RESTART;
        libc::sigaction(libc::SIGWINCH, &action, std::ptr::null_mut());
    }
    Some(fds[0])
}

/// Keep the session's pty the size of this terminal, starting from `sent`, the size the attach
/// request carried. The [`Coalescer`] decides when a size goes out. A failed send ends nothing:
/// the relay's own threads notice a dead stream.
fn follow_size(up: Arc<Mutex<UnixStream>>, changes: libc::c_int, mut sent: (u16, u16)) {
    let read_end = changes;
    std::thread::spawn(move || {
        let mut sizes = Coalescer::new(SIZE_EVERY);
        // Whatever changed while the attach was being answered is checked at once.
        sizes.changed();
        loop {
            let timeout = sizes.wait(Instant::now()).map_or(-1, |d| {
                i32::try_from(d.as_micros().div_ceil(1000)).unwrap_or(i32::MAX)
            });
            let mut poll = libc::pollfd {
                fd: read_end,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: one valid pollfd; the drain reads into a local buffer.
            if unsafe { libc::poll(&mut poll, 1, timeout) } > 0 {
                let mut drain = [0u8; 64];
                unsafe { libc::read(read_end, drain.as_mut_ptr().cast(), drain.len()) };
                sizes.changed();
            }
            if sizes.due(Instant::now())
                && let Some(now) = terminal_size()
                && now != sent
            {
                sent = now;
                let _ = send(
                    &up,
                    &Frame::Size {
                        rows: now.0,
                        cols: now.1,
                    },
                );
            }
        }
    });
}

/// The terminal's size, rows then columns, when stdout is one.
pub fn terminal_size() -> Option<(u16, u16)> {
    let out = std::io::stdout();
    if !out.is_terminal() {
        return None;
    }
    let size = tcgetwinsize(&out).ok()?;
    (size.ws_row > 0 && size.ws_col > 0).then_some((size.ws_row, size.ws_col))
}

/// Raw local terminal for the duration. `stty -g` gives a restore token, so whatever the mode
/// was is what comes back.
fn raw_mode() -> Option<String> {
    if !std::io::stdin().is_terminal() {
        return None;
    }
    let saved = std::process::Command::new("stty")
        .arg("-g")
        .stdin(std::process::Stdio::inherit())
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    let _ = std::process::Command::new("stty")
        .args(["raw", "-echo"])
        .stdin(std::process::Stdio::inherit())
        .status();
    saved
}

fn restore(saved: Option<String>) {
    if let Some(token) = saved {
        let _ = std::process::Command::new("stty")
            .arg(token)
            .stdin(std::process::Stdio::inherit())
            .status();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: Duration = Duration::from_millis(1);

    #[test]
    fn a_drag_sends_at_most_one_size_per_interval_and_always_the_last() {
        // A second of dragging: the terminal changes size every 2 ms. The loop is the one
        // `follow_size` runs, with time stepped instead of slept.
        let start = Instant::now();
        let mut sizes = Coalescer::new(SIZE_EVERY);
        let mut sent = Vec::new();
        let mut now = start;
        let changes_end = start + Duration::from_secs(1);
        while now < changes_end + SIZE_EVERY * 2 {
            if now < changes_end && (now - start).as_millis().is_multiple_of(2) {
                sizes.changed();
            }
            if sizes.due(now) {
                sent.push(now - start);
            }
            now += MS;
        }
        // One per 16 ms across the second (0, 16, … 992 ms), then the trailing one.
        assert!(
            sent.len() <= 1000_usize.div_ceil(16) + 1,
            "{} sizes for a second of dragging",
            sent.len()
        );
        for pair in sent.windows(2) {
            assert!(pair[1] - pair[0] >= SIZE_EVERY, "{pair:?}");
        }
        let last_change = Duration::from_millis(998);
        assert!(
            *sent.last().unwrap() >= last_change,
            "the size after the last change goes out: last sent at {:?}",
            sent.last()
        );
    }

    #[test]
    fn a_single_change_goes_out_at_once_and_a_quick_second_waits_for_the_interval() {
        let t0 = Instant::now();
        let mut sizes = Coalescer::new(SIZE_EVERY);
        assert_eq!(sizes.wait(t0), None, "nothing held: wait for a change");
        sizes.changed();
        assert!(sizes.due(t0), "the first change is not delayed");
        sizes.changed();
        assert!(!sizes.due(t0 + 5 * MS));
        assert_eq!(sizes.wait(t0 + 5 * MS), Some(11 * MS));
        assert!(sizes.due(t0 + 16 * MS), "the trailing size");
        assert!(!sizes.due(t0 + 40 * MS), "nothing left to send");
    }
}
