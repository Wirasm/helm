//! benchd — the bench daemon. M0 (skeleton and isolation) + M5a (the pty core).
//!
//! What exists: a suite-aware record root, an append-only event log that is the single
//! source of truth, and one unix socket answering eight verbs — status/events/stop from
//! M0, and spawn/sessions/attach/close/resume from M5a: daemon-owned ptys hosting full
//! interactive agent TUIs, viewed through a dtach-grade raw relay (`bench attach`).
//! What deliberately does not exist yet: mail, attention, taps, the painter — those are
//! next milestones, and each arrives as new event kinds plus new verbs over this same
//! spine, never as a second channel beside it.
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

use bench_session::{AgentKind, Notice, Session, SpawnSpec, TEST_AGENT_ENV, mint_session_id};
use bench_wire::{
    DAEMON_IO_TIMEOUT, EVENTS_LOG_FORMAT, EVENTS_LOG_VERSION, Event, KNOWN_VERBS,
    MAX_REQUEST_BYTES, READY_WAIT, Request, Response, SessionArgs, SpawnArgs, Status, SuiteName,
    Verb, check_socket_path, events_path, resolve_root, socket_path,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process;
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

    match boot(root, suite) {
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

/// Read the log with byte offsets. A clean log returns the next seq. An unreadable
/// line refuses — unless it is the LAST non-empty line, which is an interrupted append:
/// quarantine the tail, truncate back to the last good byte, and report the repair (R1).
fn scan_log(events: &PathBuf) -> Result<(u64, Option<RepairNote>), StartError> {
    let bytes = match fs::read(events) {
        Ok(b) => b,
        Err(_) => return Ok((0, None)),
    };
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
                return Ok((
                    seq,
                    Some(RepairNote {
                        quarantine,
                        dropped_bytes: dropped.len(),
                    }),
                ));
            }
        }
    }
    Ok((seq, None))
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
    notices: mpsc::Sender<Notice>,
}

impl Core {
    fn append(&mut self, kind: &str, data: Value) -> Result<(), String> {
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
        // Best-effort durability: the record is the point of this process.
        let _ = self.log.sync_data();
        self.next_seq += 1;
        Ok(())
    }
}

fn boot(root: PathBuf, suite: Option<SuiteName>) -> Result<i32, StartError> {
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
    let (next_seq, repair) = scan_log(&events)?;

    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&events)
        .map_err(|e| {
            StartError::Failed(format!("cannot open event log {}: {e}", events.display()))
        })?;
    let _ = fs::set_permissions(&events, fs::Permissions::from_mode(0o600));

    let listener = UnixListener::bind(&sock)
        .map_err(|e| StartError::Failed(format!("cannot bind {}: {e}", sock.display())))?;

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
        notices: notice_tx,
    }));

    {
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
        eprintln!(
            "benchd {} listening at {} (root {})",
            env!("CARGO_PKG_VERSION"),
            socket_path(&c.root).display(),
            c.root.display()
        );
    }

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

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let core = Arc::clone(&core);
        std::thread::spawn(move || handle(core, stream));
    }
    Ok(0)
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
            let root = core.lock().unwrap().root.clone();
            let _ = fs::remove_file(socket_path(&root));
            process::exit(0);
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
            let (id, notices) = {
                let mut c = core.lock().unwrap();
                let id = format!("s{}", c.next_session);
                c.next_session += 1;
                (id, c.notices.clone())
            };
            let session = match Session::spawn(id.clone(), &spec, rows, cols, notices) {
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
            let (id, notices) = {
                let mut c = core.lock().unwrap();
                let id = format!("s{}", c.next_session);
                c.next_session += 1;
                (id, c.notices.clone())
            };
            let session = match Session::spawn(id.clone(), &spec, 40, 140, notices) {
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
