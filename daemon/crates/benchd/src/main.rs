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
    Event, MAX_REQUEST_BYTES, Request, Response, Status, SuiteName, check_socket_path, events_path,
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

fn refuse_start(why: &str) -> i32 {
    eprintln!("benchd: refusing to start: {why}");
    3
}

fn fail_start(why: &str) -> i32 {
    eprintln!("benchd: {why}");
    4
}

enum StartError {
    Refused(String),
    Failed(String),
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
        // a line it cannot read would be writing history it does not understand. Refuse
        // with the line number rather than guessing (direction.md: refuse loudly).
        let events = events_path(&root);
        let next_seq = match File::open(&events) {
            Ok(f) => {
                let mut seq = 0u64;
                for (i, line) in BufReader::new(f).lines().enumerate() {
                    let line = line.map_err(|e| {
                        StartError::Failed(format!("cannot read {}: {e}", events.display()))
                    })?;
                    if line.trim().is_empty() {
                        continue;
                    }
                    let ev: Event = serde_json::from_str(&line).map_err(|e| {
                        StartError::Refused(format!(
                            "event log {} line {} is not a readable event ({e}) — refusing to append after history this daemon cannot read",
                            events.display(),
                            i + 1
                        ))
                    })?;
                    seq = ev.seq + 1;
                }
                seq
            }
            Err(_) => 0,
        };

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
        let mut reader = BufReader::new(match stream.try_clone() {
            Ok(s) => s,
            Err(_) => return Handled::Continue,
        });
        let mut line = String::new();
        // Bounded read: a line that never ends must not become memory nobody asked for.
        let mut limited = (&mut reader).take(MAX_REQUEST_BYTES as u64 + 1);
        if limited.read_line(&mut line).is_err() {
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
        match req.verb.as_str() {
            "status" => (self.ok(req, self.status_data()), Handled::Continue),
            "events" => {
                let since = req.args.get("since").and_then(Value::as_u64).unwrap_or(0);
                match self.read_events(since) {
                    Ok(data) => (self.ok(req, data), Handled::Continue),
                    Err(why) => (self.error(req, why), Handled::Continue),
                }
            }
            "stop" => {
                // Logged before answered: the record must already say "stopped" when the
                // caller is told it worked (bench-visible means logged).
                match self.append("daemon/stopped", json!({ "pid": process::id() })) {
                    Ok(()) => (self.ok(req, json!({ "stopping": true })), Handled::Stop),
                    Err(why) => (self.error(req, why), Handled::Continue),
                }
            }
            other => (
                Response {
                    id: req.id.clone(),
                    status: Status::Refused,
                    reason: Some(format!(
                        "unknown verb {other:?} — this daemon answers: status, events, stop"
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
