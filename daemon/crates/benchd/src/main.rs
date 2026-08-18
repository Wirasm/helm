//! benchd — the bench daemon. M0: skeleton and isolation.
//!
//! What exists at this milestone: a suite-aware record root, an append-only event log
//! that is the single source of truth, and one unix socket answering three verbs
//! (`status`, `events`, `stop`). What deliberately does not exist yet: panes, mail,
//! attention, taps — those are M1+ (docs/future-planning/bench-roadmap.md) and each
//! arrives as new event kinds plus new verbs over this same spine, never as a second
//! channel beside it.
//!
//! Design rules this file carries (argued in ../../direction.md):
//! - **Bench-visible means logged.** Every mutation appends an event before the response
//!   that reports it; readers project from the log, never from daemon memory alone.
//! - **One door.** The socket is the only way in; the CLI, the face, and every agent use
//!   the same verbs. There is no privileged in-process path to grow attached to.
//! - **Refuse loudly.** Unknown verbs, malformed requests, oversized lines, a corrupt
//!   log, an already-claimed socket: each is a named refusal, never a silent default.
//!
//! The daemon runs in the foreground and takes one request per connection, serially.
//! That is enough for M0's callers by construction, and a bounded, inspectable behavior
//! beats a concurrency story nothing needs yet.

use bench_wire::{
    DAEMON_IO_TIMEOUT, EVENTS_LOG_FORMAT, EVENTS_LOG_VERSION, Event, KNOWN_VERBS,
    MAX_REQUEST_BYTES, Request, Response, Status, SuiteName, Verb, check_socket_path, events_path,
    resolve_root, socket_path,
};
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process;
use std::time::Instant;

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
    // Flag wins over environment — the caller's explicit word over the inherited one,
    // helm's PaneEnvironment convention.
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
            // The whole point of the suite is isolation; a name that cannot isolate
            // must stop the launch, never fall back to the operator's live root (#86).
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

    match Daemon::start(root, suite) {
        Ok(mut daemon) => daemon.serve(),
        Err(StartError::Refused(why)) => refuse_start(&why),
        Err(StartError::Failed(why)) => fail_start(&why),
    }
}

// Pre-socket exits derive from the same enum as socket-answered ones (R3): one
// spelling of the contract, no hand-typed twin to drift.
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
/// quarantine the tail to a named sibling, truncate the log back to its last good byte,
/// and report the repair so the caller can log it (R1).
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
                // Torn tail: quarantine, truncate, and say so loudly.
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

struct Daemon {
    root: PathBuf,
    suite: Option<SuiteName>,
    listener: UnixListener,
    log: File,
    next_seq: u64,
    started_at: String,
    booted: Instant,
}

impl Daemon {
    fn start(root: PathBuf, suite: Option<SuiteName>) -> Result<Daemon, StartError> {
        // 0700, like every helm record directory: single-user machine, but the record
        // is still nobody else's to read.
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true).mode(0o700);
        builder.create(&root).map_err(|e| {
            StartError::Failed(format!("cannot create record root {}: {e}", root.display()))
        })?;

        let sock = socket_path(&root);
        check_socket_path(&sock).map_err(StartError::Refused)?;

        // A socket file can outlive its daemon (SIGKILL leaves it behind). Connectable
        // means a live daemon owns this root — refuse, because two writers on one log is
        // corruption with extra steps. Dead means stale — say so and reclaim.
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
                    fs::remove_file(&sock).map_err(|e| {
                        StartError::Failed(format!("cannot remove stale socket: {e}"))
                    })?;
                }
            }
        }

        // Boot-time integrity scan. The log is the record; a daemon that appends after
        // history it cannot read would be writing history it does not understand. One
        // exception, from PR #340's review (R1): a torn LAST line is an interrupted
        // append — the daemon's own crash mid-write, or ENOSPC part-way through a line
        // — and refusing it forever bricks the root with no route out. The tail is
        // quarantined beside the log and the repair is itself logged. A bad line in
        // the MIDDLE stays a refusal naming the line: that one is unexplained.
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

        let mut daemon = Daemon {
            root,
            suite,
            listener,
            log,
            next_seq,
            started_at: now_rfc3339(),
            booted: Instant::now(),
        };
        // A fresh log opens with its format marker (R4): the file is read outside the
        // process, and a reader that predates a change must fail on the marker rather
        // than misread history.
        if daemon.next_seq == 0 {
            daemon
                .append(
                    "log/format",
                    json!({ "format": EVENTS_LOG_FORMAT, "version": EVENTS_LOG_VERSION }),
                )
                .map_err(StartError::Failed)?;
        }
        if let Some(note) = repair {
            daemon
                .append(
                    "log/repaired",
                    json!({
                        "quarantine": note.quarantine.display().to_string(),
                        "dropped_bytes": note.dropped_bytes,
                    }),
                )
                .map_err(StartError::Failed)?;
        }
        daemon
            .append(
                "daemon/started",
                json!({
                    "pid": process::id(),
                    "version": env!("CARGO_PKG_VERSION"),
                    "suite": daemon.suite.as_ref().map(|s| s.as_str()),
                }),
            )
            .map_err(StartError::Failed)?;
        eprintln!(
            "benchd {} listening at {} (root {})",
            env!("CARGO_PKG_VERSION"),
            socket_path(&daemon.root).display(),
            daemon.root.display()
        );
        Ok(daemon)
    }

    fn serve(&mut self) -> i32 {
        loop {
            let stream = match self.listener.accept() {
                Ok((s, _)) => s,
                Err(e) => {
                    eprintln!("benchd: accept failed: {e}");
                    continue;
                }
            };
            match self.handle(stream) {
                Handled::Continue => {}
                Handled::Stop => break,
            }
        }
        // The stop event was appended before the response that promised it; all that is
        // left is to stop answering.
        let _ = fs::remove_file(socket_path(&self.root));
        0
    }

    fn handle(&mut self, stream: UnixStream) -> Handled {
        // Bounded in TIME as well as bytes (R2): this is the daemon's only loop, and a
        // client that connects and never finishes its line must get the refusal, not
        // the daemon. Timeouts are set before the reader clone so both share them.
        let _ = stream.set_read_timeout(Some(DAEMON_IO_TIMEOUT));
        let _ = stream.set_write_timeout(Some(DAEMON_IO_TIMEOUT));
        let mut reader = BufReader::new(match stream.try_clone() {
            Ok(s) => s,
            Err(_) => return Handled::Continue,
        });
        let mut line = String::new();
        // Bounded read: a line that never ends must not become memory nobody asked for.
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
            return Handled::Continue;
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
            return Handled::Continue;
        }

        // Permissive in shape, strict in judgment: a body that is not a Request still
        // gets a refusal naming the parse failure, under the only id we have.
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
                return Handled::Continue;
            }
        };

        let (response, outcome) = self.dispatch(&request);
        respond(&stream, &response);
        outcome
    }

    fn dispatch(&mut self, req: &Request) -> (Response, Handled) {
        // The verb is parsed, not string-matched (R5): the enum makes a new verb a
        // compile-forced decision here, and the refusal derives its list from the same
        // spelling the parser uses.
        match Verb::parse(&req.verb) {
            Some(Verb::Status) => (self.ok(req, self.status_data()), Handled::Continue),
            Some(Verb::Events) => {
                let since = req.args.get("since").and_then(Value::as_u64).unwrap_or(0);
                match self.read_events(since) {
                    Ok(data) => (self.ok(req, data), Handled::Continue),
                    Err(why) => (self.error(req, why), Handled::Continue),
                }
            }
            Some(Verb::Stop) => {
                // Logged before answered: the record must already say "stopped" when the
                // caller is told it worked (bench-visible means logged).
                match self.append("daemon/stopped", json!({ "pid": process::id() })) {
                    Ok(()) => (self.ok(req, json!({ "stopping": true })), Handled::Stop),
                    Err(why) => (self.error(req, why), Handled::Continue),
                }
            }
            None => (
                Response {
                    id: req.id.clone(),
                    status: Status::Refused,
                    reason: Some(format!(
                        "unknown verb {:?} — this daemon answers: {}",
                        req.verb,
                        KNOWN_VERBS.join(", ")
                    )),
                    data: None,
                },
                Handled::Continue,
            ),
        }
    }

    fn status_data(&self) -> Value {
        json!({
            "pid": process::id(),
            "version": env!("CARGO_PKG_VERSION"),
            "suite": self.suite.as_ref().map(|s| s.as_str()),
            "root": self.root.display().to_string(),
            "socket": socket_path(&self.root).display().to_string(),
            "started_at": self.started_at,
            "uptime_secs": self.booted.elapsed().as_secs(),
            "events": self.next_seq,
        })
    }

    /// Read back the log — from the file, not from memory, because the file is the
    /// record and this verb is how a reader checks that claim. Caps are reported, never
    /// silent: `returned < total` plus `truncated` says exactly what was left out.
    fn read_events(&self, since: u64) -> Result<Value, String> {
        const MAX_RETURNED: usize = 1000;
        let path = events_path(&self.root);
        let file = File::open(&path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
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
        // Best-effort durability: the record is the point of this process. A failed
        // sync is not a failed append — the bytes are handed off either way.
        let _ = self.log.sync_data();
        self.next_seq += 1;
        Ok(())
    }

    fn ok(&self, req: &Request, data: Value) -> Response {
        Response {
            id: req.id.clone(),
            status: Status::Ok,
            reason: None,
            data: Some(data),
        }
    }

    fn error(&self, req: &Request, why: String) -> Response {
        Response {
            id: req.id.clone(),
            status: Status::Error,
            reason: Some(why),
            data: None,
        }
    }
}

enum Handled {
    Continue,
    Stop,
}

fn respond(mut stream: &UnixStream, response: &Response) {
    if let Ok(mut line) = serde_json::to_string(response) {
        line.push('\n');
        let _ = stream.write_all(line.as_bytes());
    }
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "unknown".into())
}
