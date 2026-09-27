//! Each session's VT engine (M5b PR 4): one thread owns the session's libghostty-vt terminal
//! and is the only place its output goes. The drain thread hands it what the program wrote; it
//! writes that to the terminal, then to the viewer, so the two see the same bytes in the same
//! order. Attach, resize and screen reads come to the same thread as messages, so each lands
//! between two chunks of output and never inside one.
//!
//! - **A viewer that attaches is shown the screen, not the history of bytes.** The terminal is
//!   formatted as the sequences that redraw it, followed by any sequence the program has begun
//!   and not finished. The terminal queries in the history are not replayed, so a new Ghostty
//!   does not answer them again into the program.
//! - **Queries are answered by whoever the program is talking to.** While a viewer is attached,
//!   its Ghostty answers; while none is, the engine does, as Ghostty would.
//! - **A frame is never cut.** An attach or a screen read inside a synchronized update (mode
//!   2026) waits for the update to end, for at most a second, as Ghostty's own renderer does.

use std::fs::File;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::process::Child;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bench_vt::{Format, Mode, Terminal};

use crate::Notice;

/// History kept per session, in bytes of libghostty's own pages.
pub const SCROLLBACK_BYTES: usize = 16 * 1024 * 1024;
/// How long an attach waits for a synchronized update to end: Ghostty's own limit.
const HOLD_LIMIT: Duration = Duration::from_secs(1);
/// Chunks of output in flight to the engine. Bounded, so a program that writes faster than the
/// engine reads waits on its pty, as it would on any terminal: the VT-engine spike measured
/// unbounded queues at 4-6 GB.
pub const QUEUE: usize = 64;

/// What a viewer needs to know about a session's terminal, read at a settled frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screen {
    pub rows: u16,
    pub cols: u16,
    /// (column, row) from zero.
    pub cursor: (u16, u16),
    pub cursor_visible: bool,
    pub title: String,
    pub pwd: String,
    pub alt_screen: bool,
    pub bracketed_paste: bool,
    /// One string per row; with history, the rows above the screen come first.
    pub lines: Vec<String>,
}

pub(crate) type Attached = Arc<Mutex<Option<(u64, UnixStream)>>>;

pub(crate) enum Msg {
    Output(Vec<u8>),
    /// The program's side of the pty closed: every byte it wrote is in the queue ahead of this.
    Closed,
    Attach {
        stream: UnixStream,
        generation: u64,
        rows: u16,
        cols: u16,
        reply: SyncSender<Result<(), String>>,
    },
    Resize {
        rows: u16,
        cols: u16,
        reply: SyncSender<Result<(), String>>,
    },
    Screen {
        history: bool,
        reply: SyncSender<Result<Screen, String>>,
    },
}

/// Everything the engine thread shares with its session.
pub(crate) struct Shared {
    pub id: String,
    pub master: Arc<Mutex<File>>,
    pub attached: Attached,
    pub child: Arc<Mutex<Child>>,
    pub exited: Arc<AtomicBool>,
    pub notices: Sender<Notice>,
}

/// A request that must see a finished frame, waiting for the program's update to end.
enum Waiter {
    Attach {
        stream: UnixStream,
        generation: u64,
        reply: SyncSender<Result<(), String>>,
    },
    Screen {
        history: bool,
        reply: SyncSender<Result<Screen, String>>,
    },
}

/// Start the engine thread for a session of `cols` × `rows`, once its terminal exists.
pub(crate) fn start(shared: Shared, rows: u16, cols: u16, rx: Receiver<Msg>) -> Result<(), String> {
    let (ready, started) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        // The terminal is made on this thread and never leaves it (`Terminal` is `!Send`).
        match Terminal::new(cols, rows, SCROLLBACK_BYTES) {
            Ok(term) => {
                let _ = ready.send(Ok(()));
                Engine {
                    term,
                    shared,
                    waiting: Vec::new(),
                    deadline: None,
                }
                .run(&rx);
            }
            Err(e) => {
                let _ = ready.send(Err(e.to_string()));
            }
        }
    });
    started
        .recv()
        .unwrap_or_else(|_| Err("the terminal engine did not start".into()))
}

struct Engine {
    term: Terminal,
    shared: Shared,
    /// Served, in order, once the screen is a finished frame or `deadline` passes.
    waiting: Vec<Waiter>,
    deadline: Option<Instant>,
}

impl Engine {
    fn run(mut self, rx: &Receiver<Msg>) {
        loop {
            let msg = match self.deadline {
                Some(deadline) => {
                    match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                        Ok(m) => Some(m),
                        Err(RecvTimeoutError::Timeout) => None,
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                }
                None => match rx.recv() {
                    Ok(m) => Some(m),
                    Err(_) => return,
                },
            };
            if let Some(msg) = msg {
                self.handle(msg);
            }
            self.serve_waiting();
        }
    }

    fn handle(&mut self, msg: Msg) {
        match msg {
            Msg::Output(bytes) => self.output(&bytes),
            Msg::Closed => self.closed(),
            Msg::Attach {
                stream,
                generation,
                rows,
                cols,
                reply,
            } => {
                if self.shared.exited.load(Ordering::SeqCst) {
                    let _ = reply.send(Err("the session has ended".into()));
                    return;
                }
                if rows > 0 && cols > 0 {
                    let _ = self.resize(rows, cols);
                }
                self.wait(Waiter::Attach {
                    stream,
                    generation,
                    reply,
                });
            }
            Msg::Resize { rows, cols, reply } => {
                let _ = reply.send(self.resize(rows, cols));
            }
            Msg::Screen { history, reply } => self.wait(Waiter::Screen { history, reply }),
        }
    }

    fn wait(&mut self, waiter: Waiter) {
        self.waiting.push(waiter);
        self.deadline
            .get_or_insert_with(|| Instant::now() + HOLD_LIMIT);
    }

    /// The engine first, then the viewer: what is relayed is what the engine has seen.
    fn output(&mut self, bytes: &[u8]) {
        self.term.write(bytes);
        let replies = self.term.take_replies();
        let mut guard = self.shared.attached.lock().unwrap();
        match guard.as_mut() {
            Some((_, stream)) => {
                if stream.write_all(bytes).is_err() {
                    let _ = stream.shutdown(std::net::Shutdown::Both);
                    *guard = None;
                    let _ = self.shared.notices.send(Notice::Detached {
                        session: self.shared.id.clone(),
                    });
                }
            }
            // Nobody else will answer: the engine does, as the viewer's Ghostty would have.
            None if !replies.is_empty() => {
                let _ = self.shared.master.lock().unwrap().write_all(&replies);
            }
            None => {}
        }
    }

    /// The pty and the engine change size together, so output after this is laid out at the
    /// size both agree on.
    fn resize(&mut self, rows: u16, cols: u16) -> Result<(), String> {
        if rows == 0 || cols == 0 {
            return Err(format!("a terminal is at least 1x1, not {rows}x{cols}"));
        }
        self.term.resize(cols, rows).map_err(|e| e.to_string())?;
        crate::pty::resize(&self.shared.master.lock().unwrap(), rows, cols)
            .map_err(|e| format!("resize: {e}"))
    }

    fn serve_waiting(&mut self) {
        let Some(deadline) = self.deadline else {
            return;
        };
        if self.term.held() && Instant::now() < deadline {
            return;
        }
        if self.term.held() {
            // A program that never ends its update does not keep the viewer out.
            let _ = self.term.release_hold();
        }
        self.deadline = None;
        for waiter in std::mem::take(&mut self.waiting) {
            match waiter {
                Waiter::Attach {
                    stream,
                    generation,
                    reply,
                } => {
                    let _ = reply.send(self.install(stream, generation));
                }
                Waiter::Screen { history, reply } => {
                    let _ = reply.send(self.screen(history));
                }
            }
        }
    }

    /// Redraw the screen in the viewer, then make it the viewer: nothing between the two is
    /// lost or doubled, because no output is handled until this returns.
    fn install(&mut self, mut stream: UnixStream, generation: u64) -> Result<(), String> {
        let mut replay = b"\x1b[H\x1b[2J".to_vec();
        // The formatter redraws the screen, not the window: the title the program set comes
        // back as its own sequence, or the pane's tab would lose it until the program set it again.
        let title = self.term.title().replace(|c: char| c.is_control(), "");
        if !title.is_empty() {
            replay.extend(format!("\x1b]2;{title}\x1b\\").into_bytes());
        }
        replay.extend(self.term.format(Format::Vt).map_err(|e| e.to_string())?);
        replay.extend(self.term.continuation().unwrap_or_default());
        stream
            .write_all(&replay)
            .map_err(|e| format!("replay: {e}"))?;
        let mut guard = self.shared.attached.lock().unwrap();
        if let Some((_, old)) = guard.take() {
            let _ = old.shutdown(std::net::Shutdown::Both);
        }
        *guard = Some((generation, stream));
        Ok(())
    }

    fn screen(&mut self, history: bool) -> Result<Screen, String> {
        let (cols, rows) = self.term.size();
        Ok(Screen {
            rows,
            cols,
            cursor: self.term.cursor(),
            cursor_visible: self.term.cursor_visible(),
            title: self.term.title(),
            pwd: self.term.pwd(),
            alt_screen: self.term.alt_screen(),
            bracketed_paste: self.term.mode(Mode::BRACKETED_PASTE),
            lines: self.term.lines(history).map_err(|e| e.to_string())?,
        })
    }

    /// Whoever was waiting for a frame is answered with the last one; an attach is refused.
    fn closed(&mut self) {
        self.deadline = None;
        for waiter in std::mem::take(&mut self.waiting) {
            match waiter {
                Waiter::Attach { reply, .. } => {
                    let _ = reply.send(Err("the session has ended".into()));
                }
                Waiter::Screen { history, reply } => {
                    let _ = reply.send(self.screen(history));
                }
            }
        }
        finish(&self.shared);
    }
}

/// Reap at the moment of exit (PR #341 review, R2): the pty's EOF means the child is gone or
/// going, so no session leaves a zombie for `close` to find. The viewer sees EOF after the last
/// byte, rather than sitting on a relay nothing will write to again.
fn finish(shared: &Shared) {
    let _ = shared.child.lock().unwrap().wait();
    shared.exited.store(true, Ordering::SeqCst);
    if let Some((_, stream)) = shared.attached.lock().unwrap().take() {
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }
    let _ = shared.notices.send(Notice::Exited {
        session: shared.id.clone(),
    });
}
