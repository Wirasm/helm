//! benchd — the bench daemon. M0 (skeleton and isolation), M5a (the pty core), mail and
//! the shared browser.
//!
//! What exists: a suite-aware record root, an append-only event log that is the single
//! source of truth, and one unix socket answering fifteen verbs — status/events/stop from
//! M0; spawn/sessions/attach/close/resume from M5a: daemon-owned ptys hosting full
//! interactive agent TUIs, viewed through a dtach-grade raw relay (`bench attach`);
//! mail/send, mail/list and mail/read, with the wake reactor pasting a notice into an
//! idle recipient's pty (#342); and browser/start, browser/status, browser/stop and
//! browser/setup — one supervised Chrome per root whose endpoint agents and helm connect
//! to directly (#350).
//! What deliberately does not exist yet: the bench document, attention and taps (see
//! `docs/future-planning/bench-roadmap.md` and tracking issue #362). Each arrives as new
//! event kinds plus new verbs over this same spine, never as a second channel beside it.
//!
//! Design rules this file carries (argued in ../../direction.md):
//! - **Bench-visible means logged.** Every mutation appends an event before the
//!   response that reports it; readers project from the log, never from daemon memory
//!   alone. Sessions exiting, attaching, detaching — all events.
//! - **One door.** The socket is the only way in. `attach` upgrades a connection to a
//!   raw byte relay AFTER an ordinary response line — same door, one more room.
//! - **Refuse loudly.** Unknown verbs, malformed requests, oversized lines, a corrupt
//!   log, an off-allowlist agent: each is a named refusal, never a silent default.
//!
//! Connections are handled on a thread each; the shared core (log + session registry)
//! sits behind one mutex held only for map and log operations — never across a ready
//! wait, a prompt delivery, or an attach pump.

mod layout;
mod sessions;

use bench_browser::{Browser, ExitInfo, LaunchError, Launched, default_candidates};
use bench_session::{AgentKind, Notice, Session, SpawnSpec, TEST_AGENT_ENV, mint_session_id};
use bench_wire::{
    BrowserMode, DAEMON_IO_TIMEOUT, EVENTS_LOG_FORMAT, EVENTS_LOG_VERSION, Event, KNOWN_VERBS,
    MAX_REQUEST_BYTES, MailListArgs, MailReadArgs, MailSendArgs, OPERATOR_HANDLE, READY_WAIT,
    Request, Response, SessionArgs, SpawnArgs, Status, SuiteName, Verb, browser_endpoint_path,
    check_socket_path, events_path, resolve_root, socket_path, validate_handle,
};
use bench_wire::{DOCUMENT_CHANGED, Frame};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn main() {
    process::exit(run());
}

fn usage() -> &'static str {
    "usage: benchd [--suite <name>]\n\
     env:   BENCH_SUITE   suite name (the --suite flag wins)\n\
     \x20      BENCH_DIR     record root override (wins over suite; what tests claim into)\n\
     exit:  0 clean stop · 3 refused to start · 4 failed"
}

fn run() -> i32 {
    let mut args = std::env::args().skip(1);
    let mut suite_flag: Option<String> = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--suite" => match args.next() {
                Some(v) => suite_flag = Some(v),
                None => return refuse_start("--suite needs a name"),
            },
            "--help" | "-h" => {
                println!("{}", usage());
                return 0;
            }
            other => return refuse_start(&format!("unknown argument {other:?}\n{}", usage())),
        }
    }

    let suite_raw = suite_flag.or_else(|| std::env::var("BENCH_SUITE").ok());
    let suite = match suite_raw.as_deref() {
        Some(raw) => match SuiteName::validate(raw) {
            Ok(s) => Some(s),
            // A name that cannot isolate must stop the launch, never fall back to the
            // operator's live root (#86).
            Err(why) => return refuse_start(&why),
        },
        None => None,
    };

    let home = match std::env::var("HOME") {
        Ok(h) => PathBuf::from(h),
        Err(_) => return fail_start("HOME is not set; benchd cannot resolve a record root"),
    };
    let bench_dir = std::env::var("BENCH_DIR").ok();
    let root = resolve_root(bench_dir.as_deref(), suite.as_ref(), &home);

    match boot(root, suite, home) {
        Ok(code) => code,
        Err(StartError::Refused(why)) => refuse_start(&why),
        Err(StartError::Failed(why)) => fail_start(&why),
    }
}

// Pre-socket exits derive from the same enum as socket-answered ones (R3).
fn refuse_start(why: &str) -> i32 {
    eprintln!("benchd: refusing to start: {why}");
    Status::Refused.exit_code()
}

fn fail_start(why: &str) -> i32 {
    eprintln!("benchd: {why}");
    Status::Error.exit_code()
}

enum StartError {
    Refused(String),
    Failed(String),
}

struct RepairNote {
    quarantine: PathBuf,
    dropped_bytes: usize,
}

/// Mail waiting to wake its recipient. The reactor drains this — mail/sent events in,
/// pastes out — and the loop cap lives HERE, in the courier, because only the thing
/// that causes a wake can count wakes (helm #320's measurement: a hook cannot).
struct PendingWake {
    handle: String,
    mail_id: String,
    from: String,
    capped_logged: bool,
}

/// A token bucket per recipient: burst of WAKE_BURST, refilling one per minute. A
/// two-agent ping-pong self-throttles instead of burning until the money runs out.
struct WakeBucket {
    tokens: f64,
    last: Instant,
}

const WAKE_BURST: f64 = 6.0;
const WAKE_REFILL_PER_SEC: f64 = 1.0 / 60.0;
/// The idle gate: the pty must have been quiet this long before a paste. The crude
/// form the mail spike proved; taps refine the judgement later, not the plumbing.
const WAKE_IDLE_GATE: Duration = Duration::from_secs(2);

/// Read the log with byte offsets. A clean log returns the next seq. An unreadable
/// line refuses — unless it is the LAST non-empty line, which is an interrupted append:
/// quarantine the tail, truncate back to the last good byte, and report the repair (R1).
/// The scan also finds the seq of the last `bench/changed`, so boot can tell a `bench.json`
/// that is behind the log (`layout::load`).
struct Scanned {
    next_seq: u64,
    repair: Option<RepairNote>,
    last_document_change: Option<u64>,
}

fn scan_log(events: &PathBuf) -> Result<Scanned, StartError> {
    let bytes = match fs::read(events) {
        Ok(b) => b,
        Err(_) => {
            return Ok(Scanned {
                next_seq: 0,
                repair: None,
                last_document_change: None,
            });
        }
    };
    let mut last_document_change = None;
    let text = String::from_utf8_lossy(&bytes);
    let mut seq = 0u64;
    let mut offset = 0usize;
    let chunks: Vec<&str> = text.split_inclusive('\n').collect();
    for (i, chunk) in chunks.iter().enumerate() {
        let line = chunk.trim_end_matches('\n');
        if line.trim().is_empty() {
            offset += chunk.len();
            continue;
        }
        match serde_json::from_str::<Event>(line) {
            Ok(ev) => {
                seq = ev.seq + 1;
                offset += chunk.len();
                if ev.kind == DOCUMENT_CHANGED {
                    last_document_change = Some(ev.seq);
                }
            }
            Err(e) => {
                let rest_is_empty = chunks[i + 1..].iter().all(|c| c.trim().is_empty());
                if !rest_is_empty {
                    return Err(StartError::Refused(format!(
                        "event log {} line {} is not a readable event ({e}) — refusing to append after history this daemon cannot read",
                        events.display(),
                        i + 1
                    )));
                }
                let epoch = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                let quarantine = events.with_file_name(format!("events.jsonl.torn-{epoch}"));
                let dropped = &bytes[offset..];
                fs::write(&quarantine, dropped).map_err(|err| {
                    StartError::Failed(format!("cannot quarantine torn tail: {err}"))
                })?;
                let file = OpenOptions::new().write(true).open(events).map_err(|err| {
                    StartError::Failed(format!("cannot open log for repair: {err}"))
                })?;
                file.set_len(offset as u64).map_err(|err| {
                    StartError::Failed(format!("cannot truncate torn tail: {err}"))
                })?;
                eprintln!(
                    "benchd: event log {} ended in a torn line ({e}); {} byte(s) quarantined to {} and the log truncated to its last whole event",
                    events.display(),
                    dropped.len(),
                    quarantine.display()
                );
                return Ok(Scanned {
                    next_seq: seq,
                    repair: Some(RepairNote {
                        quarantine,
                        dropped_bytes: dropped.len(),
                    }),
                    last_document_change,
                });
            }
        }
    }
    Ok(Scanned {
        next_seq: seq,
        repair: None,
        last_document_change,
    })
}

/// The shared core: the log and the session registry, behind one mutex held only for
/// map and log operations.
struct Core {
    root: PathBuf,
    suite: Option<SuiteName>,
    log: File,
    next_seq: u64,
    started_at: String,
    booted: Instant,
    sessions: HashMap<String, Arc<Session>>,
    next_session: u64,
    next_mail: u64,
    pending_wakes: Vec<PendingWake>,
    wake_tokens: HashMap<String, WakeBucket>,
    notices: mpsc::Sender<Notice>,
    /// Whose Playwright cache the default browser comes from.
    home: PathBuf,
    browser: Option<Arc<Browser>>,
    /// True between a `browser/start` and a `browser/stop`: a crash restarts only a
    /// browser somebody still wants.
    browser_wanted: bool,
    /// Restarts inside the current window — the crash-loop cap.
    browser_restarts: Vec<Instant>,
    /// The bench document (M4): what `bench.json` holds, and the seq that produced it.
    bench: layout::BenchState,
    /// The hosted-sessions record and the dismissals (#384).
    session_records: sessions::SessionRecords,
    /// `events --follow` connections, each with its own bounded queue and writer thread.
    /// A frame is handed over here and written there, **never under this mutex**: a 16 KB
    /// frame is larger than a unix socket's send buffer, so one follower that stopped
    /// reading would otherwise freeze every verb (spike S1). A full queue drops the follower
    /// — safe, because reconnecting returns the whole document.
    followers: Vec<mpsc::SyncSender<Arc<str>>>,
    /// Set by every append; cleared by the flusher, which fsyncs off this mutex (see
    /// `Flusher`).
    unflushed: Arc<AtomicBool>,
}

/// How many frames a follower may fall behind before it is dropped.
const FOLLOWER_QUEUE: usize = 256;

/// How often the flusher fsyncs the log. Spike S1 measured `F_FULLFSYNC` as the only slow
/// stage between a keystroke and helm's redraw: 17.1 ms p99 per event inline, 5.4 ms p99
/// with a 50 ms flush on its own thread. The trade, approved: a power loss or kernel panic
/// can lose up to this much of the log; a benchd crash loses nothing, because every event is
/// written and flushed to the kernel before the response that reports it.
const FLUSH_EVERY: Duration = Duration::from_millis(50);

/// A crashed browser is restarted at most this many times inside this window; the next
/// crash is logged as `browser/gave-up` and the browser stays down until a
/// `browser/start`. A profile that crashes Chromium on every launch must not become a
/// launch loop nobody is watching.
const BROWSER_RESTART_CAP: usize = 3;
const BROWSER_RESTART_WINDOW: Duration = Duration::from_secs(60);

/// Held across a whole start or stop — never the core lock, which a ready wait must
/// not hold — so two starts serialize and the second finds the first's browser.
static BROWSER_LIFECYCLE: Mutex<()> = Mutex::new(());

impl Core {
    fn append(&mut self, kind: &str, data: Value) -> Result<(), String> {
        self.append_event(kind, data, None).map(|_| ())
    }

    /// Log one event, then hand it to every follower — with `document` attached when the
    /// event changed it. Written and flushed to the kernel before this returns (so before
    /// the response that reports it); fsynced by the flusher within `FLUSH_EVERY`.
    fn append_event(
        &mut self,
        kind: &str,
        data: Value,
        document: Option<&bench_doc::Document>,
    ) -> Result<Event, String> {
        let event = self.write_event(kind, data)?;
        let mut dropped = self.fan_out(&event, document);
        // A dropped follower is itself bench-visible. Its own fan-out can drop more, so this
        // repeats until a round drops nobody — at most once per follower.
        while dropped > 0 {
            let note = self.write_event(
                "events/follower-dropped",
                json!({ "count": dropped, "why": format!("fell {FOLLOWER_QUEUE} frames behind; reconnect for the whole document") }),
            )?;
            dropped = self.fan_out(&note, None);
        }
        Ok(event)
    }

    fn write_event(&mut self, kind: &str, data: Value) -> Result<Event, String> {
        let event = Event {
            seq: self.next_seq,
            at: now_rfc3339(),
            kind: kind.to_string(),
            data,
        };
        let mut line =
            serde_json::to_string(&event).map_err(|e| format!("cannot encode event: {e}"))?;
        line.push('\n');
        self.log
            .write_all(line.as_bytes())
            .and_then(|()| self.log.flush())
            .map_err(|e| format!("cannot append to event log: {e}"))?;
        self.unflushed.store(true, Ordering::Release);
        self.next_seq += 1;
        Ok(event)
    }

    /// Queue a frame for every follower; answer how many were dropped for being full.
    fn fan_out(&mut self, event: &Event, document: Option<&bench_doc::Document>) -> usize {
        if self.followers.is_empty() {
            return 0;
        }
        let frame = Frame {
            event: event.clone(),
            document: document.cloned(),
        };
        let Ok(mut line) = serde_json::to_string(&frame) else {
            return 0;
        };
        line.push('\n');
        let line: Arc<str> = line.into();
        let mut dropped = 0;
        self.followers
            .retain(|tx| match tx.try_send(Arc::clone(&line)) {
                Ok(()) => true,
                Err(mpsc::TrySendError::Full(_)) => {
                    dropped += 1;
                    false
                }
                Err(mpsc::TrySendError::Disconnected(_)) => false,
            });
        dropped
    }
}

/// fsyncs the log on its own thread, through its own descriptor, so no verb ever waits on
/// the disk (`FLUSH_EVERY` has the measurement and the trade).
fn spawn_flusher(log: &File, unflushed: Arc<AtomicBool>) -> Result<(), String> {
    let own = log
        .try_clone()
        .map_err(|e| format!("cannot open the log for the flusher: {e}"))?;
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(FLUSH_EVERY);
            if unflushed.swap(false, Ordering::AcqRel) {
                let _ = own.sync_data();
            }
        }
    });
    Ok(())
}

fn boot(root: PathBuf, suite: Option<SuiteName>, home: PathBuf) -> Result<i32, StartError> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder.create(&root).map_err(|e| {
        StartError::Failed(format!("cannot create record root {}: {e}", root.display()))
    })?;

    let sock = socket_path(&root);
    check_socket_path(&sock).map_err(StartError::Refused)?;

    // A connectable socket means a live daemon owns this root — refuse; a dead one is
    // stale — reclaim, saying so.
    if sock.exists() {
        match UnixStream::connect(&sock) {
            Ok(_) => {
                return Err(StartError::Refused(format!(
                    "a live benchd already answers at {} — one daemon per root",
                    sock.display()
                )));
            }
            Err(_) => {
                eprintln!("benchd: removing stale socket {}", sock.display());
                fs::remove_file(&sock)
                    .map_err(|e| StartError::Failed(format!("cannot remove stale socket: {e}")))?;
            }
        }
    }

    let events = events_path(&root);
    let Scanned {
        next_seq,
        repair,
        last_document_change,
    } = scan_log(&events)?;
    let (bench, bench_events) = layout::load(&root, last_document_change);
    let (session_records, session_events) = sessions::load(&root);

    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&events)
        .map_err(|e| {
            StartError::Failed(format!("cannot open event log {}: {e}", events.display()))
        })?;
    let _ = fs::set_permissions(&events, fs::Permissions::from_mode(0o600));

    // An endpoint file at boot names a browser from a daemon that is gone — and its
    // leash went with it, so that browser is gone too. Removed before the socket is
    // bound, so no client of this daemon can find it; logged once the log is open.
    let stale_endpoint = Some(browser_endpoint_path(&root))
        .filter(|p| p.exists())
        .inspect(|p| {
            let _ = fs::remove_file(p);
        });

    let (notice_tx, notice_rx) = mpsc::channel::<Notice>();
    let core = Arc::new(Mutex::new(Core {
        root,
        suite,
        log,
        next_seq,
        started_at: now_rfc3339(),
        booted: Instant::now(),
        sessions: HashMap::new(),
        next_session: 1,
        next_mail: 1,
        pending_wakes: Vec::new(),
        wake_tokens: HashMap::new(),
        notices: notice_tx,
        home,
        browser: None,
        browser_wanted: false,
        browser_restarts: Vec::new(),
        bench,
        session_records,
        followers: Vec::new(),
        unflushed: Arc::new(AtomicBool::new(false)),
    }));

    let listener = {
        let mut c = core.lock().unwrap();
        if c.next_seq == 0 {
            c.append(
                "log/format",
                json!({ "format": EVENTS_LOG_FORMAT, "version": EVENTS_LOG_VERSION }),
            )
            .map_err(StartError::Failed)?;
        }
        if let Some(note) = repair {
            c.append(
                "log/repaired",
                json!({
                    "quarantine": note.quarantine.display().to_string(),
                    "dropped_bytes": note.dropped_bytes,
                }),
            )
            .map_err(StartError::Failed)?;
        }
        if let Some(stale) = &stale_endpoint {
            c.append(
                "browser/cleared",
                json!({ "endpoint": stale.display().to_string(), "why": "left by a daemon that is no longer running" }),
            )
            .map_err(StartError::Failed)?;
        }
        for (kind, data) in bench_events.into_iter().chain(session_events) {
            c.append(kind, data).map_err(StartError::Failed)?;
        }
        let unflushed = Arc::clone(&c.unflushed);
        spawn_flusher(&c.log, unflushed).map_err(StartError::Failed)?;
        let suite_name = c.suite.as_ref().map(|s| s.as_str().to_string());
        c.append(
            "daemon/started",
            json!({
                "pid": process::id(),
                "version": env!("CARGO_PKG_VERSION"),
                "suite": suite_name,
            }),
        )
        .map_err(StartError::Failed)?;
        // Bound only now, after the boot events: a client that can connect can read them
        // (the socket used to come first, and a fast reader found an empty log).
        let listener = UnixListener::bind(&sock)
            .map_err(|e| StartError::Failed(format!("cannot bind {}: {e}", sock.display())))?;
        eprintln!(
            "benchd {} listening at {} (root {})",
            env!("CARGO_PKG_VERSION"),
            socket_path(&c.root).display(),
            c.root.display()
        );
        listener
    };

    // Session notices — exits and forced detaches — become events. The reader threads
    // send; this thread logs. Bench-visible means logged, including facts nobody asked
    // a verb for.
    {
        let core = Arc::clone(&core);
        std::thread::spawn(move || {
            while let Ok(notice) = notice_rx.recv() {
                let mut c = core.lock().unwrap();
                match notice {
                    Notice::Exited { session } => {
                        let _ = c.append("session/exited", json!({ "session": session }));
                    }
                    Notice::Detached { session } => {
                        let _ = c.append("session/detached", json!({ "session": session }));
                    }
                }
            }
        });
    }

    // The wake reactor: mail/sent facts become pastes into idle recipient ptys.
    {
        let core = Arc::clone(&core);
        std::thread::spawn(move || wake_reactor(core));
    }

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let core = Arc::clone(&core);
        std::thread::spawn(move || handle(core, stream));
    }
    Ok(0)
}

/// Answer `mail/sent` with `agent/woken` — the composition the mail spike proved, as a
/// reactor over daemon state. Per pending wake: recipient must be a live session, its
/// pty quiet past the idle gate, and its token bucket willing; then the message is
/// retired (the notice carries the path it will KEEP), the notice is pasted and
/// submitted, and the wake is logged. A capped wake logs once and waits for refill —
/// the mail itself sits safely in the mailbox either way.
fn wake_reactor(core: Arc<Mutex<Core>>) {
    loop {
        std::thread::sleep(Duration::from_millis(400));
        // Snapshot under the lock; judge and paste outside it.
        let candidates: Vec<(String, String, String, Arc<Session>)> = {
            let c = core.lock().unwrap();
            c.pending_wakes
                .iter()
                .filter_map(|p| {
                    c.sessions
                        .values()
                        .find(|s| s.handle == p.handle && s.is_live())
                        .map(|s| {
                            (
                                p.handle.clone(),
                                p.mail_id.clone(),
                                p.from.clone(),
                                Arc::clone(s),
                            )
                        })
                })
                .collect()
        };
        // Drop pendings whose recipient session is gone for good.
        {
            let mut c = core.lock().unwrap();
            let known: std::collections::HashSet<String> =
                c.sessions.values().map(|s| s.handle.clone()).collect();
            let mut dropped: Vec<(String, String)> = Vec::new();
            c.pending_wakes.retain(|p| {
                let has_session = known.contains(&p.handle);
                if !has_session {
                    dropped.push((p.handle.clone(), p.mail_id.clone()));
                }
                has_session
            });
            for (handle, mail_id) in dropped {
                let _ = c.append(
                    "wake/dropped",
                    json!({ "handle": handle, "mail": mail_id, "why": "recipient session gone; mail stays in the mailbox" }),
                );
            }
        }
        for (handle, mail_id, from, session) in candidates {
            if session.idle_for() < WAKE_IDLE_GATE {
                continue;
            }
            // Token, event, and pending-list mutation under the lock; the paste outside.
            let (go, root) = {
                let mut c = core.lock().unwrap();
                let now = Instant::now();
                let bucket = c.wake_tokens.entry(handle.clone()).or_insert(WakeBucket {
                    tokens: WAKE_BURST,
                    last: now,
                });
                let refill = now.duration_since(bucket.last).as_secs_f64() * WAKE_REFILL_PER_SEC;
                bucket.tokens = (bucket.tokens + refill).min(WAKE_BURST);
                bucket.last = now;
                if bucket.tokens < 1.0 {
                    if let Some(p) = c
                        .pending_wakes
                        .iter_mut()
                        .find(|p| p.mail_id == mail_id && !p.capped_logged)
                    {
                        p.capped_logged = true;
                        let _ =
                            c.append("wake/capped", json!({ "handle": handle, "mail": mail_id }));
                    }
                    (false, c.root.clone())
                } else {
                    bucket.tokens -= 1.0;
                    (true, c.root.clone())
                }
            };
            if !go {
                continue;
            }
            let retired = match bench_mail::retire(&root, &handle, &mail_id) {
                Ok(p) => p,
                Err(why) => {
                    let mut c = core.lock().unwrap();
                    c.pending_wakes.retain(|p| p.mail_id != mail_id);
                    let _ = c.append(
                        "wake/dropped",
                        json!({ "handle": handle, "mail": mail_id, "why": why }),
                    );
                    continue;
                }
            };
            let notice = format!("You have mail from {from}: {}", retired.display());
            let delivered = session.deliver_line(&notice).is_ok();
            let mut c = core.lock().unwrap();
            c.pending_wakes.retain(|p| p.mail_id != mail_id);
            if delivered {
                let _ = c.append(
                    "agent/woken",
                    json!({ "session": session.id, "handle": handle, "mail": mail_id }),
                );
            } else {
                let _ = c.append(
                    "wake/dropped",
                    json!({ "handle": handle, "mail": mail_id, "why": "paste failed" }),
                );
            }
        }
    }
}

enum AfterResponse {
    Done,
    /// The connection upgrades to an attach relay AFTER the response line: replay
    /// happens then, so the protocol stays "one response line first" even with a full
    /// ring. This thread then pumps client bytes into the session's pty until EOF.
    Pump {
        session: Arc<Session>,
        stream: UnixStream,
        rows: u16,
        cols: u16,
    },
    Stop,
    /// `events --follow`: after the response line, this connection is a stream of frames
    /// from the follower's own queue, written on this thread and never under the mutex.
    Follow(mpsc::Receiver<Arc<str>>),
}

fn handle(core: Arc<Mutex<Core>>, stream: UnixStream) {
    // Bounded in time as well as bytes (R2): this connection gets DAEMON_IO_TIMEOUT to
    // deliver its line; an attach upgrade lifts the bound after the response.
    let _ = stream.set_read_timeout(Some(DAEMON_IO_TIMEOUT));
    let _ = stream.set_write_timeout(Some(DAEMON_IO_TIMEOUT));
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    });
    let mut line = String::new();
    let mut limited = (&mut reader).take(MAX_REQUEST_BYTES as u64 + 1);
    if limited.read_line(&mut line).is_err() {
        respond(
            &stream,
            &Response {
                id: "timed-out".into(),
                status: Status::Refused,
                reason: Some(format!(
                    "request not completed within {}s — one line, newline-terminated",
                    DAEMON_IO_TIMEOUT.as_secs()
                )),
                data: None,
            },
        );
        return;
    }
    if line.len() > MAX_REQUEST_BYTES {
        respond(
            &stream,
            &Response {
                id: "oversized".into(),
                status: Status::Refused,
                reason: Some(format!("request exceeds {MAX_REQUEST_BYTES} bytes")),
                data: None,
            },
        );
        return;
    }
    let request: Request = match serde_json::from_str(&line) {
        Ok(r) => r,
        Err(e) => {
            respond(
                &stream,
                &Response {
                    id: "unparseable".into(),
                    status: Status::Refused,
                    reason: Some(format!("not a request: {e}")),
                    data: None,
                },
            );
            return;
        }
    };

    let (response, after) = dispatch(&core, &request, &stream);
    match after {
        AfterResponse::Done => respond(&stream, &response),
        AfterResponse::Stop => {
            respond(&stream, &response);
            // Drain-then-die for every session, then leave. process::exit is deliberate:
            // the accept loop has no other owner to unblock.
            let sessions: Vec<Arc<Session>> = {
                let c = core.lock().unwrap();
                c.sessions.values().cloned().collect()
            };
            for s in sessions {
                let _ = s.close(Duration::from_secs(1));
            }
            let _ = stop_browser(&core, Duration::from_secs(2));
            // The flusher runs every FLUSH_EVERY; the last events must not wait on it.
            let _ = core.lock().unwrap().log.sync_data();
            let root = core.lock().unwrap().root.clone();
            let _ = fs::remove_file(socket_path(&root));
            process::exit(0);
        }
        AfterResponse::Follow(frames) => {
            respond_keep_open(&stream, &response);
            // Writes stay bounded by DAEMON_IO_TIMEOUT: a follower that stops reading errors
            // out here, while its queue fills and the core drops it.
            let mut out = &stream;
            while let Ok(frame) = frames.recv() {
                if out.write_all(frame.as_bytes()).is_err() {
                    break;
                }
            }
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
        AfterResponse::Pump {
            session,
            stream: raw,
            rows,
            cols,
        } => {
            // Response first (an ordinary line), then the replay, then this connection
            // is a byte relay — the protocol stays "one response line first" even with
            // a full ring.
            respond_keep_open(&raw, &response);
            let _ = raw.set_read_timeout(None);
            let relay = match raw.try_clone() {
                Ok(s) => s,
                Err(_) => return,
            };
            let generation = match session.attach(relay, rows, cols) {
                Ok(g) => g,
                Err(_) => {
                    let _ = raw.shutdown(std::net::Shutdown::Both);
                    return;
                }
            };
            let mut input = raw;
            let mut chunk = [0u8; 8192];
            loop {
                match input.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if session.write_input(&chunk[..n]).is_err() {
                            break;
                        }
                    }
                }
            }
            // Only the attachment this pump owns is cleared; a taken-over pump's
            // detach was the takeover itself, logged from the other side.
            if session.detach_generation(generation) {
                let mut c = core.lock().unwrap();
                let _ = c.append("session/detached", json!({ "session": session.id }));
            }
        }
    }
}

fn dispatch(
    core: &Arc<Mutex<Core>>,
    req: &Request,
    stream: &UnixStream,
) -> (Response, AfterResponse) {
    let ok = |data: Value| Response {
        id: req.id.clone(),
        status: Status::Ok,
        reason: None,
        data: Some(data),
    };
    let refused = |why: String| Response {
        id: req.id.clone(),
        status: Status::Refused,
        reason: Some(why),
        data: None,
    };
    let errored = |why: String| Response {
        id: req.id.clone(),
        status: Status::Error,
        reason: Some(why),
        data: None,
    };

    match Verb::parse(&req.verb) {
        Some(Verb::Status) => {
            let c = core.lock().unwrap();
            let live = c.sessions.values().filter(|s| s.is_live()).count();
            (
                ok(json!({
                    "pid": process::id(),
                    "version": env!("CARGO_PKG_VERSION"),
                    "suite": c.suite.as_ref().map(|s| s.as_str().to_string()),
                    "root": c.root.display().to_string(),
                    "socket": socket_path(&c.root).display().to_string(),
                    "started_at": c.started_at,
                    "uptime_secs": c.booted.elapsed().as_secs(),
                    "events": c.next_seq,
                    "sessions": { "total": c.sessions.len(), "live": live },
                })),
                AfterResponse::Done,
            )
        }
        Some(Verb::Events) if req.args.get("follow").and_then(Value::as_bool) == Some(true) => {
            // Registered and snapshotted under one lock, so no event falls between the
            // document this answers with and the first frame.
            let mut c = core.lock().unwrap();
            let (tx, rx) = mpsc::sync_channel(FOLLOWER_QUEUE);
            c.followers.push(tx);
            (
                ok(json!(layout::document_at(&c))),
                AfterResponse::Follow(rx),
            )
        }
        Some(Verb::Layout) => {
            let mut c = core.lock().unwrap();
            (layout::answer(&mut c, req), AfterResponse::Done)
        }
        Some(Verb::Events) => {
            let since = req.args.get("since").and_then(Value::as_u64).unwrap_or(0);
            let path = {
                let c = core.lock().unwrap();
                events_path(&c.root)
            };
            match read_events(&path, since) {
                Ok(data) => (ok(data), AfterResponse::Done),
                Err(why) => (errored(why), AfterResponse::Done),
            }
        }
        Some(Verb::Stop) => {
            let mut c = core.lock().unwrap();
            match c.append("daemon/stopped", json!({ "pid": process::id() })) {
                Ok(()) => (ok(json!({ "stopping": true })), AfterResponse::Stop),
                Err(why) => (errored(why), AfterResponse::Done),
            }
        }

        Some(Verb::Spawn) => {
            // Typed decode first (R3: one spelling, both sides), judged strictly after
            // — a missing required key refuses naming the FIELD, never a rule that did
            // not actually fire.
            let parsed: SpawnArgs = match serde_json::from_value(req.args.clone()) {
                Ok(a) => a,
                Err(e) => return (refused(format!("spawn args: {e}")), AfterResponse::Done),
            };
            let test_ok = std::env::var(TEST_AGENT_ENV).is_ok_and(|v| v == "1");
            let agent = match AgentKind::parse(&parsed.agent, test_ok) {
                Ok(a) => a,
                Err(why) => return (refused(why), AfterResponse::Done),
            };
            let cwd = parsed.cwd.as_str();
            if !cwd.starts_with('/') || !PathBuf::from(cwd).is_dir() {
                return (
                    refused(format!(
                        "cwd must be an absolute path to an existing directory, got {cwd:?}"
                    )),
                    AfterResponse::Done,
                );
            }
            let prompt = match parsed.prompt_file.as_deref() {
                None => None,
                Some(p) => match fs::read_to_string(p) {
                    // The file must outlive the spawn (helm #93) — read it now, refuse
                    // loudly if it is not there, never pass it through argv.
                    Ok(text) => Some(text),
                    Err(e) => {
                        return (
                            refused(format!("cannot read prompt_file {p:?}: {e}")),
                            AfterResponse::Done,
                        );
                    }
                },
            };
            let rows = parsed.rows.unwrap_or(40);
            let cols = parsed.cols.unwrap_or(140);
            let spec = SpawnSpec {
                agent,
                cwd: parsed.cwd.clone(),
                model: parsed.model.clone(),
                effort: parsed.effort.clone(),
                runtime_session: agent.mints_session_id().then(mint_session_id),
                resume: false,
            };
            let (id, handle, root, notices) = {
                let mut c = core.lock().unwrap();
                let id = format!("s{}", c.next_session);
                let handle = parsed.name.clone().unwrap_or_else(|| id.clone());
                if let Err(why) = validate_handle(&handle) {
                    return (refused(why), AfterResponse::Done);
                }
                if handle == OPERATOR_HANDLE {
                    return (
                        refused(format!(
                            "{OPERATOR_HANDLE:?} is the operator's handle — addressable by anyone, claimable by no session"
                        )),
                        AfterResponse::Done,
                    );
                }
                if c.sessions.values().any(|s| s.handle == handle) {
                    return (
                        refused(format!(
                            "handle {handle:?} is already claimed — `bench sessions` lists them"
                        )),
                        AfterResponse::Done,
                    );
                }
                c.next_session += 1;
                (id, handle, c.root.clone(), c.notices.clone())
            };
            // The session learns its address and root, so `bench mail send` inside it
            // needs no flags and lands in the right mailroom.
            let extra_env = [
                ("BENCH_SESSION".to_string(), id.clone()),
                ("BENCH_HANDLE".to_string(), handle.clone()),
                ("BENCH_DIR".to_string(), root.display().to_string()),
            ];
            let session = match Session::spawn(
                id.clone(),
                handle.clone(),
                &spec,
                rows,
                cols,
                &extra_env,
                notices,
            ) {
                Ok(s) => s,
                Err(why) => return (errored(why), AfterResponse::Done),
            };
            {
                let mut c = core.lock().unwrap();
                c.sessions.insert(id.clone(), Arc::clone(&session));
                if let Err(why) = c.append(
                    "session/spawned",
                    json!({
                        "session": id,
                        "handle": session.handle,
                        "agent": agent.name(),
                        "cwd": spec.cwd,
                        "pid": session.pid,
                        "runtime_session": spec.runtime_session,
                        "model": spec.model,
                        "effort": spec.effort,
                    }),
                ) {
                    return (errored(why), AfterResponse::Done);
                }
                // Recorded at spawn only: `resume` re-enters the same runtime session id
                // (bench_session::argv), which this record already holds.
                if let Err(why) = sessions::record_spawn(
                    &mut c,
                    bench_wire::Harness::parse(agent.name()),
                    spec.runtime_session.as_deref(),
                    &spec.cwd,
                    &id,
                ) {
                    return (errored(why), AfterResponse::Done);
                }
            }
            // Ready wait and prompt delivery happen WITHOUT the core lock.
            let mut ready = true;
            let mut prompt_delivered = false;
            if let Some(text) = prompt {
                ready = session.wait_ready(READY_WAIT);
                if ready {
                    let one_line = text.replace('\n', " ");
                    prompt_delivered = session.deliver_line(one_line.trim()).is_ok();
                    let mut c = core.lock().unwrap();
                    let _ = c.append("session/prompted", json!({ "session": session.id }));
                }
            }
            (
                ok(json!({
                    "session": session.id,
                    "handle": session.handle,
                    "pid": session.pid,
                    "agent": agent.name(),
                    "runtime_session": session.runtime_session,
                    "ready": ready,
                    "prompt_delivered": prompt_delivered,
                })),
                AfterResponse::Done,
            )
        }

        Some(Verb::Sessions) => {
            let c = core.lock().unwrap();
            let list: Vec<Value> = c
                .sessions
                .values()
                .map(|s| {
                    json!({
                        "session": s.id,
                        "handle": s.handle,
                        "agent": s.agent.name(),
                        "cwd": s.cwd,
                        "pid": s.pid,
                        "live": s.is_live(),
                        "attached": s.is_attached(),
                        "output_bytes": s.output_bytes(),
                        "runtime_session": s.runtime_session,
                        "uptime_secs": s.spawned_at.elapsed().as_secs(),
                    })
                })
                .collect();
            (ok(json!({ "sessions": list })), AfterResponse::Done)
        }

        Some(Verb::SessionsAll) => match sessions::answer_all(core, &req.args) {
            Ok(data) => (ok(data), AfterResponse::Done),
            Err(sessions::Refusal::Refused(why)) => (refused(why), AfterResponse::Done),
            Err(sessions::Refusal::Failed(why)) => (errored(why), AfterResponse::Done),
        },

        Some(Verb::SessionsDismiss) => match sessions::answer_dismiss(core, &req.args) {
            Ok(data) => (ok(data), AfterResponse::Done),
            Err(sessions::Refusal::Refused(why)) => (refused(why), AfterResponse::Done),
            Err(sessions::Refusal::Failed(why)) => (errored(why), AfterResponse::Done),
        },

        Some(Verb::Attach) => {
            let parsed: SessionArgs = match serde_json::from_value(req.args.clone()) {
                Ok(a) => a,
                Err(e) => return (refused(format!("attach args: {e}")), AfterResponse::Done),
            };
            let sid = parsed.session.as_str();
            let rows = parsed.rows.unwrap_or(0);
            let cols = parsed.cols.unwrap_or(0);
            let session = {
                let c = core.lock().unwrap();
                c.sessions.get(sid).cloned()
            };
            let Some(session) = session else {
                return (
                    refused(format!("no session {sid:?} — `bench sessions` lists them")),
                    AfterResponse::Done,
                );
            };
            if !session.is_live() {
                return (
                    refused(format!(
                        "session {sid} has exited — `bench resume {sid}` re-enters it where the runtime supports that"
                    )),
                    AfterResponse::Done,
                );
            }
            let raw = match stream.try_clone() {
                Ok(s) => s,
                Err(e) => {
                    return (
                        errored(format!("cannot clone stream: {e}")),
                        AfterResponse::Done,
                    );
                }
            };
            {
                let mut c = core.lock().unwrap();
                let _ = c.append("session/attached", json!({ "session": session.id }));
            }
            (
                ok(json!({
                    "session": session.id,
                    "detach": "Ctrl-\\",
                })),
                AfterResponse::Pump {
                    session,
                    stream: raw,
                    rows,
                    cols,
                },
            )
        }

        Some(Verb::Close) => {
            let parsed: SessionArgs = match serde_json::from_value(req.args.clone()) {
                Ok(a) => a,
                Err(e) => return (refused(format!("close args: {e}")), AfterResponse::Done),
            };
            let sid = parsed.session.as_str();
            let session = {
                let mut c = core.lock().unwrap();
                c.sessions.remove(sid)
            };
            let Some(session) = session else {
                return (
                    refused(format!("no session {sid:?} — `bench sessions` lists them")),
                    AfterResponse::Done,
                );
            };
            {
                let mut c = core.lock().unwrap();
                if let Err(why) = c.append("session/closed", json!({ "session": sid })) {
                    return (errored(why), AfterResponse::Done);
                }
            }
            let was_live = session.close(Duration::from_secs(2));
            (
                ok(json!({ "session": sid, "was_live": was_live })),
                AfterResponse::Done,
            )
        }

        Some(Verb::Resume) => {
            let parsed: SessionArgs = match serde_json::from_value(req.args.clone()) {
                Ok(a) => a,
                Err(e) => return (refused(format!("resume args: {e}")), AfterResponse::Done),
            };
            let sid = parsed.session.as_str();
            let old = {
                let c = core.lock().unwrap();
                c.sessions.get(sid).cloned()
            };
            let Some(old) = old else {
                return (
                    refused(format!(
                        "no session {sid:?} in this daemon's lifetime — resume across a daemon restart is not built yet"
                    )),
                    AfterResponse::Done,
                );
            };
            if old.is_live() {
                return (
                    refused(format!(
                        "session {sid} is still live — `bench attach {sid}` instead"
                    )),
                    AfterResponse::Done,
                );
            }
            let mut spec = old.spec.clone();
            spec.resume = true;
            let (id, root, notices) = {
                let mut c = core.lock().unwrap();
                let id = format!("s{}", c.next_session);
                c.next_session += 1;
                (id, c.root.clone(), c.notices.clone())
            };
            let extra_env = [
                ("BENCH_SESSION".to_string(), id.clone()),
                ("BENCH_HANDLE".to_string(), old.handle.clone()),
                ("BENCH_DIR".to_string(), root.display().to_string()),
            ];
            let session = match Session::spawn(
                id.clone(),
                old.handle.clone(),
                &spec,
                40,
                140,
                &extra_env,
                notices,
            ) {
                Ok(s) => s,
                Err(why) => return (refused(why), AfterResponse::Done),
            };
            {
                let mut c = core.lock().unwrap();
                c.sessions.remove(sid);
                c.sessions.insert(id.clone(), Arc::clone(&session));
                if let Err(why) = c.append(
                    "session/resumed",
                    json!({ "session": id, "from": sid, "runtime_session": session.runtime_session }),
                ) {
                    return (errored(why), AfterResponse::Done);
                }
            }
            let ready = session.wait_ready(READY_WAIT);
            (
                ok(json!({
                    "session": session.id,
                    "from": sid,
                    "pid": session.pid,
                    "ready": ready,
                })),
                AfterResponse::Done,
            )
        }

        Some(Verb::MailSend) => {
            let parsed: MailSendArgs = match serde_json::from_value(req.args.clone()) {
                Ok(a) => a,
                Err(e) => return (refused(format!("mail/send args: {e}")), AfterResponse::Done),
            };
            for (role, h) in [("to", &parsed.to), ("from", &parsed.from)] {
                if let Err(why) = validate_handle(h) {
                    return (refused(format!("{role}: {why}")), AfterResponse::Done);
                }
            }
            let (seq, root) = {
                let mut c = core.lock().unwrap();
                let seq = c.next_mail;
                c.next_mail += 1;
                (seq, c.root.clone())
            };
            let (id, path) = match bench_mail::deliver(
                &root,
                seq,
                &parsed.from,
                &parsed.to,
                parsed.subject.as_deref(),
                &now_rfc3339(),
                &parsed.body,
            ) {
                Ok(pair) => pair,
                Err(why) => return (errored(why), AfterResponse::Done),
            };
            let wake = {
                let mut c = core.lock().unwrap();
                if let Err(why) = c.append(
                    "mail/sent",
                    json!({
                        "id": id,
                        "from": parsed.from,
                        "to": parsed.to,
                        "subject": parsed.subject,
                        "path": path.display().to_string(),
                    }),
                ) {
                    return (errored(why), AfterResponse::Done);
                }
                let live = c
                    .sessions
                    .values()
                    .any(|s| s.handle == parsed.to && s.is_live());
                if live {
                    c.pending_wakes.push(PendingWake {
                        handle: parsed.to.clone(),
                        mail_id: id.clone(),
                        from: parsed.from.clone(),
                        capped_logged: false,
                    });
                    "queued"
                } else {
                    // Honest: the mail is delivered and waits; nothing will wake a
                    // recipient this daemon does not host.
                    "no-live-session"
                }
            };
            (
                ok(json!({
                    "id": id,
                    "to": parsed.to,
                    "path": path.display().to_string(),
                    "wake": wake,
                })),
                AfterResponse::Done,
            )
        }

        Some(Verb::MailList) => {
            let parsed: MailListArgs = match serde_json::from_value(req.args.clone()) {
                Ok(a) => a,
                Err(e) => return (refused(format!("mail/list args: {e}")), AfterResponse::Done),
            };
            if let Err(why) = validate_handle(&parsed.handle) {
                return (refused(why), AfterResponse::Done);
            }
            const MAX_RETURNED: usize = 200;
            let root = core.lock().unwrap().root.clone();
            let all = bench_mail::list(&root, &parsed.handle);
            let total = all.len();
            let mail: Vec<Value> = all
                .iter()
                .take(MAX_RETURNED)
                .map(|m| {
                    json!({
                        "id": m.id,
                        "from": m.from,
                        "subject": m.subject,
                        "at": m.at,
                        "unread": m.unread,
                    })
                })
                .collect();
            let returned = mail.len();
            (
                ok(json!({
                    "handle": parsed.handle,
                    "mail": mail,
                    "total": total,
                    "returned": returned,
                    "truncated": returned < total,
                })),
                AfterResponse::Done,
            )
        }

        Some(Verb::MailRead) => {
            let parsed: MailReadArgs = match serde_json::from_value(req.args.clone()) {
                Ok(a) => a,
                Err(e) => return (refused(format!("mail/read args: {e}")), AfterResponse::Done),
            };
            if let Err(why) = validate_handle(&parsed.handle) {
                return (refused(why), AfterResponse::Done);
            }
            let root = core.lock().unwrap().root.clone();
            // Retire-never-delete: reading moves inbox -> read; reading again answers
            // from where it lives.
            let path = match bench_mail::retire(&root, &parsed.handle, &parsed.id) {
                Ok(p) => p,
                Err(why) => return (refused(why), AfterResponse::Done),
            };
            let body = match bench_mail::read_body(&path) {
                Ok(b) => b,
                Err(why) => return (errored(why), AfterResponse::Done),
            };
            {
                let mut c = core.lock().unwrap();
                // Reading is a mutation here (the retirement), so it is logged.
                let _ = c.append(
                    "mail/read",
                    json!({ "handle": parsed.handle, "id": parsed.id }),
                );
                c.pending_wakes.retain(|p| p.mail_id != parsed.id);
            }
            (
                ok(json!({
                    "id": parsed.id,
                    "path": path.display().to_string(),
                    "body": body,
                })),
                AfterResponse::Done,
            )
        }

        Some(Verb::BrowserStart) => {
            core.lock().unwrap().browser_restarts.clear();
            match start_browser(core, 0, BrowserMode::Headless) {
                Ok((browser, already)) => {
                    let mut data = browser_json(&browser);
                    data["already_running"] = json!(already);
                    (ok(data), AfterResponse::Done)
                }
                Err(LaunchError::Refused(why)) => (refused(why), AfterResponse::Done),
                Err(LaunchError::Failed(why)) => (errored(why), AfterResponse::Done),
            }
        }

        Some(Verb::BrowserSetup) => {
            // The same profile, headed, for what only a real window can do: installing
            // extensions and signing in to them. Whatever runs now makes way for it.
            let running_setup = {
                let c = core.lock().unwrap();
                c.browser
                    .as_ref()
                    .is_some_and(|b| b.is_running() && b.mode() == BrowserMode::Setup)
            };
            if !running_setup && let Err(why) = stop_browser(core, Duration::from_secs(5)) {
                return (errored(why), AfterResponse::Done);
            }
            core.lock().unwrap().browser_restarts.clear();
            match start_browser(core, 0, BrowserMode::Setup) {
                Ok((browser, already)) => {
                    let mut data = browser_json(&browser);
                    data["already_running"] = json!(already);
                    data["next"] = json!(
                        "a Chrome window is open on this profile: install extensions and sign in, then quit it (Cmd-Q) — the browser returns to headless by itself"
                    );
                    (ok(data), AfterResponse::Done)
                }
                Err(LaunchError::Refused(why)) => (refused(why), AfterResponse::Done),
                Err(LaunchError::Failed(why)) => (errored(why), AfterResponse::Done),
            }
        }

        Some(Verb::BrowserStatus) => {
            let c = core.lock().unwrap();
            let running = c.browser.as_ref().filter(|b| b.is_running());
            let mut data = running.map_or_else(|| json!({}), |b| browser_json(b));
            data["running"] = json!(running.is_some());
            (ok(data), AfterResponse::Done)
        }

        Some(Verb::BrowserStop) => match stop_browser(core, Duration::from_secs(5)) {
            Ok(pid) => (
                ok(json!({ "was_running": pid.is_some(), "pid": pid })),
                AfterResponse::Done,
            ),
            Err(why) => (errored(why), AfterResponse::Done),
        },

        None => (
            refused(format!(
                "unknown verb {:?} — this daemon answers: {}",
                req.verb,
                KNOWN_VERBS.join(", ")
            )),
            AfterResponse::Done,
        ),
    }
}

/// Start the browser unless one is running; `(browser, already_running)`. `restart` is
/// 0 for a caller's start and n for the supervisor's n-th relaunch, and is logged.
fn start_browser(
    core: &Arc<Mutex<Core>>,
    restart: usize,
    mode: BrowserMode,
) -> Result<(Arc<Browser>, bool), LaunchError> {
    let _life = BROWSER_LIFECYCLE.lock().unwrap();
    let (root, home) = {
        let mut c = core.lock().unwrap();
        if let Some(b) = c.browser.as_ref().filter(|b| b.is_running()) {
            // Decided here, under the lifecycle lock that serializes every start, so no
            // caller can slip between a check and the hand-back. A setup window is the
            // operator's, mid-install or mid-sign-in, on the one profile: it has no address
            // to hand out, and a headless start beside it would take the profile from him.
            return match (b.mode(), mode) {
                (running, asked) if running == asked => Ok((Arc::clone(b), true)),
                (BrowserMode::Setup, _) => Err(LaunchError::Refused(
                    "the shared browser is open in a window for setup — the operator is using it. When he quits it (Cmd-Q) it comes back headless by itself; `bench browser status` says when".into(),
                )),
                (BrowserMode::Headless, _) => Err(LaunchError::Refused(
                    "the headless browser came back while setup was starting — run `bench browser setup` again".into(),
                )),
            };
        }
        if restart > 0 && !c.browser_wanted {
            return Err(LaunchError::Refused(
                "stopped while a restart was pending".into(),
            ));
        }
        c.browser_wanted = true;
        (c.root.clone(), c.home.clone())
    };
    let supervisor = Arc::clone(core);
    let candidates = default_candidates(
        &home,
        std::env::var("PLAYWRIGHT_BROWSERS_PATH").ok().as_deref(),
    );
    let launched = Browser::launch(
        &root,
        &home,
        &candidates,
        mode,
        now_rfc3339(),
        Box::new(move |info| browser_exited(supervisor, info)),
    );
    let mut c = core.lock().unwrap();
    match launched {
        Ok(browser) => {
            c.browser = Some(Arc::clone(&browser));
            let mut data = browser_json(&browser);
            data["restart"] = json!(restart);
            if let Err(why) = c.append("browser/started", data) {
                drop(c);
                browser.stop(Duration::from_secs(2));
                return Err(LaunchError::Failed(why));
            }
            Ok((browser, false))
        }
        Err(e) => {
            if restart == 0 {
                c.browser_wanted = false;
            }
            let why = match &e {
                LaunchError::Refused(w) | LaunchError::Failed(w) => w.clone(),
            };
            let _ = c.append(
                "browser/failed",
                json!({ "why": why, "restart": restart, "mode": mode }),
            );
            Err(e)
        }
    }
}

/// Stop the browser if one runs: logged, then the leash is dropped and the exit
/// awaited. Returns the pid that was stopped.
fn stop_browser(core: &Arc<Mutex<Core>>, grace: Duration) -> Result<Option<u32>, String> {
    let _life = BROWSER_LIFECYCLE.lock().unwrap();
    let browser = {
        let mut c = core.lock().unwrap();
        c.browser_wanted = false;
        match c.browser.take().filter(|b| b.is_running()) {
            Some(b) => {
                if let Err(why) = c.append("browser/stopped", json!({ "pid": b.pid })) {
                    // Not logged is not a reason to leave it running untracked: the next
                    // start would launch a second browser on the same profile. Stop it and
                    // say the record failed — `start_browser`'s rule on the same failure.
                    drop(c);
                    b.stop(grace);
                    return Err(why);
                }
                b
            }
            None => return Ok(None),
        }
    };
    browser.stop(grace);
    Ok(Some(browser.pid))
}

/// What the daemon says about a running browser — in answers, in `browser/status` and in
/// `browser/started`, one shape for all three: the headless browser's endpoint plus its
/// mode, or for setup just the mode and pid, because a setup browser has no address.
fn browser_json(browser: &Browser) -> Value {
    let mut data = match &browser.launched {
        Launched::Headless(endpoint) => json!(endpoint),
        Launched::Setup => json!({ "pid": browser.pid }),
    };
    data["mode"] = json!(browser.mode());
    data
}

/// The supervisor's half: a requested exit was already logged as `browser/stopped`; a
/// setup window the operator quit goes back to headless; a crash is logged and, inside
/// the cap and while the browser is still wanted, relaunched.
fn browser_exited(core: Arc<Mutex<Core>>, info: ExitInfo) {
    if info.requested {
        return;
    }
    if info.mode == BrowserMode::Setup {
        let wanted = {
            let mut c = core.lock().unwrap();
            if c.browser.as_ref().is_some_and(|b| b.pid == info.pid) {
                c.browser = None;
            }
            let wanted = c.browser_wanted;
            let _ = c.append(
                "browser/exited",
                json!({ "pid": info.pid, "code": info.code, "mode": info.mode, "restarting": wanted }),
            );
            wanted
        };
        if wanted {
            let _ = start_browser(&core, 0, BrowserMode::Headless);
        }
        return;
    }
    let restart = {
        let mut c = core.lock().unwrap();
        if c.browser.as_ref().is_some_and(|b| b.pid == info.pid) {
            c.browser = None;
        }
        let now = Instant::now();
        c.browser_restarts
            .retain(|t| now.duration_since(*t) < BROWSER_RESTART_WINDOW);
        let restarting = c.browser_wanted && c.browser_restarts.len() < BROWSER_RESTART_CAP;
        let _ = c.append(
            "browser/exited",
            json!({ "pid": info.pid, "code": info.code, "mode": info.mode, "restarting": restarting }),
        );
        if restarting {
            c.browser_restarts.push(now);
            Some(c.browser_restarts.len())
        } else {
            if c.browser_wanted {
                c.browser_wanted = false;
                let _ = c.append(
                    "browser/gave-up",
                    json!({
                        "restarts": BROWSER_RESTART_CAP,
                        "window_secs": BROWSER_RESTART_WINDOW.as_secs(),
                        "route": "`bench browser start` tries again; the browser log is <root>/browser/chrome.log",
                    }),
                );
            }
            None
        }
    };
    if let Some(n) = restart {
        std::thread::sleep(Duration::from_millis(500));
        let _ = start_browser(&core, n, BrowserMode::Headless);
    }
}

/// Report caps, never hide them: `returned < total` plus `truncated` says exactly what
/// was left out.
fn read_events(path: &PathBuf, since: u64) -> Result<Value, String> {
    const MAX_RETURNED: usize = 1000;
    let file = File::open(path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
    let mut events: Vec<Event> = Vec::new();
    let mut total = 0u64;
    for line in BufReader::new(file).lines() {
        let line = line.map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        if line.trim().is_empty() {
            continue;
        }
        let ev: Event = serde_json::from_str(&line)
            .map_err(|e| format!("corrupt event in {}: {e}", path.display()))?;
        if ev.seq < since {
            continue;
        }
        total += 1;
        if events.len() < MAX_RETURNED {
            events.push(ev);
        }
    }
    let returned = events.len();
    Ok(json!({
        "events": events,
        "total": total,
        "returned": returned,
        "truncated": (returned as u64) < total,
    }))
}

fn respond(stream: &UnixStream, response: &Response) {
    respond_keep_open(stream, response);
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

fn respond_keep_open(mut stream: &UnixStream, response: &Response) {
    if let Ok(mut line) = serde_json::to_string(response) {
        line.push('\n');
        let _ = stream.write_all(line.as_bytes());
    }
}

fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "unknown".into())
}
