//! bench — the CLI, the one agent-facing surface over the benchd socket (and, at M5a,
//! the operator's attach client).
//!
//! One connection, one JSON request line, one JSON response line — except `attach`,
//! which upgrades the same connection into a raw byte relay after the response: pty
//! output down, keystrokes up, Ctrl-\ to detach. The exit code IS the outcome:
//!
//!   0  ok            (the verb's data, pretty JSON, on stdout; attach: a clean detach)
//!   2  no daemon     (the socket could not be reached, or never answered — transport)
//!   3  refused       (the daemon said no and named why, on stderr)
//!   4  daemon failed (the daemon tried and could not, named why, on stderr)
//!
//! These are helm's spool codes, kept on purpose.

use bench_wire::{
    CLIENT_READ_TIMEOUT, DAEMON_IO_TIMEOUT, EXIT_NO_DAEMON, Request, RequestId, Response, Status,
    SuiteName, resolve_root, socket_path,
};
use serde_json::{Value, json};
use std::io::{IsTerminal, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    process::exit(run());
}

fn usage() -> &'static str {
    "usage: bench [--suite <name>] <verb> [args]\n\
     verbs: status                              daemon identity, root, uptime, counts\n\
     \x20     events [--since N]                  read the record back from seq N\n\
     \x20     stop                                log the stop, kill sessions, exit\n\
     \x20     spawn --agent <a> --cwd <dir>       spawn an agent into a bench pty\n\
     \x20           [--prompt-file <p>] [--model <m>] [--effort <e>]\n\
     \x20     sessions                            list bench sessions\n\
     \x20     attach <session>                    raw relay to a session's pty (Ctrl-\\ detaches)\n\
     \x20     close <session>                     drain-then-die the session\n\
     \x20     resume <session>                    re-enter an exited session's runtime state\n\
     env:   BENCH_SUITE (flag wins) · BENCH_DIR (root override, wins over suite)\n\
     exit:  0 ok · 2 no daemon · 3 refused · 4 daemon failed"
}

struct Cli {
    verb: String,
    args: Value,
    root: PathBuf,
}

fn run() -> i32 {
    let mut argv = std::env::args().skip(1).peekable();
    let mut suite_flag: Option<String> = None;
    let mut verb: Option<String> = None;
    let mut positional: Vec<String> = Vec::new();
    let mut flags: Vec<(String, String)> = Vec::new();
    let mut since: u64 = 0;

    while let Some(arg) = argv.next() {
        match arg.as_str() {
            "--suite" => match argv.next() {
                Some(v) => suite_flag = Some(v),
                None => return refuse("--suite needs a name"),
            },
            "--since" => match argv.next().and_then(|v| v.parse::<u64>().ok()) {
                Some(n) => since = n,
                None => return refuse("--since needs a sequence number"),
            },
            "--agent" | "--cwd" | "--prompt-file" | "--model" | "--effort" | "--rows"
            | "--cols" => {
                let key = arg.trim_start_matches("--").replace('-', "_");
                match argv.next() {
                    Some(v) => flags.push((key, v)),
                    None => return refuse(&format!("{arg} needs a value")),
                }
            }
            "--help" | "-h" => {
                println!("{}", usage());
                return 0;
            }
            other if verb.is_none() && !other.starts_with('-') => verb = Some(other.to_string()),
            other if verb.is_some() && !other.starts_with('-') => {
                positional.push(other.to_string())
            }
            other => return refuse(&format!("unknown argument {other:?}\n{}", usage())),
        }
    }

    let Some(verb) = verb else {
        return refuse(usage());
    };

    // Suite validated before any socket is touched — a name that cannot isolate must
    // never resolve to the shared root by accident (#86). One spelling, two edges.
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

    let mut args = serde_json::Map::new();
    match verb.as_str() {
        "events" if since > 0 => {
            args.insert("since".into(), json!(since));
        }
        "spawn" => {
            for (k, v) in &flags {
                let value: Value = match k.as_str() {
                    "rows" | "cols" => match v.parse::<u64>() {
                        Ok(n) => json!(n),
                        Err(_) => return refuse(&format!("--{k} needs a number")),
                    },
                    _ => json!(v),
                };
                args.insert(k.clone(), value);
            }
        }
        "attach" | "close" | "resume" => match positional.first() {
            Some(s) => {
                args.insert("session".into(), json!(s));
            }
            None => {
                return refuse(&format!(
                    "{verb} needs a session id — `bench sessions` lists them"
                ));
            }
        },
        _ => {}
    }
    if verb == "attach" {
        // Tell the daemon the viewer's size so the pty matches before replay.
        if let Some((rows, cols)) = terminal_size() {
            args.insert("rows".into(), json!(rows));
            args.insert("cols".into(), json!(cols));
        }
    }

    let cli = Cli {
        verb: verb.clone(),
        args: Value::Object(args),
        root,
    };
    if verb == "attach" {
        attach(cli)
    } else {
        simple(cli)
    }
}

/// The ordinary one-line-in, one-line-out path.
fn simple(cli: Cli) -> i32 {
    let (stream, request_line) = match open(&cli) {
        Ok(pair) => pair,
        Err(code) => return code,
    };
    if let Err(e) = (&stream).write_all(request_line.as_bytes()) {
        eprintln!("bench: write failed ({e})");
        return EXIT_NO_DAEMON;
    }
    let reply = match read_response_line(&stream) {
        Some(r) => r,
        None => {
            eprintln!("bench: no answer within {}s", CLIENT_READ_TIMEOUT.as_secs());
            return EXIT_NO_DAEMON;
        }
    };
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

/// The attach path: response line, then the connection is a raw relay. Local terminal
/// goes raw (keystrokes reach the agent unmangled, Ctrl-C included); Ctrl-\ detaches.
fn attach(cli: Cli) -> i32 {
    let (stream, request_line) = match open(&cli) {
        Ok(pair) => pair,
        Err(code) => return code,
    };
    if let Err(e) = (&stream).write_all(request_line.as_bytes()) {
        eprintln!("bench: write failed ({e})");
        return EXIT_NO_DAEMON;
    }
    let reply = match read_response_line(&stream) {
        Some(r) => r,
        None => {
            eprintln!("bench: no answer within {}s", CLIENT_READ_TIMEOUT.as_secs());
            return EXIT_NO_DAEMON;
        }
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
    eprintln!("bench: attached — Ctrl-\\ detaches");
    let _ = stream.set_read_timeout(None);

    // Raw local terminal for the duration; restored on the way out. `stty -g` gives a
    // restore token, so whatever the mode was is what comes back.
    let stdin_is_tty = std::io::stdin().is_terminal();
    let saved = if stdin_is_tty {
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
    } else {
        None
    };

    // Down: socket → stdout, byte-for-byte — escape sequences ride through, which is
    // what lets an OSC from the agent reach whatever terminal hosts this client.
    let down = {
        let mut sock = match stream.try_clone() {
            Ok(s) => s,
            Err(_) => return fail("cannot clone stream"),
        };
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
        })
    };

    // Up: stdin → socket, until Ctrl-\ (0x1C) or EOF.
    let mut stdin = std::io::stdin();
    let up_sock = stream;
    let mut chunk = [0u8; 1024];
    let code = loop {
        match stdin.read(&mut chunk) {
            Ok(0) | Err(_) => break 0,
            Ok(n) => {
                if let Some(pos) = chunk[..n].iter().position(|&b| b == 0x1c) {
                    if pos > 0 {
                        let _ = (&up_sock).write_all(&chunk[..pos]);
                    }
                    break 0;
                }
                if (&up_sock).write_all(&chunk[..n]).is_err() {
                    break 0;
                }
            }
        }
    };
    let _ = up_sock.shutdown(std::net::Shutdown::Both);
    let _ = down.join();
    if let Some(token) = saved {
        let _ = std::process::Command::new("stty")
            .arg(token)
            .stdin(std::process::Stdio::inherit())
            .status();
    }
    eprintln!("\nbench: detached");
    code
}

fn open(cli: &Cli) -> Result<(UnixStream, String), i32> {
    let sock = socket_path(&cli.root);
    let stream = match UnixStream::connect(&sock) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("bench: no daemon at {} ({e})", sock.display());
            return Err(EXIT_NO_DAEMON);
        }
    };
    // Bounded on both directions (R2): a hung caller has no exit code, which is the one
    // failure an unattended agent cannot act on.
    let _ = stream.set_write_timeout(Some(DAEMON_IO_TIMEOUT));
    let _ = stream.set_read_timeout(Some(CLIENT_READ_TIMEOUT));
    let request = Request {
        id: request_id(),
        verb: cli.verb.clone(),
        args: cli.args.clone(),
    };
    let mut line = match serde_json::to_string(&request) {
        Ok(l) => l,
        Err(_) => return Err(4),
    };
    line.push('\n');
    Ok((stream, line))
}

/// Read exactly the response line, byte by byte — a BufReader would swallow the raw
/// replay bytes that follow it on an attach connection.
fn read_response_line(mut stream: &UnixStream) -> Option<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) | Err(_) => {
                return if line.is_empty() {
                    None
                } else {
                    Some(String::from_utf8_lossy(&line).into_owned())
                };
            }
            Ok(_) => {
                if byte[0] == b'\n' {
                    return Some(String::from_utf8_lossy(&line).into_owned());
                }
                line.push(byte[0]);
                if line.len() > 1_000_000 {
                    return None;
                }
            }
        }
    }
}

fn terminal_size() -> Option<(u16, u16)> {
    if !std::io::stdout().is_terminal() {
        return None;
    }
    let out = std::process::Command::new("stty")
        .arg("size")
        .stdin(std::process::Stdio::inherit())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let mut parts = text.split_whitespace();
    let rows = parts.next()?.parse().ok()?;
    let cols = parts.next()?.parse().ok()?;
    Some((rows, cols))
}

// Pre-socket exits derive from the same enum as socket-answered ones (R3).
fn refuse(why: &str) -> i32 {
    eprintln!("bench: {why}");
    Status::Refused.exit_code()
}

fn fail(why: &str) -> i32 {
    eprintln!("bench: {why}");
    Status::Error.exit_code()
}

/// A fresh id per invocation, inside `RequestId`'s own pattern — validated, not assumed.
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
