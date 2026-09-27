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
//! A session has one viewer, and a second attach takes it over. A pane must not end for that:
//! its session is still running, and a pane whose process has exited has no way back to it. So
//! an `--in-pane` client whose stream closes asks benchd what happened. The session ended: it
//! ends too. Nobody holds the session: it attaches again. Another viewer holds it: it says so in
//! the pane and waits, and attaches again on a key or once that viewer lets go.
//!
//! A pane dragged across the screen resizes its terminal many times a second, and every size the
//! session's pty takes is a SIGWINCH and a full redraw of whatever runs there. So sizes are
//! coalesced: at most one per [`SIZE_EVERY`], plus a trailing one when the changes stop, and the
//! size sent is the one the terminal has when it is sent (#359's resize note).

use crate::{Cli, EXIT_NO_DAEMON, exchange, fail, open, read_response_line};
use bench_wire::attach::AttachFrame;
use bench_wire::{LiveSessions, Response, SessionArgs, Status};
use rustix::termios::tcgetwinsize;
use serde_json::json;
use std::io::{IsTerminal, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

/// The shortest gap between two sizes sent to the session: one frame at 60 Hz.
pub const SIZE_EVERY: Duration = Duration::from_millis(16);

/// How often a displaced pane asks whether the other viewer has let go.
const RECHECK_EVERY: Duration = Duration::from_secs(2);

/// What the relay heard.
enum Heard {
    /// The viewer pressed Ctrl-\ or closed its input.
    Detached,
    /// The daemon closed the stream: the session ended, was closed, or another viewer took it.
    StreamClosed,
    /// A key while displaced: the viewer wants the session back. Never sent to the session.
    Key,
}

/// One attachment: its stream, and the size its pty was last given through it.
struct Attachment {
    stream: UnixStream,
    size: Option<(u16, u16)>,
}

/// Where keys and sizes go: the attachment, or nowhere while the pane is displaced.
type Current = Arc<Mutex<Option<Attachment>>>;

/// Who holds the session, asked after its stream closed.
#[derive(Debug, PartialEq)]
enum Holder {
    /// It ended, or benchd is gone and took it along.
    Gone,
    /// It runs and nobody views it.
    Nobody,
    /// It runs and another viewer has it.
    Another,
}

pub fn run(mut cli: Cli, in_pane: bool) -> i32 {
    let size_changes = hear_size_changes();
    // The request `main` built, read back as its type: a retake sends the same one, resized.
    let mut request: SessionArgs = match serde_json::from_value(cli.args.clone()) {
        Ok(args) => args,
        Err(e) => return fail(&format!("attach args: {e}")),
    };
    let session = request.session.clone();
    let current: Current = Arc::new(Mutex::new(None));
    let (tell, heard) = mpsc::channel();
    let mut saved = None;
    let mut started = false;
    loop {
        let stream = match attach(&cli) {
            Ok(stream) => stream,
            Err(code) => {
                restore(saved);
                return code;
            }
        };
        let down = match stream.try_clone() {
            Ok(sock) => sock,
            Err(_) => {
                restore(saved);
                return fail("cannot clone stream");
            }
        };
        *current.lock().unwrap() = Some(Attachment {
            stream,
            size: request.rows.zip(request.cols),
        });
        if !started {
            started = true;
            if !in_pane {
                eprintln!("bench: attached — Ctrl-\\ detaches");
            }
            saved = raw_mode();
            // Once per client: stdin and the size signal outlive any one attachment.
            relay_up(Arc::clone(&current), !in_pane, tell.clone());
            if let Some(changes) = size_changes {
                follow_size(Arc::clone(&current), changes);
            }
        }
        relay_down(down, tell.clone());

        let ended = loop {
            match heard.recv() {
                Ok(Heard::Key) => continue,
                Ok(ended) => break ended,
                Err(_) => break Heard::Detached,
            }
        };
        current.lock().unwrap().take();
        if !in_pane {
            restore(saved);
            match ended {
                Heard::StreamClosed => eprintln!(
                    "\nbench: the session's stream closed — it ended, was closed, or another attach took it over"
                ),
                _ => eprintln!("\nbench: detached"),
            }
            return 0;
        }
        if !matches!(ended, Heard::StreamClosed) || !wait_to_retake(&cli, &session, &heard) {
            restore(saved);
            return 0;
        }
        // The replay repaints the session on a clean terminal, as on the first attach.
        let mut out = std::io::stdout();
        let _ = out.write_all(b"\x1b[H\x1b[2J\x1b[3J");
        let _ = out.flush();
        if let Some((rows, cols)) = terminal_size() {
            request.rows = Some(rows);
            request.cols = Some(cols);
            cli.args = json!(request);
        }
    }
}

/// Send the attach request and read its answer. `Ok` is a stream the replay follows on.
fn attach(cli: &Cli) -> Result<UnixStream, i32> {
    let (stream, request_line) = open(cli)?;
    if let Err(e) = (&stream).write_all(request_line.as_bytes()) {
        eprintln!("bench: write failed ({e})");
        return Err(EXIT_NO_DAEMON);
    }
    let Some(reply) = read_response_line(&stream) else {
        eprintln!(
            "bench: no answer within {}s",
            bench_wire::CLIENT_READ_TIMEOUT.as_secs()
        );
        return Err(EXIT_NO_DAEMON);
    };
    let response: Response = match serde_json::from_str(&reply) {
        Ok(r) => r,
        Err(e) => {
            return Err(fail(&format!(
                "unreadable response ({e}): {}",
                reply.trim()
            )));
        }
    };
    if response.status != Status::Ok {
        if let Some(reason) = &response.reason {
            eprintln!("bench: {reason}");
        }
        return Err(response.status.exit_code());
    }
    let _ = stream.set_read_timeout(None);
    Ok(stream)
}

/// A displaced pane: whether to attach again. Waits while another viewer holds the session,
/// saying so once, and answers true on a key or once nobody holds it; false once it has ended
/// or the pane's input closed.
fn wait_to_retake(cli: &Cli, session: &str, heard: &mpsc::Receiver<Heard>) -> bool {
    let mut said = false;
    loop {
        match holder(cli, session) {
            Holder::Gone => return false,
            Holder::Nobody => {
                // A stream that drops by itself on a session nobody else holds is attached again
                // at once, but not in a hot loop, and not once the pane's own input has closed:
                // nothing would be left to notice that, and the session's one viewer slot would
                // be held by a client with no terminal.
                std::thread::sleep(Duration::from_millis(200));
                return !matches!(
                    heard.try_recv(),
                    Ok(Heard::Detached) | Err(mpsc::TryRecvError::Disconnected)
                );
            }
            Holder::Another => {
                if !said {
                    said = true;
                    let mut out = std::io::stdout();
                    let _ = write!(
                        out,
                        "\r\n\x1b[7m bench: {session} is still running, but another viewer took it over. Press any key to show it here. \x1b[0m\r\n"
                    );
                    let _ = out.flush();
                }
                match heard.recv_timeout(RECHECK_EVERY) {
                    Ok(Heard::Key) => return true,
                    Ok(Heard::Detached) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                        return false;
                    }
                    Ok(Heard::StreamClosed) | Err(mpsc::RecvTimeoutError::Timeout) => {}
                }
            }
        }
    }
}

/// Ask benchd who holds `session` now. No answer means benchd is gone, and its sessions with it.
fn holder(cli: &Cli, session: &str) -> Holder {
    let ask = Cli {
        verb: "sessions".to_string(),
        args: json!({}),
        root: cli.root.clone(),
        asked: false,
    };
    let Ok(response) = exchange(&ask) else {
        return Holder::Gone;
    };
    let listed = response
        .data
        .and_then(|data| serde_json::from_value::<LiveSessions>(data).ok());
    let Some(entry) = listed.and_then(|l| l.sessions.into_iter().find(|s| s.session == session))
    else {
        return Holder::Gone;
    };
    match (entry.live, entry.attached) {
        (false, _) => Holder::Gone,
        (true, false) => Holder::Nobody,
        (true, true) => Holder::Another,
    }
}

/// Socket → stdout, byte for byte: escape sequences ride through, which is what lets an OSC
/// from the agent reach whatever terminal hosts this client.
fn relay_down(mut sock: UnixStream, tell: mpsc::Sender<Heard>) {
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
        let _ = tell.send(Heard::StreamClosed);
    });
}

/// Write one frame whole to the current attachment. With none, the frame goes nowhere, and
/// `Ok(false)` says so.
fn send(current: &Current, frame: &AttachFrame) -> std::io::Result<bool> {
    let guard = current.lock().unwrap();
    let Some(attachment) = guard.as_ref() else {
        return Ok(false);
    };
    (&attachment.stream)
        .write_all(&frame.encode())
        .map(|()| true)
}

/// Stdin → the current attachment as input frames, until EOF or, when `detach_key` is set,
/// Ctrl-\ (0x1C), which is never forwarded. Keys pressed while displaced go nowhere: they are
/// the viewer asking for the session back.
fn relay_up(current: Current, detach_key: bool, tell: mpsc::Sender<Heard>) {
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
            // A write to a stream the daemon closed fails here; relay_down reports the close.
            if !keys.is_empty()
                && let Ok(false) = send(&current, &AttachFrame::Input(keys.to_vec()))
            {
                let _ = tell.send(Heard::Key);
            }
            if detach_at.is_some() {
                break;
            }
        }
        if let Some(attachment) = current.lock().unwrap().take() {
            let _ = attachment.stream.shutdown(std::net::Shutdown::Both);
        }
        let _ = tell.send(Heard::Detached);
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

/// Keep the session's pty the size of this terminal, through whichever attachment is current;
/// each starts from the size its attach request carried. The [`Coalescer`] decides when a size
/// goes out. A failed send ends nothing: the relay's own threads notice a dead stream.
fn follow_size(current: Current, changes: libc::c_int) {
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
                && let Some(attachment) = current.lock().unwrap().as_mut()
                && attachment.size != Some(now)
            {
                attachment.size = Some(now);
                let frame = AttachFrame::Size {
                    rows: now.0,
                    cols: now.1,
                };
                let _ = (&attachment.stream).write_all(&frame.encode());
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
