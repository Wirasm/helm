//! bench — the CLI, which is also the future agent skill surface (bench-roadmap M0/M3).
//!
//! One connection, one JSON request line, one JSON response line. The exit code IS the
//! outcome — an agent reads `$?`, not prose:
//!
//!   0  ok            (the verb's data, pretty JSON, on stdout)
//!   2  no daemon     (the socket could not be reached — transport, not a daemon answer)
//!   3  refused       (the daemon said no and named why, on stderr)
//!   4  daemon failed (the daemon tried and could not, named why, on stderr)
//!
//! These are helm's spool codes, kept on purpose: every agent skill in this repo already
//! knows them, and a code that changes meaning across tools is worse than no code.

use bench_wire::{
    EXIT_NO_DAEMON, Request, RequestId, Response, SuiteName, resolve_root, socket_path,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    process::exit(run());
}

fn usage() -> &'static str {
    "usage: bench [--suite <name>] <verb>\n\
     verbs: status              daemon identity, root, uptime, event count\n\
     \x20     events [--since N]  read the record back from seq N\n\
     \x20     stop                ask the daemon to log its stop and exit\n\
     env:   BENCH_SUITE (flag wins) · BENCH_DIR (root override, wins over suite)\n\
     exit:  0 ok · 2 no daemon · 3 refused · 4 daemon failed"
}

fn run() -> i32 {
    let mut args = std::env::args().skip(1).peekable();
    let mut suite_flag: Option<String> = None;
    let mut verb: Option<String> = None;
    let mut since: u64 = 0;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--suite" => match args.next() {
                Some(v) => suite_flag = Some(v),
                None => return refuse("--suite needs a name"),
            },
            "--since" => match args.next().and_then(|v| v.parse::<u64>().ok()) {
                Some(n) => since = n,
                None => return refuse("--since needs a sequence number"),
            },
            "--help" | "-h" => {
                println!("{}", usage());
                return 0;
            }
            other if verb.is_none() && !other.starts_with('-') => verb = Some(other.to_string()),
            other => return refuse(&format!("unknown argument {other:?}\n{}", usage())),
        }
    }

    let Some(verb) = verb else {
        return refuse(usage());
    };

    // The suite is validated here, before any socket is touched: a name that cannot
    // isolate must never resolve to the shared root by accident (#86 semantics). The
    // daemon applies the identical rule from the same crate — one spelling, two edges.
    let suite_raw = suite_flag.or_else(|| std::env::var("BENCH_SUITE").ok());
    let suite = match suite_raw.as_deref() {
        Some(raw) => match SuiteName::validate(raw) {
            Ok(s) => Some(s),
            Err(why) => return refuse(&why),
        },
        None => None,
    };
    let home = match std::env::var("HOME") {
        Ok(h) => PathBuf::from(h),
        Err(_) => return refuse("HOME is not set; bench cannot resolve a record root"),
    };
    let bench_dir = std::env::var("BENCH_DIR").ok();
    let root = resolve_root(bench_dir.as_deref(), suite.as_ref(), &home);
    let sock = socket_path(&root);

    let args_value = match verb.as_str() {
        "events" if since > 0 => json!({ "since": since }),
        _ => Value::Null,
    };

    let request = Request {
        id: request_id(),
        verb,
        args: args_value,
    };

    let stream = match UnixStream::connect(&sock) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("bench: no daemon at {} ({e})", sock.display());
            return EXIT_NO_DAEMON;
        }
    };

    let mut line = match serde_json::to_string(&request) {
        Ok(l) => l,
        Err(e) => return fail(&format!("cannot encode request: {e}")),
    };
    line.push('\n');
    if let Err(e) = (&stream).write_all(line.as_bytes()) {
        eprintln!("bench: write to {} failed ({e})", sock.display());
        return EXIT_NO_DAEMON;
    }

    let mut reply = String::new();
    if BufReader::new(&stream).read_line(&mut reply).is_err() || reply.is_empty() {
        eprintln!("bench: no answer from {}", sock.display());
        return EXIT_NO_DAEMON;
    }

    let response: Response = match serde_json::from_str(&reply) {
        Ok(r) => r,
        Err(e) => return fail(&format!("unreadable response ({e}): {}", reply.trim())),
    };

    if let Some(reason) = &response.reason {
        eprintln!("bench: {reason}");
    }
    if let Some(data) = &response.data {
        match serde_json::to_string_pretty(data) {
            Ok(pretty) => println!("{pretty}"),
            Err(_) => println!("{data}"),
        }
    }
    response.status.exit_code()
}

fn refuse(why: &str) -> i32 {
    eprintln!("bench: {why}");
    3
}

fn fail(why: &str) -> i32 {
    eprintln!("bench: {why}");
    4
}

/// A fresh id per invocation, inside `RequestId`'s own pattern — validated, not assumed,
/// so the client can never send an id the daemon-side rule would refuse.
fn request_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let candidate = format!("bench-{}-{nanos:08x}", process::id());
    RequestId::validate(&candidate)
        .map(|id| id.as_str().to_string())
        .unwrap_or_else(|_| "bench-fallback".to_string())
}
